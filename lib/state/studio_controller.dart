import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../ancient/ancient_renderer.dart';
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
    this.textInput = '',
    this.textUppercase = false,
    this.ancientSeedNonce = 0,
    this.wordartSeedNonce = 0,
    this.tileCrops = const {},
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

  // Word-art phrase state (the phrases + uppercase live here, not in settings).
  final String textInput;
  final bool textUppercase;

  /// Ancient-mosaic reshuffle key — bump to get a new stone layout.
  final int ancientSeedNonce;

  /// Word-art reshuffle key — bump to get a new word arrangement.
  final int wordartSeedNonce;

  /// Manual per-tile crops, keyed by tile id — the source of truth. Copied onto the
  /// plan (which carries them to the server) and handed to the preview painters.
  /// Square mode only, mirroring the web: other modes have no crop editor.
  final Map<String, TileCrop> tileCrops;

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
    String? textInput,
    bool? textUppercase,
    int? ancientSeedNonce,
    int? wordartSeedNonce,
    Map<String, TileCrop>? tileCrops,
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
      textInput: textInput ?? this.textInput,
      textUppercase: textUppercase ?? this.textUppercase,
      ancientSeedNonce: ancientSeedNonce ?? this.ancientSeedNonce,
      wordartSeedNonce: wordartSeedNonce ?? this.wordartSeedNonce,
      tileCrops: tileCrops ?? this.tileCrops,
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

  /// Pick a base photo from the library and return its raw bytes + name without
  /// processing it, so the UI can run the crop step first. Null if cancelled.
  Future<({Uint8List bytes, String name})?> pickBaseBytes() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return (bytes: bytes, name: _basename(file.name));
  }

  /// Compress → upload → decode a picked (already-cropped) base image and make
  /// it the active base. Shared by the crop flow and [pickBaseImage].
  Future<void> setBaseFromBytes(Uint8List bytes, String name) async {
    state = state.copyWith(isUploadingBase: true, error: null);
    try {
      final compressed = await _images.compressBase(bytes);
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
          name: name,
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

  /// Pick a base photo and process it directly (no crop step).
  Future<void> pickBaseImage() async {
    final picked = await pickBaseBytes();
    if (picked == null) return;
    await setBaseFromBytes(picked.bytes, picked.name);
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
      // Upload key only — the tile's real id is derived from the blob URL below,
      // so it survives a save/restore (crops are keyed by it).
      final uploadKey = 'tile-${_ts()}-$i';
      try {
        final original = await file.readAsBytes();
        final compressed = await _images.compressTile(original);
        if (compressed.isEmpty) {
          firstError ??= 'Could not read image (unsupported format?)';
          return;
        }
        final filename = '$uploadKey.jpg';
        final upload =
            await _tilesApi.uploadTile(compressed, uploadKey, filename);
        if (!upload.isOk || upload.data == null) {
          firstError ??= upload.error ?? 'Upload failed';
          return;
        }
        final id = stableTileIdFromUrl(upload.data!.blobUrl);
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
              final id = stableTileIdFromUrl(sample.blobUrl);
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
    // Drop the tile's crop with it — leaving it behind would silently re-apply to a
    // re-added photo, since ids are derived from the (unchanged) blob URL.
    final crops = Map<String, TileCrop>.from(state.tileCrops)..remove(id);
    state = state.copyWith(
      tiles: state.tiles.where((t) => t.id != id).toList(),
      tileCrops: crops,
    );
    _applyCropsToPlan(crops);
  }

  // ── Manual tile crops ────────────────────────────────────────────────────
  //
  // NON-DESTRUCTIVE, exactly as on the web: the uploaded file is never rewritten.
  // A crop is metadata the painters and the server compositor read when drawing, so
  // it can be changed or cleared at any time and preview + export follow together.

  /// Set (or with `null`, clear) the manual crop for one tile.
  void setTileCrop(String tileId, TileCrop? crop) {
    final crops = Map<String, TileCrop>.from(state.tileCrops);
    if (crop == null) {
      crops.remove(tileId);
    } else {
      crops[tileId] = crop;
    }
    state = state.copyWith(tileCrops: crops);
    _applyCropsToPlan(crops);
    _scheduleAutoSave();
  }

  /// Keep the live plan's copy in step. The plan object is MUTATED rather than
  /// rebuilt: re-running the matcher for a crop change would be pointless work (the
  /// matching is unaffected) and would cross-fade the preview. A new map instance is
  /// what the painters compare, so the repaint still happens.
  void _applyCropsToPlan(Map<String, TileCrop> crops) {
    state.plan?.tileCrops = crops;
  }

  // ── Word-art phrases ─────────────────────────────────────────────────────

  void setTextInput(String v) {
    state = state.copyWith(textInput: v);
    _scheduleAutoSave();
  }

  void setTextUppercase(bool v) {
    state = state.copyWith(textUppercase: v);
    _scheduleAutoSave();
  }

  // ── Ancient mosaic ───────────────────────────────────────────────────────

  /// Reshuffle the stone scatter (same look settings, new layout).
  void newAncientLayout() =>
      state = state.copyWith(ancientSeedNonce: state.ancientSeedNonce + 1);

  /// Reshuffle the word arrangement (same look settings, new layout).
  void newWordartLayout() =>
      state = state.copyWith(wordartSeedNonce: state.wordartSeedNonce + 1);

  /// Render the ancient mosaic on-device at [longSide] px and return PNG bytes.
  /// Ancient is client-rendered (no tiles / server), so export is local.
  Future<Uint8List?> renderAncientPng(
      {required bool curved, required int longSide}) async {
    final base = state.base;
    if (base == null) return null;
    final img = base.thumbnail;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final rgba = data.buffer.asUint8List();
    final sw = img.width, sh = img.height;
    final aspect = sw / sh;
    int w, h;
    if (aspect >= 1) {
      w = longSide;
      h = (longSide / aspect).round();
    } else {
      h = longSide;
      w = (longSide * aspect).round();
    }
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    final s = state.settings;
    final shape = curved ? s.ancientShape : 'none';
    final params = AncientParams(
      stoneSize: s.ancientStoneSize,
      grout: s.ancientGrout,
      irregularity: s.ancientIrregularity,
      variation: s.ancientVariation,
      bevel: s.ancientBevel,
      groutColor: s.ancientGroutColor,
      curviness: curved ? s.ancientCurviness : 0,
      shape: shape,
      seedNonce: state.ancientSeedNonce,
    );
    final geo =
        buildAncientGeometry(rgba, sw, sh, w.toDouble(), h.toDouble(), params);
    final sprites =
        (shape != 'none' && shape != 'heart') ? await AncientSprites.load() : null;
    final out = await renderAncientImage(geo, w, h,
        baseImage: shape != 'none' ? img : null, sprites: sprites);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return png?.buffer.asUint8List();
  }

  /// Updates matching settings and schedules a debounced preview rebuild.
  void updateSettings(MosaicSettings settings) {
    state = state.copyWith(settings: settings);
    _debounce?.cancel();
    // Ancient modes render themselves (no tiles / matching), so never kick off
    // the heavy layout isolate — it would run pointlessly and jank the UI.
    final m = settings.mosaicMode;
    // Tile-less modes render themselves (no tiles / matching), so never kick off
    // the heavy layout isolate — it would run pointlessly and jank the UI. Still
    // persist their look settings (+ word-art phrases) via autosave.
    if (m == 'ancient' || m == 'ancient-curved' || m == 'wordart') {
      _scheduleAutoSave();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), buildPlan);
  }

  /// Updates a render-overlay parameter (tint / blur / output saturation). These
  /// don't affect tile matching, so no replan — the preview repaints instantly and
  /// the value is synced into the plan so the server render matches.
  void updateRenderParam(
      {double? tintStrength, double? baseBlur, double? outputSaturation}) {
    final settings = state.settings.copyWith(
        tintStrength: tintStrength,
        baseBlur: baseBlur,
        outputSaturation: outputSaturation);
    final plan = state.plan;
    if (plan != null) {
      if (tintStrength != null) plan.tintStrength = tintStrength;
      if (baseBlur != null) plan.baseBlur = baseBlur;
      if (outputSaturation != null) plan.outputSaturation = outputSaturation;
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
      // The engine knows nothing about crops (they do not affect matching), so the
      // fresh plan is handed the current ones before it reaches the painters.
      plan.tileCrops = state.tileCrops;
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
    final base = state.base;
    if (base == null) return;
    final m = state.settings.mosaicMode;
    final isTileless =
        m == 'ancient' || m == 'ancient-curved' || m == 'wordart';
    // Tile modes need a tile set to be worth saving; tile-less modes persist
    // base + settings + word-art phrases only (they have no tiles).
    if (!isTileless && state.tiles.isEmpty) return;
    final tiles =
        state.tiles
            .map((t) => ProjectTileRef(t.blobUrl, t.filename, tileId: t.id))
            .toList();
    final api = ref.read(projectsApiProvider);
    final id = state.currentProjectId;
    try {
      if (id != null) {
        // Update in place — omit name so the user's project name is preserved.
        await api.update(id,
            baseImageUrl: base?.blobUrl,
            baseImageName: base?.name,
            tiles: tiles,
            settings: state.settings,
            texts: state.textInput,
            // Always sent, including when empty — this is the path a crop change
            // persists through, and {} is how a cleared crop is recorded.
            tileCrops: state.tileCrops);
      } else {
        final res = await api.create(
            name: base?.name ?? 'My mosaic',
            baseImageUrl: base?.blobUrl,
            baseImageName: base?.name,
            tiles: tiles,
            settings: state.settings,
            texts: state.textInput,
            tileCrops: state.tileCrops);
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
        state.tiles
            .map((t) => ProjectTileRef(t.blobUrl, t.filename, tileId: t.id))
            .toList();
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
        texts: state.textInput,
        tileCrops: state.tileCrops,
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
      texts: state.textInput,
      tileCrops: state.tileCrops,
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
          textInput: p.texts ?? '',
          // Keyed by the URL-derived tile id, so they line up with the tiles about
          // to be restored below — and with whatever the web studio saved.
          tileCrops: p.tileCrops,
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
              // A saved id wins (web-created projects have one); otherwise derive
              // the same stable id the web would.
              final id = ref0.tileId ?? stableTileIdFromUrl(ref0.blobUrl);
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
