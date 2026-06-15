import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../api/projects_api.dart';
import '../api/tiles_api.dart';
import '../core/config.dart';
import '../mosaic/mosaic_engine.dart';
import '../mosaic/shared.dart';
import '../mosaic/types.dart';
import '../services/image_service.dart';
import 'auth_controller.dart';
import 'library_providers.dart';

const int _maxTiles = 2000;

/// Upload is network-bound, so fan out widely; compression is serialized
/// inside [ImageService] (the native codec isn't reentrant) and overlaps with
/// the in-flight uploads, so a high worker count mostly buys network parallelism.
const int _uploadConcurrency = 16;

/// Restore fetches tiles via the server batch endpoint: [_restoreBatchSize]
/// tiles per request (the server's max), [_restoreBatchConcurrency] requests in
/// flight. One batched request replaces dozens of per-tile round-trips.
const int _restoreBatchSize = 60;
const int _restoreBatchConcurrency = 6;

class BaseImage {
  BaseImage({
    required this.bytes,
    required this.thumbnail,
    required this.overlay,
    required this.blobUrl,
    required this.name,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;

  /// Full-ish thumbnail for on-screen display (base preview, control chip).
  final ui.Image thumbnail;

  /// Tiny intermediate used for the tinted overlay; the painter upscales it,
  /// which produces the web's blur. See [buildOverlayImage].
  final ui.Image overlay;
  final String blobUrl;
  final String name;
  final int width;
  final int height;
}

class TileAsset {
  TileAsset({
    required this.id,
    required this.descriptor,
    required this.thumbnail,
    required this.blobUrl,
    required this.filename,
  });
  final String id;
  final TileDescriptor descriptor;
  final ui.Image thumbnail;
  final String blobUrl;
  final String filename;
}

class StudioState {
  StudioState({
    this.base,
    this.tiles = const [],
    required this.settings,
    this.plan,
    this.isPlanning = false,
    this.isUploadingBase = false,
    this.isUploadingTiles = false,
    this.isRestoring = false,
    this.uploadDone = 0,
    this.uploadTotal = 0,
    this.error,
    this.currentProjectId,
  });

  final BaseImage? base;
  final List<TileAsset> tiles;
  final MosaicSettings settings;
  final SlimMosaicPlan? plan;
  final bool isPlanning;
  final bool isUploadingBase;
  final bool isUploadingTiles;
  final bool isRestoring;
  final int uploadDone;
  final int uploadTotal;
  final String? error;

  /// The id of the saved project currently open (null for a fresh mosaic).
  /// When set, Save updates this project instead of creating a new one.
  final String? currentProjectId;

  bool get canPlan => base != null && tiles.isNotEmpty;

  Map<String, ui.Image> get tileImages =>
      {for (final t in tiles) t.id: t.thumbnail};

  StudioState copyWith({
    BaseImage? base,
    List<TileAsset>? tiles,
    MosaicSettings? settings,
    SlimMosaicPlan? plan,
    bool? isPlanning,
    bool? isUploadingBase,
    bool? isUploadingTiles,
    bool? isRestoring,
    int? uploadDone,
    int? uploadTotal,
    Object? error = _noChange,
    bool clearPlan = false,
    String? currentProjectId,
  }) {
    return StudioState(
      base: base ?? this.base,
      tiles: tiles ?? this.tiles,
      settings: settings ?? this.settings,
      plan: clearPlan ? null : (plan ?? this.plan),
      isPlanning: isPlanning ?? this.isPlanning,
      isUploadingBase: isUploadingBase ?? this.isUploadingBase,
      isUploadingTiles: isUploadingTiles ?? this.isUploadingTiles,
      isRestoring: isRestoring ?? this.isRestoring,
      uploadDone: uploadDone ?? this.uploadDone,
      uploadTotal: uploadTotal ?? this.uploadTotal,
      error: error == _noChange ? this.error : error as String?,
      currentProjectId: currentProjectId ?? this.currentProjectId,
    );
  }

  static const _noChange = Object();
}

final imageServiceProvider = Provider((_) => ImageService());
final tilesApiProvider =
    Provider((ref) => TilesApi(ref.watch(apiClientProvider)));
final projectsApiProvider =
    Provider((ref) => ProjectsApi(ref.watch(apiClientProvider)));

final studioControllerProvider =
    NotifierProvider<StudioController, StudioState>(StudioController.new);

class StudioController extends Notifier<StudioState> {
  final _picker = ImagePicker();
  Timer? _debounce;
  Timer? _autoSave;
  int _planToken = 0;
  int _restoreToken = 0;

  @override
  StudioState build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _autoSave?.cancel();
    });
    return StudioState(settings: defaultSettings());
  }

  ImageService get _images => ref.read(imageServiceProvider);
  TilesApi get _tilesApi => ref.read(tilesApiProvider);

  /// Runs [task] for indices [0, count) keeping [concurrency] in flight at once
  /// (a continuous pool — no per-batch head-of-line blocking). Stops early when
  /// [cancelled] returns true.
  Future<void> _runPool(int count, int concurrency, bool Function() cancelled,
      Future<void> Function(int) task) async {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (cancelled()) return;
        final i = next++;
        if (i >= count) return;
        await task(i);
      }
    }

    final n = concurrency < count ? concurrency : count;
    await Future.wait([for (var w = 0; w < n; w++) worker()]);
  }

  Future<void> pickBaseImage() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    state = state.copyWith(isUploadingBase: true, error: null);
    try {
      final original = await file.readAsBytes();
      final compressed = await _images.compressBase(original);
      final upload =
          await _tilesApi.uploadBase(compressed, 'base-${_ts()}.jpg');
      if (!upload.isOk || upload.data == null) {
        state = state.copyWith(
            isUploadingBase: false, error: upload.error ?? 'Upload failed.');
        return;
      }
      final thumb = await decodeThumbnail(compressed, 1280);
      final overlay =
          await buildOverlayImage(compressed, baseBlur: state.settings.baseBlur);
      state = state.copyWith(
        base: BaseImage(
          bytes: compressed,
          thumbnail: thumb,
          overlay: overlay,
          blobUrl: upload.data!.blobUrl,
          name: _basename(file.name),
          width: thumb.width,
          height: thumb.height,
        ),
        isUploadingBase: false,
        clearPlan: true,
      );
    } catch (e) {
      state = state.copyWith(isUploadingBase: false, error: e.toString());
    }
  }

  Future<void> pickTileImages() async {
    final remaining = _maxTiles - state.tiles.length;
    if (remaining <= 0) {
      state = state.copyWith(
          error: 'You\'ve reached the $_maxTiles-tile limit. '
              'Remove some tiles to add more.');
      return;
    }
    // Show the loader immediately. image_picker keeps resolving the selected
    // files for a moment after the picker dismisses (longer for many photos);
    // without this there's a dead gap where the app looks stuck.
    state = state.copyWith(
        isUploadingTiles: true, uploadDone: 0, uploadTotal: 0, error: null);

    final List<XFile> files;
    try {
      files = await _picker.pickMultiImage();
    } catch (e) {
      state = state.copyWith(
          isUploadingTiles: false,
          error: 'Could not open the photo library: $e');
      return;
    }
    if (files.isEmpty) {
      state = state.copyWith(isUploadingTiles: false); // cancelled
      return;
    }

    final picked = files.take(remaining).toList();
    state = state.copyWith(uploadDone: 0, uploadTotal: picked.length);

    // Compress + upload + analyze in concurrent batches (network-bound, so
    // fanning out is far faster than a sequential loop).
    final results = List<TileAsset?>.filled(picked.length, null);
    var done = 0;
    String? firstError;

    Future<void> ingestOne(int i) async {
      final file = picked[i];
      final id = 'tile-${_ts()}-$i';
      try {
        final original = await file.readAsBytes();
        final compressed = await _images.compressTile(original);
        if (compressed.isEmpty) {
          firstError ??= 'Could not read image (unsupported format?)';
          return;
        }
        final filename = '$id.jpg';
        final upload = await _tilesApi.uploadTile(compressed, id, filename);
        if (!upload.isOk || upload.data == null) {
          firstError ??= upload.error ?? 'Upload failed';
          return;
        }
        final analyzed =
            await analyzeTileWithThumbnail(id, filename, compressed);
        results[i] = TileAsset(
          id: id,
          descriptor: analyzed.descriptor,
          thumbnail: analyzed.thumbnail,
          blobUrl: upload.data!.blobUrl,
          filename: filename,
        );
      } catch (e) {
        firstError ??= e.toString();
      }
      done++;
      state = state.copyWith(uploadDone: done);
    }

    try {
      await _runPool(
          picked.length, _uploadConcurrency, () => false, ingestOne);
    } finally {
      final added = results.whereType<TileAsset>().toList();
      // Surface a failure only when nothing got added — otherwise a few skipped
      // tiles shouldn't show an error.
      state = state.copyWith(
        tiles: [...state.tiles, ...added],
        isUploadingTiles: false,
        error: added.isEmpty ? (firstError ?? 'No tiles were added.') : null,
      );
    }
  }

  /// Imports a free sample pack (server-hosted blobs). These already exist on
  /// the server, so — like a project restore — we only fetch thumbnails to
  /// analyze locally and reuse each blob URL; nothing is re-uploaded.
  Future<void> loadSampleTiles(String folder) async {
    final remaining = _maxTiles - state.tiles.length;
    if (remaining <= 0) {
      state = state.copyWith(
          error: 'You\'ve reached the $_maxTiles-tile limit. '
              'Remove some tiles to add more.');
      return;
    }
    state = state.copyWith(
        isUploadingTiles: true, uploadDone: 0, uploadTotal: 0, error: null);
    try {
      final listRes = await _tilesApi.sampleTiles(folder);
      if (!listRes.isOk || listRes.data == null) {
        state = state.copyWith(
            isUploadingTiles: false,
            error: listRes.error ?? 'Could not load samples.');
        return;
      }
      var samples = listRes.data!;
      if (samples.isEmpty) {
        state = state.copyWith(
            isUploadingTiles: false, error: 'No sample tiles found.');
        return;
      }
      if (samples.length > remaining) samples = samples.sublist(0, remaining);
      state = state.copyWith(uploadTotal: samples.length);

      final results = List<TileAsset?>.filled(samples.length, null);
      var done = 0;

      final batches = <List<int>>[];
      for (var s = 0; s < samples.length; s += _restoreBatchSize) {
        final e = (s + _restoreBatchSize).clamp(0, samples.length);
        batches.add([for (var i = s; i < e; i++) i]);
      }

      Future<void> fetchBatch(int b) async {
        final idxs = batches[b];
        final urls = [for (final i in idxs) samples[i].blobUrl];
        final bytesByUrl = await _tilesApi.tileThumbBatch(urls, maxSize: 256);
        for (final i in idxs) {
          final sample = samples[i];
          final bytes = bytesByUrl[sample.blobUrl];
          if (bytes != null) {
            try {
              final id = 'tile-sample-${_ts()}-$i';
              final fileName = sample.pathname.split('/').last;
              final analyzed =
                  await analyzeTileWithThumbnail(id, fileName, bytes);
              results[i] = TileAsset(
                id: id,
                descriptor: analyzed.descriptor,
                thumbnail: analyzed.thumbnail,
                blobUrl: sample.blobUrl,
                filename: fileName,
              );
            } catch (_) {}
          }
          done++;
          state = state.copyWith(uploadDone: done);
        }
      }

      await _runPool(
          batches.length, _restoreBatchConcurrency, () => false, fetchBatch);

      final added = results.whereType<TileAsset>().toList();
      state = state.copyWith(
        tiles: [...state.tiles, ...added],
        isUploadingTiles: false,
        error: added.isEmpty ? 'No sample tiles were added.' : null,
      );
    } catch (e) {
      state = state.copyWith(isUploadingTiles: false, error: e.toString());
    }
  }

  void removeTile(String id) {
    state = state.copyWith(
        tiles: state.tiles.where((t) => t.id != id).toList());
  }

  /// Updates matching settings and schedules a debounced preview rebuild.
  void updateSettings(MosaicSettings settings) {
    state = state.copyWith(settings: settings);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), buildPlan);
  }

  /// Updates a render-overlay parameter (tint / blur). These don't affect tile
  /// matching, so no replan — the preview repaints instantly and the value is
  /// synced into the plan so the server render matches.
  void updateRenderParam({double? tintStrength, double? baseBlur}) {
    final settings = state.settings
        .copyWith(tintStrength: tintStrength, baseBlur: baseBlur);
    final plan = state.plan;
    if (plan != null) {
      if (tintStrength != null) plan.tintStrength = tintStrength;
      if (baseBlur != null) plan.baseBlur = baseBlur;
    }
    state = state.copyWith(settings: settings);
  }

  /// Builds the full-quality plan on-device (layout + match + SA in an isolate).
  Future<void> buildPlan() async {
    if (!state.canPlan) return;
    final token = ++_planToken;
    state = state.copyWith(isPlanning: true, error: null);
    try {
      final plan = await buildMosaicPlan(
        baseBytes: state.base!.bytes,
        tiles: state.tiles.map((t) => t.descriptor).toList(),
        rawSettings: state.settings,
        isMobile: true,
      );
      if (token != _planToken) return; // superseded by a newer build
      state = state.copyWith(plan: plan, isPlanning: false);
      _scheduleAutoSave();
    } catch (e) {
      if (token != _planToken) return;
      state = state.copyWith(isPlanning: false, error: e.toString());
    }
  }

  /// Persists the project a short while after the latest plan build, so the
  /// user's work is saved automatically without a manual Save action. Coalesces
  /// rapid rebuilds (slider drags) into one write.
  void _scheduleAutoSave() {
    _autoSave?.cancel();
    _autoSave = Timer(const Duration(milliseconds: 2000), _autoSaveProject);
  }

  Future<void> _autoSaveProject() async {
    if (!state.canPlan) return;
    final base = state.base;
    final tiles =
        state.tiles.map((t) => ProjectTileRef(t.blobUrl, t.filename)).toList();
    final api = ref.read(projectsApiProvider);
    final id = state.currentProjectId;
    try {
      if (id != null) {
        // Update in place — omit name so the user's project name is preserved.
        await api.update(id,
            baseImageUrl: base?.blobUrl,
            baseImageName: base?.name,
            tiles: tiles,
            settings: state.settings);
      } else {
        final res = await api.create(
            name: base?.name ?? 'My mosaic',
            baseImageUrl: base?.blobUrl,
            baseImageName: base?.name,
            tiles: tiles,
            settings: state.settings);
        if (res.isOk && res.data != null && res.data!.isNotEmpty) {
          state = state.copyWith(currentProjectId: res.data);
        }
      }
      ref.invalidate(projectsListProvider);
    } catch (_) {
      // Auto-save is best-effort; ignore transient failures.
    }
  }

  /// Saves the current studio state as a server project. Returns the project id
  /// (or null on failure).
  Future<String?> saveProject(String name) async {
    final base = state.base;
    final api = ref.read(projectsApiProvider);
    final tiles =
        state.tiles.map((t) => ProjectTileRef(t.blobUrl, t.filename)).toList();
    final existingId = state.currentProjectId;

    if (existingId != null) {
      // Update the project that's currently open.
      final res = await api.update(
        existingId,
        name: name,
        baseImageUrl: base?.blobUrl,
        baseImageName: base?.name,
        tiles: tiles,
        settings: state.settings,
      );
      if (!res.isOk) {
        state = state.copyWith(error: res.error);
        return null;
      }
      return existingId;
    }

    // No open project — create a new one and remember its id.
    final res = await api.create(
      name: name,
      baseImageUrl: base?.blobUrl,
      baseImageName: base?.name,
      tiles: tiles,
      settings: state.settings,
    );
    if (!res.isOk || res.data == null || res.data!.isEmpty) {
      state = state.copyWith(error: res.error);
      return null;
    }
    state = state.copyWith(currentProjectId: res.data);
    return res.data;
  }

  /// Restores a saved project into the studio: re-fetches the base + tile blobs
  /// (via the authenticated blob proxy), re-analyzes the tiles, applies the
  /// saved settings, and rebuilds the plan.
  /// Cancels an in-flight project restore (e.g. the user navigated back).
  void cancelRestore() {
    _restoreToken++;
    if (state.isRestoring) state = state.copyWith(isRestoring: false);
  }

  Future<void> loadProject(String projectId) async {
    final token = ++_restoreToken;
    state = StudioState(
        settings: state.settings,
        isRestoring: true,
        currentProjectId: projectId);
    try {
      final detail = await ref.read(projectsApiProvider).get(projectId);
      if (token != _restoreToken) return;
      if (!detail.isOk || detail.data == null) {
        state = state.copyWith(
            isRestoring: false, error: detail.error ?? 'Could not open project.');
        return;
      }
      final p = detail.data!;
      final settings = p.settings ?? state.settings;

      BaseImage? base;
      if (p.baseImageUrl != null) {
        final bytes = await _proxyBytes(p.baseImageUrl!);
        if (token != _restoreToken) return;
        if (bytes != null) {
          final thumb = await decodeThumbnail(bytes, 1280);
          final overlay = await buildOverlayImage(bytes, baseBlur: settings.baseBlur);
          base = BaseImage(
            bytes: bytes,
            thumbnail: thumb,
            overlay: overlay,
            blobUrl: p.baseImageUrl!,
            name: p.baseImageName ?? 'mosaic',
            width: thumb.width,
            height: thumb.height,
          );
        }
      }

      state = state.copyWith(
          base: base,
          settings: settings,
          uploadTotal: p.tiles.length,
          uploadDone: 0);

      // Fetch tiles via the server batch endpoint (one request per ~60 tiles)
      // and analyze each locally. Results stay index-aligned so the restored
      // tile order matches the saved project (keeps planning deterministic).
      // Aborts promptly if the restore is cancelled (back nav bumps the token).
      final results = List<TileAsset?>.filled(p.tiles.length, null);
      var done = 0;

      // Group tile indices into server-sized batches.
      final batches = <List<int>>[];
      for (var s = 0; s < p.tiles.length; s += _restoreBatchSize) {
        final e = (s + _restoreBatchSize).clamp(0, p.tiles.length);
        batches.add([for (var i = s; i < e; i++) i]);
      }

      Future<void> restoreBatch(int b) async {
        final idxs = batches[b];
        final urls = [for (final i in idxs) p.tiles[i].blobUrl];
        final bytesByUrl = await _tilesApi.tileThumbBatch(urls, maxSize: 256);
        if (token != _restoreToken) return;
        for (final i in idxs) {
          final ref0 = p.tiles[i];
          final bytes = bytesByUrl[ref0.blobUrl];
          if (bytes != null) {
            try {
              final id = 'tile-restore-${_ts()}-$i';
              final analyzed =
                  await analyzeTileWithThumbnail(id, ref0.fileName, bytes);
              if (token != _restoreToken) return;
              results[i] = TileAsset(
                id: id,
                descriptor: analyzed.descriptor,
                thumbnail: analyzed.thumbnail,
                blobUrl: ref0.blobUrl,
                filename: ref0.fileName,
              );
            } catch (_) {}
          }
          done++;
          state = state.copyWith(uploadDone: done);
        }
      }

      await _runPool(batches.length, _restoreBatchConcurrency,
          () => token != _restoreToken, restoreBatch);

      if (token != _restoreToken) return; // cancelled — discard partial work
      state = state.copyWith(
          tiles: results.whereType<TileAsset>().toList(), isRestoring: false);
      await buildPlan();
    } catch (e) {
      if (token == _restoreToken) {
        state = state.copyWith(isRestoring: false, error: e.toString());
      }
    }
  }

  /// Streams a blob directly through the authenticated proxy. We omit `maxSize`
  /// so the server does NOT re-encode with Sharp — uploaded tiles are already
  /// ≤600px and base images ≤2000px, so streaming the stored blob is fastest.
  Future<Uint8List?> _proxyBytes(String blobUrl) {
    return ref
        .read(apiClientProvider)
        .getBytes('/api/blob-proxy', query: {'url': blobUrl});
  }

  void reset() {
    _debounce?.cancel();
    state = StudioState(settings: defaultSettings());
  }

  String _ts() => DateTime.now().microsecondsSinceEpoch.toString();
  String _basename(String path) => path.split('/').last.split('\\').last;
}

/// Convenience: is the device able to render? Needs a plan, plus a token —
/// except during the free-render launch bridge ([AppConfig.freeRenders]).
final canRenderProvider = Provider<bool>((ref) {
  final tokens = ref.watch(authControllerProvider).user?.tokenBalance ?? 0;
  final plan = ref.watch(studioControllerProvider).plan;
  return plan != null && (AppConfig.freeRenders || tokens > 0);
});
