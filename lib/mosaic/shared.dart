import 'dart:math' as math;
import 'dart:typed_data';

import 'types.dart';

/// Dart port of `foto-mozaik/lib/mosaic/shared.ts` (pure math + helpers).
/// Browser-only helpers (isMobileDevice, yieldToMain, debug timing) are omitted.

const double minDensity = 12;
const double maxDensity = 1000;
const double minOutputWidth = 1200;
const double maxOutputWidth = 25000;

/// Same factor as canvas blur; used by the render overlay.
const double overlayBlurCellFactor = 0.7;

const double _originalCellsPerTile = 3.0;
const double _minTilesOriginalThreshold = 250;

// ── JS-faithful numeric helpers ─────────────────────────────────────────────

double clampD(double value, double min, double max) =>
    math.min(max, math.max(min, value));

/// Replicates JavaScript `Math.round`, which rounds half toward +Infinity
/// (`floor(x + 0.5)`). Dart's `double.round()` rounds half away from zero and
/// would diverge on negative .5 values.
double jsRound(double x) => (x + 0.5).floorToDouble();

double roundChannel(double value) => clampD(jsRound(value), 0, 255);

/// Cube root approximating `Math.cbrt`. Dart lacks a native cbrt; `pow(t,1/3)`
/// alone is ~2-4 ULP off, so we refine with one Newton step toward the true
/// root (x − (x³−a)/(3x²)), bringing it to ≤1 ULP — within libm noise of V8.
double _cbrt(double t) {
  if (t == 0) return 0.0;
  final neg = t < 0;
  final a = neg ? -t : t;
  var x = math.pow(a, 1.0 / 3.0).toDouble();
  x = x - (x * x * x - a) / (3 * x * x);
  return neg ? -x : x;
}

// ── Defaults ────────────────────────────────────────────────────────────────

SignalWeights defaultSignalWeights() => SignalWeights(
      color: 0.55,
      luminancePattern: 0.15,
      chromaPattern: 0.06,
      edgePattern: 0.12,
      tonalHistogram: 0.05,
      brightnessEmphasis: 3.5,
      contrastPattern: 0.08,
    );

MosaicSettings defaultSettings() => MosaicSettings(
      mosaicMode: 'square',
      density: 180,
      outputWidth: 8000,
      reusePenalty: 0.01,
      aspectWeight: 0.08,
      detailWeight: 0.05,
      minBlockSize: 4,
      maxBlockSize: 10,
      tintStrength: 0.4,
      baseBlur: 1,
      colorBoost: 1.0,
      autoContrast: 0,
      signalWeights: defaultSignalWeights(),
    );

bool isMinimumDetailOriginalMode(MosaicSettings settings) {
  if (settings.mosaicMode != 'original') return false;
  final cells = jsRound(math.pow(settings.density / 4, 2).toDouble() * 1.4);
  final tiles = jsRound(cells / _originalCellsPerTile);
  return tiles <= _minTilesOriginalThreshold;
}

TileOrientation getOrientation(double width, double height) {
  final ratio = width / height;
  if (ratio > 1.1) return 'landscape';
  if (ratio < 0.9) return 'portrait';
  return 'square';
}

MosaicSettings sanitizeSettings(MosaicSettings input) {
  final minBlockSize = clampD(jsRound(input.minBlockSize), 2, 10);
  final maxBlockSize = clampD(jsRound(input.maxBlockSize), 6, 18);

  final sw = input.signalWeights;
  final signalWeights = sw != null
      ? SignalWeights(
          color: clampD(sw.color, 0, 1),
          luminancePattern: clampD(sw.luminancePattern, 0, 1),
          chromaPattern: clampD(sw.chromaPattern, 0, 1),
          edgePattern: clampD(sw.edgePattern, 0, 1),
          tonalHistogram: clampD(sw.tonalHistogram, 0, 1),
          brightnessEmphasis: clampD(sw.brightnessEmphasis, 0, 5),
          contrastPattern: clampD(sw.contrastPattern, 0, 1),
        )
      : defaultSignalWeights();

  const validModes = ['original', 'blocks', 'square', 'landscape', 'portrait'];

  return MosaicSettings(
    mosaicMode:
        validModes.contains(input.mosaicMode) ? input.mosaicMode : 'original',
    density: clampD(jsRound(input.density), minDensity, maxDensity),
    outputWidth: clampD(jsRound(input.outputWidth), minOutputWidth, maxOutputWidth),
    reusePenalty: clampD(input.reusePenalty, 0, 1),
    aspectWeight: clampD(input.aspectWeight, 0, 1),
    detailWeight: clampD(input.detailWeight, 0, 1),
    minBlockSize: math.min(minBlockSize, maxBlockSize - 2),
    maxBlockSize: math.max(maxBlockSize, minBlockSize + 2),
    tintStrength: clampD(input.tintStrength, 0, 0.5),
    baseBlur: clampD(input.baseBlur, 0, 5),
    colorBoost: clampD(input.colorBoost, 1.0, 2.0),
    autoContrast: clampD(input.autoContrast, 0, 1),
    signalWeights: signalWeights,
  );
}

double getOutputHeight(double baseWidth, double baseHeight, double outputWidth) =>
    math.max(1, jsRound(outputWidth * baseHeight / baseWidth));

List<RenderPlacement> scalePlacements(
    MosaicPlan plan, double targetWidth, double targetHeight) {
  final scaleX = targetWidth / plan.baseWidth;
  final scaleY = targetHeight / plan.baseHeight;
  return plan.placements.map((p) {
    final x = jsRound(p.x * scaleX);
    final y = jsRound(p.y * scaleY);
    final right = jsRound((p.x + p.width) * scaleX);
    final bottom = jsRound((p.y + p.height) * scaleY);
    return RenderPlacement(
      index: p.index,
      x: x,
      y: y,
      width: math.max(1, right - x),
      height: math.max(1, bottom - y),
    );
  }).toList();
}

// ── Color math ──────────────────────────────────────────────────────────────

double colorDistance(RgbColor left, RgbColor right) {
  final dr = left.r - right.r;
  final dg = left.g - right.g;
  final db = left.b - right.b;
  return math.sqrt(dr * dr + dg * dg + db * db) / 441.6729559300637;
}

double _srgbToLinear(double c) {
  final v = c / 255;
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

const double _labEpsilon = 0.008856;
const double _labKappa = 903.3;

double _labF(double t) =>
    t > _labEpsilon ? _cbrt(t) : (_labKappa * t + 16) / 116;

LabColor rgbToLab(RgbColor rgb) {
  final r = _srgbToLinear(rgb.r);
  final g = _srgbToLinear(rgb.g);
  final b = _srgbToLinear(rgb.b);

  final x = _labF((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047);
  final y = _labF(0.2126729 * r + 0.7151522 * g + 0.072175 * b);
  final z = _labF((0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883);

  return LabColor(116 * y - 16, 500 * (x - y), 200 * (y - z));
}

const double maxLabDistance = 375;

double labDistance(LabColor left, LabColor right) {
  final dL = (left.L - right.L) * 1.5;
  final da = left.a - right.a;
  final db = left.b - right.b;
  return math.sqrt(dL * dL + da * da + db * db) / maxLabDistance;
}

double aspectPenalty(double tileAspectRatio, double regionAspectRatio) {
  final tileIsLandscape = tileAspectRatio > 1.1;
  final tileIsPortrait = tileAspectRatio < 0.9;
  final regionIsLandscape = regionAspectRatio > 1.1;
  final regionIsPortrait = regionAspectRatio < 0.9;

  if ((tileIsPortrait && regionIsLandscape) ||
      (tileIsLandscape && regionIsPortrait)) {
    return 10;
  }

  final raw = (math.log(tileAspectRatio / regionAspectRatio)).abs();
  return raw <= 0.18 ? raw : raw * 4;
}

TileDescriptor createTileDescriptor(
  String id,
  String name,
  double width,
  double height,
  RgbColor averageColor,
  double detailScore,
  SubregionColors? subregionColors,
  SubregionEdges? subregionEdges,
  ContrastMap? contrastMap,
  LuminanceBalance? luminanceBalance,
  double colorVariance,
  double edgeOrientation,
  LuminanceHistogram? tonalHistogram,
  SubregionEdgeOrientations? subregionEdgeOrientations,
) {
  return TileDescriptor(
    id: id,
    name: name,
    width: width,
    height: height,
    aspectRatio: width / height,
    orientation: getOrientation(width, height),
    averageColor: averageColor,
    averageLabColor: rgbToLab(averageColor),
    detailScore: detailScore,
    subregionColors: subregionColors,
    subregionEdges: subregionEdges,
    contrastMap: contrastMap,
    luminanceBalance: luminanceBalance,
    colorVariance: colorVariance,
    edgeOrientation: edgeOrientation,
    tonalHistogram: tonalHistogram,
    subregionEdgeOrientations: subregionEdgeOrientations,
  );
}

/// 5x5 center-weighted Gaussian subregion weights.
const List<double> subregionWeights = [
  0.5, 0.8, 1.0, 0.8, 0.5, //
  0.8, 1.2, 1.5, 1.2, 0.8,
  1.0, 1.5, 2.0, 1.5, 1.0,
  0.8, 1.2, 1.5, 1.2, 0.8,
  0.5, 0.8, 1.0, 0.8, 0.5,
];
final double subregionWeightSum =
    subregionWeights.fold(0.0, (s, w) => s + w);

List<double>? computeCropWeights(double tileAR, double cellAR,
    [List<double>? out]) {
  if ((math.log(tileAR / cellAR)).abs() < 0.05) return null;

  List<double> weights;
  if (out != null) {
    for (var i = 0; i < 25; i++) {
      out[i] = subregionWeights[i];
    }
    weights = out;
  } else {
    weights = List<double>.from(subregionWeights);
  }

  if (tileAR < cellAR) {
    final cropFrac = 1 - tileAR / cellAR;
    final edgeVis = math.max(0, 1 - 1.8 * cropFrac).toDouble();
    final midVis = math.max(0, 1 - 0.8 * cropFrac).toDouble();
    for (var c = 0; c < 5; c++) {
      weights[c] *= edgeVis;
      weights[5 + c] *= midVis;
      weights[15 + c] *= midVis;
      weights[20 + c] *= edgeVis;
    }
  } else {
    final cropFrac = 1 - cellAR / tileAR;
    final edgeVis = math.max(0, 1 - 1.8 * cropFrac).toDouble();
    final midVis = math.max(0, 1 - 0.8 * cropFrac).toDouble();
    for (var r = 0; r < 5; r++) {
      weights[r * 5] *= edgeVis;
      weights[r * 5 + 1] *= midVis;
      weights[r * 5 + 3] *= midVis;
      weights[r * 5 + 4] *= edgeVis;
    }
  }

  return weights;
}

double subregionDistance(SubregionColors a, SubregionColors b) {
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += labDistance(a[i], b[i]) * subregionWeights[i];
  }
  return total / subregionWeightSum;
}

double luminancePatternDistance(SubregionColors a, SubregionColors b,
    [List<double>? cropWeights]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final dL = (a[i].L - b[i].L) * 2.0;
    total += (dL.abs() / (maxLabDistance * 0.5)) * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double chromaPatternDistance(SubregionColors a, SubregionColors b,
    [List<double>? cropWeights]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final da = a[i].a - b[i].a;
    final db = a[i].b - b[i].b;
    total += (math.sqrt(da * da + db * db) / maxLabDistance) * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double edgePatternDistance(SubregionEdges a, SubregionEdges b,
    [List<double>? cropWeights]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += (a[i] - b[i]).abs() * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double contrastPatternDistance(ContrastMap a, ContrastMap b,
    [List<double>? cropWeights]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += (a[i] - b[i]).abs() * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double edgeOrientationPatternDistance(
    SubregionEdgeOrientations a, SubregionEdgeOrientations b,
    [List<double>? cropWeights]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final off = i * 4;
    final cellDist = ((a[off] - b[off]).abs() +
            (a[off + 1] - b[off + 1]).abs() +
            (a[off + 2] - b[off + 2]).abs() +
            (a[off + 3] - b[off + 3]).abs()) *
        0.5;
    total += cellDist * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double luminanceBalanceDiff(LuminanceBalance a, LuminanceBalance b) {
  final dv = a.vertical - b.vertical;
  final dh = a.horizontal - b.horizontal;
  return math.sqrt(dv * dv + dh * dh) / math.sqrt2;
}

double histogramDistance(LuminanceHistogram a, LuminanceHistogram b) {
  var sum = 0.0;
  for (var i = 0; i < 8; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / 2;
}

const String flipSuffix = ':flip';

String getBaseTileId(String tileId) =>
    tileId.endsWith(flipSuffix)
        ? tileId.substring(0, tileId.length - flipSuffix.length)
        : tileId;

bool isTileFlipped(String tileId) => tileId.endsWith(flipSuffix);

double difference(double left, double right) => (left - right).abs();

/// Helper to allocate a zeroed Float32List orientation buffer (length 100).
Float32List zeroOrientations() => Float32List(100);
