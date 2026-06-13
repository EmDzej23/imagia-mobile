import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'analyze.dart';
import 'grid_layout.dart';
import 'shared.dart';
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

Future<ui.Image> _decode(Uint8List bytes,
    {int? targetWidth, int? targetHeight}) async {
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: targetWidth, targetHeight: targetHeight);
  final frame = await codec.getNextFrame();
  return frame.image;
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
Future<ui.Image> buildOverlayImage(Uint8List baseBytes,
    {double baseBlur = 1}) async {
  final probe = await _decode(baseBytes);
  final w = probe.width, h = probe.height;
  probe.dispose();

  final overlayShort = baseBlur > 0 ? 100 : 200;
  final snapShort = math.max(1, math.min(w, h));
  final iw = math.max(1, (w * overlayShort / snapShort).round());
  final ih = math.max(1, (h * overlayShort / snapShort).round());
  return _decode(baseBytes, targetWidth: iw, targetHeight: ih);
}

/// Decodes a small thumbnail (long side [maxSize]) for preview rendering.
Future<ui.Image> decodeThumbnail(Uint8List bytes, int maxSize) async {
  final probe = await _decode(bytes);
  final w = probe.width, h = probe.height;
  final scale = maxSize / (w > h ? w : h);
  if (scale >= 1) return probe;
  probe.dispose();
  return _decode(bytes,
      targetWidth: (w * scale).round(), targetHeight: (h * scale).round());
}

/// Analyzes a single tile image into a [TileDescriptor]. Runs on the calling
/// isolate (light per-tile work); decode is via `dart:ui`.
Future<TileDescriptor> analyzeTile(
    String id, String name, Uint8List bytes) async {
  final probe = await _decode(bytes);
  final descriptor =
      await _analyzeFromProbe(id, name, bytes, probe.width, probe.height);
  probe.dispose();
  return descriptor;
}

/// Analyzes a tile AND produces its preview thumbnail from a single probe
/// decode (the thumbnail is GPU-resized from the probe rather than re-decoded).
/// Cuts per-tile work from ~4 decodes to 2 — important when restoring a large
/// library. Returns the descriptor + a [ui.Image] thumbnail (≤[thumbSize] px).
Future<({TileDescriptor descriptor, ui.Image thumbnail})>
    analyzeTileWithThumbnail(String id, String name, Uint8List bytes,
        {int thumbSize = 200}) async {
  final probe = await _decode(bytes);
  final srcW = probe.width, srcH = probe.height;
  final descriptor = await _analyzeFromProbe(id, name, bytes, srcW, srcH);

  final longSide = srcW > srcH ? srcW : srcH;
  final scale = thumbSize / longSide;
  if (scale >= 1) {
    return (descriptor: descriptor, thumbnail: probe);
  }
  final thumb = await _resize(probe, (srcW * scale).round(), (srcH * scale).round());
  probe.dispose();
  return (descriptor: descriptor, thumbnail: thumb);
}

Future<TileDescriptor> _analyzeFromProbe(
    String id, String name, Uint8List bytes, int srcWi, int srcHi) async {
  final srcW = srcWi.toDouble();
  final srcH = srcHi.toDouble();
  final dims = getAnalysisDimensions(srcW, srcH, _studioTileAnalysisDimension);
  final img = await _decode(bytes,
      targetWidth: dims.sampleWidth, targetHeight: dims.sampleHeight);
  final rgba = await _rgba(img);
  img.dispose();

  final integral = buildIntegralImage(rgba, dims.sampleWidth, dims.sampleHeight);
  final region =
      sampleRegionFromIntegral(0, 0, srcW, srcH, srcW, srcH, integral);

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
Future<ui.Image> _resize(ui.Image src, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  return recorder.endRecording().toImage(w, h);
}

class _PlanArgs {
  _PlanArgs(this.rgba, this.sampleW, this.sampleH, this.sourceW, this.sourceH,
      this.settings, this.tiles, this.faces, this.isMobile);
  final Uint8List rgba;
  final int sampleW;
  final int sampleH;
  final double sourceW;
  final double sourceH;
  final MosaicSettings settings;
  final List<TileDescriptor> tiles;
  final List<FaceRect> faces;
  final bool isMobile;
}

/// Pure layout entry point (runs in the background isolate). Builds the integral
/// image from RGBA bytes, runs the full pipeline, and returns a slim plan.
SlimMosaicPlan _runLayout(_PlanArgs a) {
  final analyzer = ImageAnalyzer.fromPixels(
    a.rgba,
    a.sampleW,
    a.sampleH,
    a.sourceW,
    a.sourceH,
    colorBoost: a.settings.colorBoost,
    autoContrast: a.settings.autoContrast,
  );
  final placements = buildGridLayout(
    baseWidth: a.sourceW,
    baseHeight: a.sourceH,
    analyzer: analyzer,
    tiles: a.tiles,
    settings: a.settings,
    faceRegions: a.faces,
    isMobile: a.isMobile,
  );
  return _toSlim(a.sourceW, a.sourceH, a.settings, placements);
}

SlimMosaicPlan _toSlim(double baseWidth, double baseHeight,
    MosaicSettings settings, List<MosaicPlacement> placements) {
  return SlimMosaicPlan(
    baseWidth: baseWidth,
    baseHeight: baseHeight,
    outputWidth: settings.outputWidth,
    outputHeight: getOutputHeight(baseWidth, baseHeight, settings.outputWidth),
    tintStrength: settings.tintStrength,
    baseBlur: settings.baseBlur,
    placements: placements
        .map((p) => SlimPlacement(
              index: p.index,
              x: p.x,
              y: p.y,
              width: p.width,
              height: p.height,
              tileId: p.tileId,
              regionAvgColor: [
                p.averageColor.r,
                p.averageColor.g,
                p.averageColor.b
              ],
            ))
        .toList(),
  );
}

/// Builds a mosaic plan for the given base image bytes and analyzed tiles.
///
/// [previewDensity] (when provided) overrides `settings.density` so the live
/// preview can rebuild at a lower region count while a slider is dragging; pass
/// null for the full-quality build. The whole layout runs in an [Isolate] when
/// [useIsolate] is true (default) so the UI never blocks.
Future<SlimMosaicPlan> buildMosaicPlan({
  required Uint8List baseBytes,
  required List<TileDescriptor> tiles,
  required MosaicSettings rawSettings,
  List<FaceRect> faces = const [],
  bool isMobile = true,
  bool useIsolate = true,
  int? previewDensity,
}) async {
  var settings = sanitizeSettings(rawSettings);
  if (previewDensity != null) {
    settings = sanitizeSettings(MosaicSettings(
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
    ));
  }

  final probe = await _decode(baseBytes);
  final srcW = probe.width.toDouble();
  final srcH = probe.height.toDouble();
  probe.dispose();

  // Analysis dimension: mirrors browser.ts. Mobile holds at 800 to protect
  // memory; desktop tiers up with density.
  final analysisDim = isMobile
      ? 800
      : settings.density > 200
          ? 1600
          : settings.density > 120
              ? 1400
              : 1000;
  final dims = getAnalysisDimensions(srcW, srcH, analysisDim);

  final img = await _decode(baseBytes,
      targetWidth: dims.sampleWidth, targetHeight: dims.sampleHeight);
  final rgba = await _rgba(img);
  img.dispose();

  final args = _PlanArgs(rgba, dims.sampleWidth, dims.sampleHeight, srcW, srcH,
      settings, tiles, faces, isMobile);

  return useIsolate ? await Isolate.run(() => _runLayout(args)) : _runLayout(args);
}
