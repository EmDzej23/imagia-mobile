import 'dart:async';
import 'dart:io' show ProcessInfo;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'analyze.dart';
import 'grid_layout.dart';
import 'shared.dart';
import 'local_recolor.dart' show labGridToRgb;
import 'looks.dart';
import 'seed_pool.dart';
import 'tile_recolor.dart' show primeTileColorGrid;
import 'tone_fit.dart';
import 'types.dart';

/// Orchestration layer — the Dart equivalent of `foto-mozaik/lib/mosaic/browser.ts`.
///
/// Replaces the browser Canvas pixel path with `dart:ui`: an image is decoded
/// (and resized during decode) to the analysis dimension, then read out as raw
/// RGBA — the exact byte buffer `buildIntegralImage` expects. The heavy layout +
/// matching + SA runs in a background [Isolate]; its inputs (RGBA bytes, tile
/// descriptors, settings) are all plain sendable data, so the boundary is clean.

/// Tile analysis dimension used by the studio (matches web
/// `STUDIO_TILE_ANALYSIS_DIMENSION` in browser.ts).
const int _studioTileAnalysisDimension = 120;

Future<ui.Image> _decode(
  Uint8List bytes, {
  int? targetWidth,
  int? targetHeight,
}) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// An image's pixel size from its header alone — no decode. (Decoding a whole photo
/// just to learn its size used to be the most expensive step of analysing a tile.)
Future<({int width, int height})> _probeSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final size = (width: desc.width, height: desc.height);
  desc.dispose();
  buffer.dispose();
  return size;
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

/// Builds the small base-overlay image used for the tinted base overlay.
///
/// Mirrors the web's blur trick (`getTintOverlayIntermediateDims` in render.ts):
/// the base is decoded down to a tiny intermediate (short side 100px when
/// `baseBlur > 0`, else 200px); the preview painter then scales it *up* to the
/// mosaic, and the bilinear upscale produces the blur. There is no continuous
/// blur radius — any `baseBlur > 0` is "blurred", `0` is "sharp", exactly as web.
Future<ui.Image> buildOverlayImage(
  Uint8List baseBytes, {
  double baseBlur = 1,
}) async {
  final probe = await _probeSize(baseBytes);
  final w = probe.width, h = probe.height;

  final overlayShort = baseBlur > 0 ? 100 : 200;
  final snapShort = math.max(1, math.min(w, h));
  final iw = math.max(1, (w * overlayShort / snapShort).round());
  final ih = math.max(1, (h * overlayShort / snapShort).round());
  return _decode(baseBytes, targetWidth: iw, targetHeight: ih);
}

/// Decodes a small thumbnail (long side [maxSize]) for preview rendering.
Future<ui.Image> decodeThumbnail(Uint8List bytes, int maxSize) async {
  final probe = await _probeSize(bytes);
  final w = probe.width, h = probe.height;
  final scale = maxSize / (w > h ? w : h);
  if (scale >= 1) return _decode(bytes);
  return _decode(
    bytes,
    targetWidth: (w * scale).round(),
    targetHeight: (h * scale).round(),
  );
}

/// Analyzes a single tile image into a [TileDescriptor]. Runs on the calling
/// isolate (light per-tile work); decode is via `dart:ui`.
Future<TileDescriptor> analyzeTile(
  String id,
  String name,
  Uint8List bytes,
) async {
  final probe = await _probeSize(bytes);
  return _analyzeFromProbe(id, name, bytes, probe.width, probe.height);
}

/// Analyzes a tile AND produces its preview thumbnail from a single probe
/// decode (the thumbnail is GPU-resized from the probe rather than re-decoded).
/// Cuts per-tile work from ~4 decodes to 2 — important when restoring a large
/// library. Returns the descriptor + a [ui.Image] thumbnail (≤[thumbSize] px).
Future<({TileDescriptor descriptor, ui.Image thumbnail})>
analyzeTileWithThumbnail(
  String id,
  String name,
  Uint8List bytes, {
  int thumbSize = 200,
}) async {
  final probe = await _probeSize(bytes);
  final srcW = probe.width, srcH = probe.height;
  final thumbnail = await _tileThumbnail(bytes, srcW, srcH, thumbSize);
  try {
    final descriptor = await _analyzeFromProbe(
      id,
      name,
      bytes,
      srcW,
      srcH,
      gridFor: thumbnail,
    );
    return (descriptor: descriptor, thumbnail: thumbnail);
  } catch (e) {
    thumbnail.dispose();
    rethrow;
  }
}

/// A tile's preview thumbnail (long side ≤[thumbSize]) — what
/// [analyzeTileWithThumbnail] makes, for a tile whose analysis was kept on disk.
Future<ui.Image> decodeTileThumbnail(
  Uint8List bytes, {
  int thumbSize = 200,
}) async {
  final probe = await _probeSize(bytes);
  return _tileThumbnail(bytes, probe.width, probe.height, thumbSize);
}

// The thumbnail is DECODED at its size, not drawn from a full-size decode on the
// GPU: a Picture.toImage per tile kept that image (and an offscreen render target)
// alive in graphics memory until GC — ~0.5 GB on a 500-tile restore, enough to get
// the app killed on 2–3 GB phones. The size comes from the header alone.
Future<ui.Image> _tileThumbnail(
  Uint8List bytes,
  int srcW,
  int srcH,
  int thumbSize,
) {
  final longSide = srcW > srcH ? srcW : srcH;
  final scale = thumbSize / longSide;
  if (scale >= 1) return _decode(bytes);
  return _decode(
    bytes,
    targetWidth: math.max(1, (srcW * scale).round()),
    targetHeight: math.max(1, (srcH * scale).round()),
  );
}

Future<TileDescriptor> _analyzeFromProbe(
  String id,
  String name,
  Uint8List bytes,
  int srcWi,
  int srcHi, {
  ui.Image? gridFor,
}) async {
  final srcW = srcWi.toDouble();
  final srcH = srcHi.toDouble();
  final dims = getAnalysisDimensions(srcW, srcH, _studioTileAnalysisDimension);
  final img = await _decode(
    bytes,
    targetWidth: dims.sampleWidth,
    targetHeight: dims.sampleHeight,
  );
  final rgba = await _rgba(img);
  img.dispose();

  // The live preview's recolour needs each thumbnail's colour grid; these pixels are
  // the same photo, so it comes from them instead of a GPU read-back per thumbnail
  // (hundreds of stalls on the raster thread — slow on Android).
  if (gridFor != null) {
    primeTileColorGrid(gridFor, rgba, dims.sampleWidth, dims.sampleHeight);
  }

  final integral = buildIntegralImage(
    rgba,
    dims.sampleWidth,
    dims.sampleHeight,
  );
  final region = sampleRegionFromIntegral(
    0,
    0,
    srcW,
    srcH,
    srcW,
    srcH,
    integral,
  );

  return createTileDescriptor(
    id,
    name,
    srcW,
    srcH,
    region.averageColor,
    region.detailScore,
    region.subregionColors,
    region.subregionEdges,
    region.contrastMap,
    region.luminanceBalance,
    region.colorVariance,
    region.edgeOrientation,
    region.tonalHistogram,
    region.subregionEdgeOrientations,
  );
}

/// GPU-resizes an already-decoded image (no re-decode).

class _PlanArgs {
  _PlanArgs(
    this.rgba,
    this.sampleW,
    this.sampleH,
    this.sourceW,
    this.sourceH,
    this.settings,
    this.tiles,
    this.faces,
    this.isMobile,
  );
  final Uint8List rgba;
  final int sampleW;
  final int sampleH;
  final double sourceW;
  final double sourceH;
  final MosaicSettings settings;
  final List<TileDescriptor> tiles;
  final List<FaceRect> faces;
  final bool isMobile;

  _PlanArgs withPixels(Uint8List px) => _PlanArgs(
    px,
    sampleW,
    sampleH,
    sourceW,
    sourceH,
    settings,
    tiles,
    faces,
    isMobile,
  );

  /// For the worker's port. The pixels go as a transferable buffer (moved, not
  /// copied); the rest is copied like any isolate message.
  List<Object?> toMessage() => [
    rgba.isEmpty ? null : TransferableTypedData.fromList([rgba]),
    sampleW,
    sampleH,
    sourceW,
    sourceH,
    settings,
    tiles,
    faces,
    isMobile,
  ];

  static _PlanArgs fromMessage(List<Object?> m) => _PlanArgs(
    m[0] == null
        ? Uint8List(0)
        : (m[0] as TransferableTypedData).materialize().asUint8List(),
    m[1] as int,
    m[2] as int,
    m[3] as double,
    m[4] as double,
    m[5] as MosaicSettings,
    (m[6] as List).cast<TileDescriptor>(),
    (m[7] as List).cast<FaceRect>(),
    m[8] as bool,
  );
}

/// Pure layout entry point (runs in the background isolate). Builds the integral
/// image from RGBA bytes, runs the full pipeline, and returns a slim plan.
Future<SlimMosaicPlan> _runLayout(_PlanArgs a) =>
    _layoutWith(_analyzerFor(a), a);

ImageAnalyzer _analyzerFor(_PlanArgs a) => ImageAnalyzer.fromPixels(
  a.rgba,
  a.sampleW,
  a.sampleH,
  a.sourceW,
  a.sourceH,
  colorBoost: a.settings.colorBoost,
  autoContrast: a.settings.autoContrast,
);

/// [helpers]: helper isolates (seed_pool.dart) — the same plan, parts of it side by
/// side: the annealing seeds on the first [annealSeedHelpers] of them (modes that
/// anneal seeds), the optimiser's candidates on the next one (or the first, in modes
/// without seeds). None: everything here, one after another.
Future<SlimMosaicPlan> _layoutWith(
  ImageAnalyzer analyzer,
  _PlanArgs a, {
  void Function(SlimMosaicPlan draft)? onDraft,
  List<SendPort> helpers = const [],
}) async {
  final s = a.settings;

  // "Fit light to your photos": the matcher sees the photo's brightness fitted to the
  // library's; the plan keeps the true photo colours (restored below). Web: browser.ts.
  // The look (looks.dart): photo and tiles are both compared through it. Web: browser.ts.
  final matchAnalyzer = lookAnalyzer(
    toneFitAnalyzer(analyzer, a.tiles, s.fitLightToLibrary),
    s.look,
  );
  final tiles = lookTiles(a.tiles, s.look);
  // Not with "fit light": its draft would need the true photo restored, which
  // mutates the cells the remaining passes still work on.
  final draft = onDraft == null || !identical(matchAnalyzer, analyzer)
      ? null
      : (List<MosaicPlacement> placements) =>
            onDraft(_toSlim(a.sourceW, a.sourceH, s, placements));
  final seeds = modeAnnealsSeeds(s.mosaicMode);
  final candidateHelper = seeds
      ? (helpers.length > annealSeedHelpers ? helpers[annealSeedHelpers] : null)
      : (helpers.isNotEmpty ? helpers.first : null);
  final placements =
      (seeds && helpers.length >= annealSeedHelpers) || candidateHelper != null
      ? await buildGridLayoutParallel(
          baseWidth: a.sourceW,
          baseHeight: a.sourceH,
          analyzer: matchAnalyzer,
          tiles: tiles,
          settings: s,
          faceRegions: a.faces,
          isMobile: a.isMobile,
          onDraft: draft,
          runSeeds: (job, attempts) => runSeedsOn(helpers, job, attempts),
          runBatch: (batch) => runBatchOn(helpers, batch),
          runCandidates: candidateHelper == null
              ? null
              : (job) => runCandidatesOn(candidateHelper, job),
        )
      : buildGridLayout(
          baseWidth: a.sourceW,
          baseHeight: a.sourceH,
          analyzer: matchAnalyzer,
          tiles: tiles,
          settings: s,
          faceRegions: a.faces,
          isMobile: a.isMobile,
          onDraft: draft,
        );
  if (!identical(matchAnalyzer, analyzer)) {
    restoreTruePhoto(placements, analyzer);
  }
  return _toSlim(a.sourceW, a.sourceH, s, placements);
}

SlimMosaicPlan _toSlim(
  double baseWidth,
  double baseHeight,
  MosaicSettings settings,
  List<MosaicPlacement> placements,
) {
  return SlimMosaicPlan(
    baseWidth: baseWidth,
    baseHeight: baseHeight,
    outputWidth: settings.outputWidth,
    outputHeight: getOutputHeight(baseWidth, baseHeight, settings.outputWidth),
    tintStrength: settings.tintStrength,
    baseBlur: settings.baseBlur,
    outputSaturation: settings.outputSaturation,
    tileRecolor: settings.tileRecolor,
    look: settings.look,
    // Square cells are ambiguous about which part of a non-square tile to keep — anchor
    // portrait tiles to the top (faces) and leave landscape tiles centred.
    cropPortraitTop: settings.mosaicMode == 'square',
    // Hexagon cells are reconstructed on the server from the SAME x/y/width/height
    // every mode sends, so this flag is the only thing that distinguishes them.
    hexagon: settings.mosaicMode == 'hexagon',
    placements: placements
        .map(
          (p) => SlimPlacement(
            index: p.index,
            x: p.x,
            y: p.y,
            width: p.width,
            height: p.height,
            tileId: p.tileId,
            regionAvgColor: [
              p.averageColor.r,
              p.averageColor.g,
              p.averageColor.b,
            ],
            regionGrid: labGridToRgb([
              for (final c in p.subregionColors) [c.L, c.a, c.b],
            ]),
            // 3D cubes: the cell is a parallelogram, and x/y/width/height describe
            // only the matcher's sample rect. Without these the export falls back to
            // rectangles and silently loses the whole effect.
            quad: p.quad,
            face: p.face,
          ),
        )
        .toList(),
  );
}

/// Builds a mosaic plan for the given base image bytes and analyzed tiles.
///
/// [previewDensity] (when provided) overrides `settings.density` so the live
/// preview can rebuild at a lower region count while a slider is dragging; pass
/// null for the full-quality build. The whole layout runs in an [Isolate] when
/// [useIsolate] is true (default) so the UI never blocks.
///
/// [onDraft] gets a first plan early when the build is slow (see [_draftAfterMs]): the
/// cells and a first choice of photo, before the optimisation passes. The returned
/// plan is the finished one, the same with or without a draft.
Future<SlimMosaicPlan> buildMosaicPlan({
  required Uint8List baseBytes,
  required List<TileDescriptor> tiles,
  required MosaicSettings rawSettings,
  List<FaceRect> faces = const [],
  bool isMobile = true,
  bool useIsolate = true,
  int? previewDensity,
  void Function(SlimMosaicPlan draft)? onDraft,
  int draftAfterMs = _draftAfterMs,
}) async {
  var settings = sanitizeSettings(rawSettings);
  if (previewDensity != null) {
    settings = sanitizeSettings(
      MosaicSettings(
        mosaicMode: settings.mosaicMode,
        density: previewDensity.toDouble(),
        outputWidth: settings.outputWidth,
        reusePenalty: settings.reusePenalty,
        aspectWeight: settings.aspectWeight,
        detailWeight: settings.detailWeight,
        minBlockSize: settings.minBlockSize,
        maxBlockSize: settings.maxBlockSize,
        tintStrength: settings.tintStrength,
        baseBlur: settings.baseBlur,
        colorBoost: settings.colorBoost,
        autoContrast: settings.autoContrast,
        signalWeights: settings.signalWeights,
        look: settings.look,
      ),
    );
  }

  final probe = await _probeSize(baseBytes);
  final srcW = probe.width.toDouble();
  final srcH = probe.height.toDouble();

  // Analysis dimension: mirrors browser.ts — the SAME on every device. Phones used to
  // analyse at 800, so at higher densities each cell's 5×5 samples were 1–2 px and a
  // phone chose different (and clearly worse) tiles than the web for the same photo —
  // most visibly under "Max N", where cells must take photos past their best few.
  final analysisDim = settings.density > 200
      ? 1600
      : settings.density > 120
      ? 1400
      : 1000;
  final dims = getAnalysisDimensions(srcW, srcH, analysisDim);

  Future<Uint8List> pixels() async {
    final img = await _decode(
      baseBytes,
      targetWidth: dims.sampleWidth,
      targetHeight: dims.sampleHeight,
    );
    final rgba = await _rgba(img);
    img.dispose();
    return rgba;
  }

  if (useIsolate) {
    return _LayoutWorker.instance.run(
      // The photo's analysis depends only on these; the worker keeps it between builds.
      analysisKey:
          '${_bytesId(baseBytes)}/${dims.sampleWidth}x${dims.sampleHeight}'
          '/${settings.colorBoost}/${settings.autoContrast}',
      pixels: pixels,
      onDraft: onDraft,
      draftAfterMs: draftAfterMs,
      args: _PlanArgs(
        Uint8List(0),
        dims.sampleWidth,
        dims.sampleHeight,
        srcW,
        srcH,
        settings,
        tiles,
        faces,
        isMobile,
      ),
    );
  }

  final rgba = await pixels();
  final args = _PlanArgs(
    rgba,
    dims.sampleWidth,
    dims.sampleHeight,
    srcW,
    srcH,
    settings,
    tiles,
    faces,
    isMobile,
  );

  return _runLayout(args);
}

/// A stable id per base-photo buffer (the same bytes object = the same photo).
final Expando<int> _bytesIds = Expando('baseBytesId');
int _nextBytesId = 0;
int _bytesId(Uint8List bytes) => _bytesIds[bytes] ??= ++_nextBytesId;

/// Frees the layout worker and the photo analysis it keeps (≈150–200 MB). Call when
/// leaving the studio; the next plan starts a new one.
void releaseLayoutWorker() => _LayoutWorker.instance.release();

/// A long-lived background isolate for the layout.
///
/// Building the photo's analysis (the integral image) took ~a quarter of every plan
/// and allocated ~150–200 MB each time — on every slider change, although the photo
/// had not changed. The worker builds it once per photo + analysis setting and keeps
/// it, so a settings change only re-runs the matching. Heavy allocation churn was a
/// large part of why the studio felt slower on Android than on iPhone.
///
/// One build at a time. A newer build arriving while one runs kills that one — its
/// result would be thrown away anyway — and starts afresh (no worse than before).
class _LayoutWorker {
  _LayoutWorker._();
  static final _LayoutWorker instance = _LayoutWorker._();

  Isolate? _isolate;
  SendPort? _send;
  ReceivePort? _inbox;

  /// Seed helpers for the worker (seed_pool.dart) — started, and killed, with it.
  final List<Isolate> _helpers = [];
  final List<SendPort> _helperPorts = [];
  String? _heldKey; // whose analysis the worker holds
  int _nextId = 0;
  int? _runningId;
  final Map<int, Completer<Object?>> _waiting = {};

  final Map<int, void Function(SlimMosaicPlan)> _drafts = {};

  Future<SlimMosaicPlan> run({
    required String analysisKey,
    required Future<Uint8List> Function() pixels,
    required _PlanArgs args,
    void Function(SlimMosaicPlan draft)? onDraft,
    int draftAfterMs = _draftAfterMs,
  }) async {
    if (_runningId != null) _restart(); // stale build: drop it
    try {
      await _start();
    } catch (_) {
      // No worker (should not happen): the old one-shot isolate.
      final a = args.withPixels(await pixels());
      return Isolate.run(() => _runLayout(a));
    }
    // Seeds on annealSeedHelpers helpers + the optimiser's candidates on one more;
    // modes without seeds only use the one.
    final helpers = modeAnnealsSeeds(args.settings.mosaicMode)
        ? annealSeedHelpers + 1
        : 1;
    await _ensureHelpers(helpers);
    if (_send == null)
      await _start(); // a helper failed and took the worker down
    for (var attempt = 0; attempt < 2; attempt++) {
      final withPixels = _heldKey != analysisKey;
      final job = withPixels ? args.withPixels(await pixels()) : args;
      final id = ++_nextId;
      final done = Completer<Object?>();
      _waiting[id] = done;
      if (onDraft != null) _drafts[id] = onDraft;
      _runningId = id;
      _heldKey = analysisKey;
      _send!.send((
        id,
        analysisKey,
        withPixels,
        onDraft == null ? -1 : draftAfterMs,
        job.toMessage(),
        List<SendPort>.of(_helperPorts.take(helpers)),
      ));
      final reply = await done.future;
      _drafts.remove(id);
      if (_runningId == id) _runningId = null;
      if (reply is SlimMosaicPlan) return reply;
      if (reply == _missing) {
        _heldKey = null; // the worker lost it (restarted): send the pixels
        continue;
      }
      throw reply ?? StateError('Layout stopped');
    }
    throw StateError('Layout failed');
  }

  Future<void> _start() async {
    if (_send != null) return;
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    inbox.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg == null) {
        // onExit: the worker died (e.g. killed for memory). Next build starts anew.
        if (identical(_inbox, inbox)) _failAll(StateError('Layout stopped'));
      } else if (msg is List) {
        // onError: [error, stack] as strings.
        if (identical(_inbox, inbox)) _failAll(StateError('${msg.first}'));
      } else if (msg is (int, _Draft)) {
        _drafts[msg.$1]?.call(msg.$2.plan);
      } else if (msg is (int, Object?)) {
        _waiting.remove(msg.$1)?.complete(msg.$2);
      }
    });
    _inbox = inbox;
    _isolate = await Isolate.spawn(
      _workerMain,
      inbox.sendPort,
      onExit: inbox.sendPort,
      onError: inbox.sendPort,
      debugName: 'layout',
    );
    _send = await ready.future;
  }

  /// Starts [count] helpers (once per worker; more only when a mode needs more).
  /// Optional: without them the work runs on the worker, one part after another.
  Future<void> _ensureHelpers(int count) async {
    final inbox = _inbox;
    if (inbox == null || _helperPorts.length >= count) return;
    try {
      while (_helperPorts.length < count) {
        final (iso, port) = await spawnSeedHelper();
        if (!identical(_inbox, inbox)) {
          iso.kill(
            priority: Isolate.immediate,
          ); // the worker was replaced meanwhile
          return;
        }
        // A helper that dies mid-build would leave the worker waiting for its seed:
        // treat it like the worker dying (the next build starts afresh).
        iso.addOnExitListener(inbox.sendPort);
        iso.addErrorListener(inbox.sendPort);
        _helpers.add(iso);
        _helperPorts.add(port);
      }
    } catch (_) {
      _killHelpers();
    }
  }

  void _killHelpers() {
    for (final h in _helpers) {
      h.kill(priority: Isolate.immediate);
    }
    _helpers.clear();
    _helperPorts.clear();
  }

  void _failAll(Object error) {
    _killHelpers();
    final all = _waiting.values.toList();
    _waiting.clear();
    _drafts.clear();
    _send = null;
    _heldKey = null;
    _runningId = null;
    _isolate = null;
    _inbox?.close();
    _inbox = null;
    for (final c in all) {
      if (!c.isCompleted) c.complete(error);
    }
  }

  void _restart() {
    _isolate?.kill(priority: Isolate.immediate);
    _failAll(StateError('Superseded by a newer build'));
  }

  void release() {
    _isolate?.kill(priority: Isolate.immediate);
    _failAll(StateError('Layout worker released'));
  }
}

/// Reply meaning "I don't hold that photo's analysis — send the pixels".
const String _missing = 'missing-analysis';

/// A first plan, sent ahead of the finished one.
class _Draft {
  _Draft(this.plan);
  final SlimMosaicPlan plan;
}

/// A draft is only worth showing when the finished plan is seconds away. Reaching the
/// first match takes about a fifth of a build: past this, the whole build will take
/// several seconds (slow phones); fast ones finish before a draft would help, and a
/// draft followed straight by the finished plan would only flicker.
const int _draftAfterMs = 900;

void _workerMain(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  String? key;
  ImageAnalyzer? analyzer;
  // One build at a time: the main side kills this isolate before sending another while
  // one runs, so awaiting the seed helpers never interleaves two builds.
  inbox.listen((msg) async {
    final (
      int id,
      String k,
      bool withPixels,
      int draftAfter,
      List<Object?> m,
      List<SendPort> helpers,
    ) = msg as (int, String, bool, int, List<Object?>, List<SendPort>);
    final clock = Stopwatch()..start();
    // One log line per build: where the time goes on this phone (`adb logcat`).
    final trace = <String>[];
    var lap = 0;
    void mark(String stage) {
      final t = clock.elapsedMilliseconds;
      trace.add('$stage ${t - lap}');
      lap = t;
    }

    gridLayoutTrace = mark;
    try {
      final a = _PlanArgs.fromMessage(m);
      mark('receive');
      if (withPixels) {
        analyzer = null; // free the old one before building the new
        analyzer = _analyzerFor(a);
        key = k;
        mark('photo analysis');
      } else if (k != key || analyzer == null) {
        toMain.send((id, _missing));
        return;
      }
      final plan = await _layoutWith(
        analyzer!,
        a,
        helpers: helpers,
        onDraft: draftAfter < 0
            ? null
            : (draft) {
                if (clock.elapsedMilliseconds >= draftAfter) {
                  toMain.send((id, _Draft(draft)));
                }
              },
      );
      mark('finish');
      final mb = (int b) => b >> 20;
      print(
        '[plan] memory ${mb(ProcessInfo.currentRss)} MB now, '
        '${mb(ProcessInfo.maxRss)} MB peak',
      );
      print(
        '[plan] ${a.settings.mosaicMode} ${plan.placements.length} cells, '
        '${a.tiles.length} photos, ${helpers.length} helpers: '
        '${clock.elapsedMilliseconds} ms (${trace.join(', ')})',
      );
      toMain.send((id, plan));
    } catch (e) {
      toMain.send((id, StateError('$e')));
    }
  });
}
