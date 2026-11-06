import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../collage/collage_renderer.dart';
import '../mosaic/types.dart';
import 'auth_controller.dart';
import 'studio_controller.dart';
import '../core/friendly_error.dart';

/// Collage mode, app side — the port of the web's useCollagePieces
/// (foto-mozaik/lib/collage/use-collage-pieces.ts).
///
/// Every photo starts WHOLE. A photo is cut out of its background only when the user
/// selects it in Manage tiles and taps "Cut out" ([cut]); each photo is cut once —
/// finished cut-outs are kept in the settings (`collageCuts`, saved with the project,
/// the same keys as the web), so reopening or switching never asks the server again.
///
/// Layout inputs stay stable while images upgrade: a whole photo's aspect comes from
/// the tile, its important part (`keep`) from the tile thumbnail, so the pile does not
/// rearrange when a sharper preview image lands.

/// What the user sees for a photo in Manage tiles.
enum CutState { full, cutting, cutout, failed }

class CollageState {
  const CollageState({
    this.version = 0,
    this.busy = const {},
    this.failed = const {},
  });

  /// Bumped whenever images, keeps or cuts change (pieces must be rebuilt).
  final int version;

  /// Photos (by uploaded-photo key) whose cut-out is being made.
  final Set<String> busy;

  /// Photos whose cut failed, with the reason the server gave.
  final Map<String, String?> failed;

  CollageState copyWith({
    int? version,
    Set<String>? busy,
    Map<String, String?>? failed,
  }) => CollageState(
    version: version ?? this.version,
    busy: busy ?? this.busy,
    failed: failed ?? this.failed,
  );
}

/// Cut-out requests in flight at once (one photo each).
const int _parallelCuts = 12;

/// Long side the zoomed preview redraws photos from.
const int collageHiRes = 1600;

/// Preview image size by photo count — the more photos, the smaller each one shows.
/// 0 = draw from the tile thumbnails (already in memory): past 200 photos a preview
/// image each would hold hundreds of MB on a phone; zoom still loads sharp copies.
int _previewSize(int n) => n <= 40 ? 640 : (n <= 120 ? 480 : (n <= 200 ? 320 : 0));

/// One key per uploaded photo, whatever tile it sits in.
String srcKey(String url) => url.split('?').first;

final collageControllerProvider =
    NotifierProvider<CollageController, CollageState>(CollageController.new);

class CollageController extends Notifier<CollageState> {
  final Map<String, ui.Image> _full = {}; // tile id → preview image
  final Map<String, ui.Image> _cut = {}; // cut key → cut-out preview image
  final Map<String, PieceMask> _masks = {}; // cut key → silhouette grid
  final Map<String, Box> _keeps = {}; // tile id → important part
  final Set<String> _loading = {};
  int _previewFor = 0;

  /// Reshuffle counter — a new random pile for the same photos (not saved, like
  /// the web). The export uses the same value, so it renders the pile on screen.
  int seedNonce = 0;

  void reshuffle() {
    seedNonce++;
    _bump();
  }

  @override
  CollageState build() => const CollageState();

  StudioState get _studio => ref.read(studioControllerProvider);

  Future<Uint8List?> _proxy(String url, [int? maxSize]) => ref
      .read(apiClientProvider)
      .getBytes(
        '/api/blob-proxy',
        query: {'url': url, if (maxSize != null) 'maxSize': '$maxSize'},
      );

  /// Bytes of a photo's sharp copy for the zoomed preview (cut-out or whole).
  Future<Uint8List?> hiResBytes(String tileId) {
    final t = _tileById(tileId);
    if (t == null) return Future.value(null);
    final cut = _cutFor(t);
    if (_wantsCut(t.id) && cut != null) return _proxy(cut.cutUrl, collageHiRes);
    return _proxy(t.blobUrl, collageHiRes);
  }

  TileAsset? _tileById(String id) {
    for (final t in _studio.tiles) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool _wantsCut(String id) => _studio.settings.collageKinds?[id] == 'cutout';

  /// The saved cut-out for a tile, if it was made from this same photo.
  CollageCut? _cutFor(TileAsset t) {
    final c = _studio.settings.collageCuts?[t.id];
    if (c == null || srcKey(c.src) != srcKey(t.blobUrl)) return null;
    return c;
  }

  /// The photos in the collage (every tile, once — capped).
  List<TileAsset> get photos {
    final tiles = _studio.tiles;
    return tiles.length > collageMaxPhotos
        ? tiles.sublist(0, collageMaxPhotos)
        : tiles;
  }

  Future<ui.Image?> _decode(Uint8List? bytes) async {
    if (bytes == null) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final f = await codec.getNextFrame();
      codec.dispose();
      return f.image;
    } catch (_) {
      return null;
    }
  }

  void _bump() => state = state.copyWith(version: state.version + 1);

  /// Load what the pile needs: each photo's important part (from its thumbnail),
  /// its preview image, and the cut-out image of photos shown cut. Cheap to call
  /// often — only missing pieces are fetched.
  void ensureLoaded() {
    final list = photos;
    final size = _previewSize(list.length);
    if (size != _previewFor) {
      // Photo count moved across a size step — keep what we have, new loads use it.
      _previewFor = size;
    }
    for (final t in list) {
      if (!_keeps.containsKey(t.id) && _loading.add('keep:${t.id}')) {
        importanceBox(t.thumbnail).then((k) {
          _keeps[t.id] = k;
          _loading.remove('keep:${t.id}');
          _bump();
        });
      }
      if (size > 0 && !_full.containsKey(t.id) && _loading.add('full:${t.id}')) {
        _proxy(t.blobUrl, size).then(_decode).then((img) {
          _loading.remove('full:${t.id}');
          if (img != null) {
            _full[t.id] = img;
            _bump();
          }
        });
      }
      final cut = _wantsCut(t.id) ? _cutFor(t) : null;
      if (cut != null) {
        final key = srcKey(cut.cutPreviewUrl);
        if (!_cut.containsKey(key) && _loading.add('cut:$key')) {
          _proxy(cut.cutPreviewUrl).then(_decode).then((img) async {
            if (img != null) {
              _masks[key] = await buildPieceMask(img);
              _cut[key] = img;
              _bump();
            }
            _loading.remove('cut:$key');
          });
        }
      }
    }
  }

  /// The pieces to lay, in collage order. A cut-out joins as a cut-out only once its
  /// image is in (until then it stays whole); a whole photo waits for its keep box.
  List<PilePiece> pieces() {
    final hero = _studio.settings.collageHero;
    final out = <PilePiece>[];
    for (final t in photos) {
      final cut = _wantsCut(t.id) ? _cutFor(t) : null;
      final cutImg = cut == null ? null : _cut[srcKey(cut.cutPreviewUrl)];
      if (cut != null && cutImg != null) {
        out.add(
          PilePiece(
            id: t.id,
            kind: 'cutout',
            image: cutImg,
            aspect: cutImg.width / cutImg.height,
            hero: t.id == hero,
            mask: _masks[srcKey(cut.cutPreviewUrl)],
          ),
        );
        continue;
      }
      final keep = _keeps[t.id];
      if (keep == null) continue;
      out.add(
        PilePiece(
          id: t.id,
          kind: 'full',
          image: _full[t.id] ?? t.thumbnail,
          aspect: t.descriptor.aspectRatio,
          hero: t.id == hero,
          keep: keep,
        ),
      );
    }
    return out;
  }

  CutState stateOf(String id) {
    if (!_wantsCut(id)) return CutState.full;
    final t = _tileById(id);
    if (t == null) return CutState.full;
    final key = srcKey(t.blobUrl);
    final cut = _cutFor(t);
    if (cut == null) {
      if (state.busy.contains(key)) return CutState.cutting;
      if (state.failed.containsKey(key)) return CutState.failed;
      return CutState.full;
    }
    return _cut.containsKey(srcKey(cut.cutPreviewUrl))
        ? CutState.cutout
        : CutState.cutting;
  }

  String? failReason(String id) {
    final t = _tileById(id);
    return t == null ? null : state.failed[srcKey(t.blobUrl)];
  }

  /// The cut-out image of a photo (for Manage tiles), if it has one.
  ui.Image? cutThumb(String id) {
    final t = _tileById(id);
    if (t == null || !_wantsCut(id)) return null;
    final cut = _cutFor(t);
    return cut == null ? null : _cut[srcKey(cut.cutPreviewUrl)];
  }

  /// Photos still being cut.
  int get cutting =>
      photos.where((t) => stateOf(t.id) == CutState.cutting).length;

  /// Ready to export: something to draw for every photo, no cut-out on its way.
  bool get settled {
    final list = photos;
    return list.isNotEmpty && cutting == 0 && pieces().length == list.length;
  }

  /// For the export: the file Cloud Run draws for a photo.
  String? sourceFor(String id, String kind) {
    final t = _tileById(id);
    if (t == null) return null;
    final cut = _cutFor(t);
    if (kind == 'cutout' && cut != null) return cut.cutUrl;
    return t.blobUrl;
  }

  /// Mark photos as cut-out / whole. Cutting is requested ONLY here.
  void setCut(Iterable<String> ids, bool cutOut) {
    final studio = ref.read(studioControllerProvider.notifier);
    final s = _studio.settings;
    final kinds = Map<String, String>.of(s.collageKinds ?? const {});
    for (final id in ids) {
      kinds[id] = cutOut ? 'cutout' : 'full';
    }
    studio.updateSettings(s.copyWith(collageKinds: kinds));
    if (cutOut) {
      _cutPhotos(ids.toList());
    } else {
      // A failed cut is forgotten when the photo goes back to whole, so asking again
      // retries.
      final failed = Map<String, String?>.of(state.failed);
      for (final id in ids) {
        final t = _tileById(id);
        if (t != null) failed.remove(srcKey(t.blobUrl));
      }
      state = state.copyWith(failed: failed);
    }
    _bump();
  }

  void setHero(String? id) {
    final studio = ref.read(studioControllerProvider.notifier);
    studio.updateSettings(_studio.settings.copyWith(collageHero: id ?? ''));
    _bump();
  }

  Future<void> _cutPhotos(List<String> ids) async {
    final want = ids.toSet();
    final seen = <String>{};
    final queue = <TileAsset>[];
    for (final t in photos) {
      if (!want.contains(t.id)) continue;
      final key = srcKey(t.blobUrl);
      if (_cutFor(t) != null ||
          seen.contains(key) ||
          state.busy.contains(key)) {
        continue;
      }
      seen.add(key);
      queue.add(t);
    }
    if (queue.isEmpty) {
      ensureLoaded();
      return;
    }
    final failed = Map<String, String?>.of(state.failed);
    for (final k in seen) {
      failed.remove(k);
    }
    state = state.copyWith(busy: {...state.busy, ...seen}, failed: failed);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final t = queue.removeAt(0);
        final key = srcKey(t.blobUrl);
        String? error;
        try {
          final res = await ref
              .read(apiClientProvider)
              .post<Map<String, dynamic>>(
                '/api/collage/cutouts',
                body: {
                  'items': [
                    {'id': t.id, 'url': t.blobUrl},
                  ],
                },
                // A cold start loads the model before the first photo.
                receiveTimeout: const Duration(minutes: 5),
              );
          if (!res.isOk || res.data == null) {
            error = res.error ?? 'Cut-out failed.';
          } else {
            final results = (res.data!['results'] as List? ?? const [])
                .cast<Map<String, dynamic>>();
            final r = results.where((x) => x['id'] == t.id).firstOrNull;
            if (r != null &&
                r['ok'] == true &&
                r['cutUrl'] is String &&
                r['cutPreviewUrl'] is String) {
              final info = (
                cutUrl: r['cutUrl'] as String,
                cutPreviewUrl: r['cutPreviewUrl'] as String,
                width: (r['width'] as num?)?.toInt() ?? 0,
                height: (r['height'] as num?)?.toInt() ?? 0,
              );
              // Keep it for every tile of this photo.
              final s = _studio.settings;
              final cuts = Map<String, CollageCut>.of(
                s.collageCuts ?? const {},
              );
              for (final q in _studio.tiles) {
                if (srcKey(q.blobUrl) == key) {
                  cuts[q.id] = CollageCut(
                    src: q.blobUrl,
                    cutUrl: info.cutUrl,
                    cutPreviewUrl: info.cutPreviewUrl,
                    width: info.width,
                    height: info.height,
                  );
                }
              }
              ref
                  .read(studioControllerProvider.notifier)
                  .updateSettings(s.copyWith(collageCuts: cuts));
            } else {
              error = r?['error'] as String? ?? 'Cut-out failed.';
            }
          }
        } catch (e) {
          error = friendlyError(e, fallback: "Couldn't cut this photo out.");
        }
        final busy = Set<String>.of(state.busy)..remove(key);
        final failedNow = Map<String, String?>.of(state.failed);
        if (error != null) failedNow[key] = error;
        state = state.copyWith(busy: busy, failed: failedNow);
        ensureLoaded(); // fetch the new cut-out image
        _bump();
      }
    }

    final workers = queue.length < _parallelCuts ? queue.length : _parallelCuts;
    await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  }
}

/// The collage's pile parameters from the studio settings (+ reshuffle nonce).
PileParams collageParamsFrom(StudioState studio, int seedNonce) {
  final s = studio.settings;
  return PileParams(
    format: s.collageFormat,
    rotation: s.collageRotation,
    outline: s.collageOutline,
    shadow: s.collageShadow,
    background: s.collageBackground,
    seedNonce: seedNonce,
  );
}

/// Lay out the pile — in a background isolate for bigger collages (a few hundred
/// photos take a noticeable moment), inline for small ones.
Future<List<PilePlacement>> layPile(List<PilePiece> pieces, PileParams params) {
  final size = formatSize(params.format);
  final light = [for (final p in pieces) p.layoutOnly()];
  if (light.length <= 40) {
    return Future.value(planPile(light, size.w, size.h, params));
  }
  return Isolate.run(() => planPile(light, size.w, size.h, params));
}
