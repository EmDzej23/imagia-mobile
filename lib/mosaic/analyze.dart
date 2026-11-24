import 'dart:math' as math;
import 'dart:typed_data';

import 'shared.dart';
import 'types.dart';

/// Dart port of `foto-mozaik/lib/mosaic/analyze.ts`.
///
/// The integral-image math is platform-independent: it operates on a raw RGBA
/// byte buffer + dimensions. The web's canvas pixel-acquisition
/// (`document.createElement('canvas')` + `getImageData`) is replaced by a
/// `dart:ui` decode in the engine layer (Phase 3); this file takes the decoded
/// RGBA bytes directly.

const int defaultAnalysisDimension = 2000;
const int tileAnalysisDimension = 200;

/// Diagonal-vs-axial threshold: tan(67.5°) ≈ 2.4142.
const double _orientAxialRatio = 2.4142;

/// The photo's integral image: per position, 11 whole-number channels (red, green,
/// blue, 8 brightness bins) in [ints] and 7 fractional ones (detail, edgeH, edgeV,
/// 4 orientation bins) in [floats], each position's channels side by side.
///
/// Interleaved, not one array per channel: a rectangle sum reads 4 corners, and with
/// 18 separate ~15 MB planes that was 72 reads from 72 places — on a phone nearly every
/// one a cache (and TLB) miss, which made region sampling ~30× slower than on a laptop.
/// Side by side, a corner's channels share one or two cache lines. Same numbers, same
/// arithmetic, same results; same memory.
class IntegralImage {
  IntegralImage({
    required this.width,
    required this.height,
    required this.ints,
    required this.floats,
  });

  final int width;
  final int height;
  final Uint32List ints;
  final Float64List floats;
}

/// Channels of [IntegralImage.ints] / [IntegralImage.floats].
const int _nI = 11, _nF = 7;
const int _cRed = 0, _cGreen = 1, _cBlue = 2, _cBin0 = 3;
const int _cDetail = 0, _cEdgeH = 1, _cEdgeV = 2, _cOrient0 = 3;

class ImageAnalyzer {
  ImageAnalyzer({
    required this.sourceWidth,
    required this.sourceHeight,
    required IntegralImage integral,
    RegionAnalysis Function(RegionAnalysis)? transform,
    LabColor Function(LabColor)? fineTransform,
  }) : _integral = integral,
       _transform = transform,
       _fineTransform = fineTransform;

  final double sourceWidth;
  final double sourceHeight;
  final IntegralImage _integral;
  final RegionAnalysis Function(RegionAnalysis)? _transform;

  /// The same change for one colour of [sampleFine].
  final LabColor Function(LabColor)? _fineTransform;

  /// The same image, with every sampled region passed through [transform] (used by
  /// tone_fit.dart so only the matcher sees the light-fitted photo).
  ImageAnalyzer withTransform(
    RegionAnalysis Function(RegionAnalysis) transform, {
    required LabColor Function(LabColor) fine,
  }) => ImageAnalyzer(
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    integral: _integral,
    transform: transform,
    fineTransform: fine,
  );

  /// [withTransform] on top of the transform this analyzer already has (the look over
  /// the light fit — web: lookAnalyzer(toneFitAnalyzer(...))).
  ImageAnalyzer thenTransform(
    RegionAnalysis Function(RegionAnalysis) next, {
    required LabColor Function(LabColor) fine,
  }) {
    final prev = _transform, prevFine = _fineTransform;
    return withTransform(
      prev == null ? next : (r) => next(prev(r)),
      fine: prevFine == null ? fine : (c) => fine(prevFine(c)),
    );
  }

  /// grid×grid Lab samples of a region (row by row, L a b) — see fine_placement.dart.
  Float64List sampleFine(
    double x,
    double y,
    double width,
    double height,
    int grid,
  ) {
    final f = _sampleFineFromIntegral(
      x,
      y,
      width,
      height,
      sourceWidth,
      sourceHeight,
      _integral,
      grid,
    );
    final t = _fineTransform;
    if (t != null) {
      for (var i = 0; i < f.length; i += 3) {
        final c = t(LabColor(f[i], f[i + 1], f[i + 2]));
        f[i] = c.L;
        f[i + 1] = c.a;
        f[i + 2] = c.b;
      }
    }
    return f;
  }

  RegionAnalysis sampleRegion({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final r = sampleRegionFromIntegral(
      x,
      y,
      width,
      height,
      sourceWidth,
      sourceHeight,
      _integral,
    );
    final t = _transform;
    return t == null ? r : t(r);
  }

  /// Builds an analyzer from a pre-sampled RGBA buffer of size
  /// [sampleWidth]×[sampleHeight]. The source dimensions are kept so region
  /// queries (in source pixels) map back into the integral image.
  factory ImageAnalyzer.fromPixels(
    Uint8List rgba,
    int sampleWidth,
    int sampleHeight,
    double sourceWidth,
    double sourceHeight, {
    double colorBoost = 1.0,
    double autoContrast = 0,
    bool grayscale = false,
    double grayContrast = 0,
    bool invert = false,
    bool threshold = false,
  }) {
    preprocessPixels(
      rgba,
      colorBoost: colorBoost,
      autoContrast: autoContrast,
      grayscale: grayscale,
      grayContrast: grayContrast,
      invert: invert,
      threshold: threshold,
    );
    final integral = buildIntegralImage(rgba, sampleWidth, sampleHeight);
    return ImageAnalyzer(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      integral: integral,
    );
  }
}

/// Returns the (sampleWidth, sampleHeight) for analyzing an image of the given
/// source size at [maxDim] longest side.
({int sampleWidth, int sampleHeight}) getAnalysisDimensions(
  double sourceWidth,
  double sourceHeight, [
  int maxDim = defaultAnalysisDimension,
]) {
  final longestSide = math.max(sourceWidth, sourceHeight);
  final scale = math.min(1.0, maxDim / longestSide);
  return (
    sampleWidth: math.max(10, jsRound(sourceWidth * scale)).toInt(),
    sampleHeight: math.max(10, jsRound(sourceHeight * scale)).toInt(),
  );
}

IntegralImage buildIntegralImage(Uint8List data, int width, int height) {
  final size = (width + 1) * (height + 1);
  final ints = Uint32List(size * _nI);
  final floats = Float64List(size * _nF);
  final luminance = Float64List(width * height);

  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final offset = (y * width + x) * 4;
      final r = data[offset].toDouble();
      final g = data[offset + 1].toDouble();
      final b = data[offset + 2].toDouble();
      luminance[y * width + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }
  }

  for (var y = 0; y < height; y += 1) {
    var rowRed = 0, rowGreen = 0, rowBlue = 0;
    var rowDetail = 0.0, rowEdgeH = 0.0, rowEdgeV = 0.0;
    var rowB0 = 0, rowB1 = 0, rowB2 = 0, rowB3 = 0;
    var rowB4 = 0, rowB5 = 0, rowB6 = 0, rowB7 = 0;
    var rowOr0 = 0.0, rowOr1 = 0.0, rowOr2 = 0.0, rowOr3 = 0.0;

    for (var x = 0; x < width; x += 1) {
      final offset = (y * width + x) * 4;
      final r = data[offset];
      final g = data[offset + 1];
      final b = data[offset + 2];
      final currentLum = luminance[y * width + x];
      final rightLum = luminance[y * width + math.min(x + 1, width - 1)];
      final bottomLum = luminance[math.min(y + 1, height - 1) * width + x];
      final gx = rightLum - currentLum;
      final gy = bottomLum - currentLum;
      final absGx = gx.abs();
      final absGy = gy.abs();
      final hEdge = absGx / 255;
      final vEdge = absGy / 255;
      final integralIndex = (y + 1) * (width + 1) + (x + 1);

      rowRed += r;
      rowGreen += g;
      rowBlue += b;
      rowDetail += (hEdge + vEdge) / 2;
      rowEdgeH += hEdge;
      rowEdgeV += vEdge;

      final mag = hEdge + vEdge;
      if (mag > 0) {
        if (absGx > absGy * _orientAxialRatio) {
          rowOr0 += mag;
        } else if (absGy > absGx * _orientAxialRatio) {
          rowOr2 += mag;
        } else if (gx * gy > 0) {
          rowOr1 += mag;
        } else {
          rowOr3 += mag;
        }
      }

      if (currentLum < 32) {
        rowB0++;
      } else if (currentLum < 64) {
        rowB1++;
      } else if (currentLum < 96) {
        rowB2++;
      } else if (currentLum < 128) {
        rowB3++;
      } else if (currentLum < 160) {
        rowB4++;
      } else if (currentLum < 192) {
        rowB5++;
      } else if (currentLum < 224) {
        rowB6++;
      } else {
        rowB7++;
      }

      final prev = integralIndex - (width + 1);
      final pi = prev * _nI, ci = integralIndex * _nI;
      ints[ci] = ints[pi] + rowRed;
      ints[ci + 1] = ints[pi + 1] + rowGreen;
      ints[ci + 2] = ints[pi + 2] + rowBlue;
      ints[ci + 3] = ints[pi + 3] + rowB0;
      ints[ci + 4] = ints[pi + 4] + rowB1;
      ints[ci + 5] = ints[pi + 5] + rowB2;
      ints[ci + 6] = ints[pi + 6] + rowB3;
      ints[ci + 7] = ints[pi + 7] + rowB4;
      ints[ci + 8] = ints[pi + 8] + rowB5;
      ints[ci + 9] = ints[pi + 9] + rowB6;
      ints[ci + 10] = ints[pi + 10] + rowB7;
      final pf = prev * _nF, cf = integralIndex * _nF;
      floats[cf] = floats[pf] + rowDetail;
      floats[cf + 1] = floats[pf + 1] + rowEdgeH;
      floats[cf + 2] = floats[pf + 2] + rowEdgeV;
      floats[cf + 3] = floats[pf + 3] + rowOr0;
      floats[cf + 4] = floats[pf + 4] + rowOr1;
      floats[cf + 5] = floats[pf + 5] + rowOr2;
      floats[cf + 6] = floats[pf + 6] + rowOr3;
    }
  }

  return IntegralImage(
    width: width,
    height: height,
    ints: ints,
    floats: floats,
  );
}

/// Side of the RGB thumbnail kept with every photo ([TileDescriptor.fine]).
const int fineThumbSize = 32;

/// The whole image as a [fineThumbSize]² RGB thumbnail (box averages, rounded to bytes).
Uint8List fineThumb(IntegralImage integral) {
  const F = fineThumbSize;
  final out = Uint8List(F * F * 3);
  for (var y = 0; y < F; y++) {
    final y1 = (y * integral.height) ~/ F;
    final y2 = math.max(y1 + 1, ((y + 1) * integral.height) ~/ F);
    for (var x = 0; x < F; x++) {
      final x1 = (x * integral.width) ~/ F;
      final x2 = math.max(x1 + 1, ((x + 1) * integral.width) ~/ F);
      final n = (x2 - x1) * (y2 - y1), o = (y * F + x) * 3;
      out[o] = (_sumI(integral, _cRed, x1, y1, x2, y2) / n + 0.5).floor();
      out[o + 1] = (_sumI(integral, _cGreen, x1, y1, x2, y2) / n + 0.5).floor();
      out[o + 2] = (_sumI(integral, _cBlue, x1, y1, x2, y2) / n + 0.5).floor();
    }
  }
  return out;
}

Float64List _sampleFineFromIntegral(
  double regionX,
  double regionY,
  double regionWidth,
  double regionHeight,
  double sourceWidth,
  double sourceHeight,
  IntegralImage integral,
  int grid,
) {
  final W = integral.width, H = integral.height;
  final x0 = _clampInt(((regionX / sourceWidth) * W).floor(), 0, W - 1);
  final y0 = _clampInt(((regionY / sourceHeight) * H).floor(), 0, H - 1);
  final w =
      _clampInt((((regionX + regionWidth) / sourceWidth) * W).ceil(), x0 + 1, W) -
      x0;
  final h =
      _clampInt(
        (((regionY + regionHeight) / sourceHeight) * H).ceil(),
        y0 + 1,
        H,
      ) -
      y0;
  final out = Float64List(grid * grid * 3);
  final rgb = RgbColor(0, 0, 0);
  for (var gy = 0; gy < grid; gy++) {
    final ya = y0 + (gy * h) ~/ grid;
    final yb = math.max(ya + 1, y0 + ((gy + 1) * h) ~/ grid);
    for (var gx = 0; gx < grid; gx++) {
      final xa = x0 + (gx * w) ~/ grid;
      final xb = math.max(xa + 1, x0 + ((gx + 1) * w) ~/ grid);
      final n = (xb - xa) * (yb - ya), o = (gy * grid + gx) * 3;
      rgb
        ..r = _sumI(integral, _cRed, xa, ya, xb, yb) / n
        ..g = _sumI(integral, _cGreen, xa, ya, xb, yb) / n
        ..b = _sumI(integral, _cBlue, xa, ya, xb, yb) / n;
      final lab = rgbToLab(rgb);
      out[o] = lab.L;
      out[o + 1] = lab.a;
      out[o + 2] = lab.b;
    }
  }
  return out;
}

int _clampInt(int value, int min, int max) =>
    math.min(max, math.max(min, value));

RegionAnalysis sampleRegionFromIntegral(
  double regionX,
  double regionY,
  double regionWidth,
  double regionHeight,
  double sourceWidth,
  double sourceHeight,
  IntegralImage integral,
) {
  final x1 = _clampInt(
    ((regionX / sourceWidth) * integral.width).floor(),
    0,
    integral.width - 1,
  );
  final y1 = _clampInt(
    ((regionY / sourceHeight) * integral.height).floor(),
    0,
    integral.height - 1,
  );
  final x2 = _clampInt(
    (((regionX + regionWidth) / sourceWidth) * integral.width).ceil(),
    x1 + 1,
    integral.width,
  );
  final y2 = _clampInt(
    (((regionY + regionHeight) / sourceHeight) * integral.height).ceil(),
    y1 + 1,
    integral.height,
  );
  final pixelCount = math.max(1, (x2 - x1) * (y2 - y1));

  final averageColor = _sampleAvgColor(
    integral,
    x1,
    y1,
    x2,
    y2,
    pixelCount.toDouble(),
  );
  final averageLabColor = rgbToLab(averageColor);

  final regionW = x2 - x1;
  final regionH = y2 - y1;

  SubregionColors subregionColors;
  SubregionEdges subregionEdges;
  SubregionEdgeOrientations subregionEdgeOrientations;

  if (regionW < 5 || regionH < 5) {
    final uniformEdge = clampD(
      _sumF(integral, _cDetail, x1, y1, x2, y2) / pixelCount,
      0,
      1,
    );
    subregionColors = List<LabColor>.generate(
      25,
      (_) => LabColor(averageLabColor.L, averageLabColor.a, averageLabColor.b),
      growable: false,
    );
    subregionEdges = Float64List(25)..fillRange(0, 25, uniformEdge);
    subregionEdgeOrientations = Float32List(100);
  } else {
    final xSplits = _compute5Splits(x1, x2);
    final ySplits = _compute5Splits(y1, y2);
    subregionColors = _sampleSubregions5x5(integral, xSplits, ySplits);
    subregionEdges = _sampleSubregionEdges5x5(integral, xSplits, ySplits);
    subregionEdgeOrientations = _sampleSubregionOrientations5x5(
      integral,
      xSplits,
      ySplits,
    );
  }

  final contrastMap = computeLocalContrast(subregionColors);
  final luminanceBalance = _deriveLuminanceBalance(subregionColors);
  final colorVariance = _deriveColorVariance(averageLabColor, subregionColors);

  final totalEdgeH = _sumF(integral, _cEdgeH, x1, y1, x2, y2);
  final totalEdgeV = _sumF(integral, _cEdgeV, x1, y1, x2, y2);
  final edgeSum = totalEdgeH + totalEdgeV;
  final edgeOrientation = edgeSum > 0
      ? clampD((totalEdgeH - totalEdgeV) / edgeSum, -1, 1)
      : 0.0;

  final b0 = _sumI(integral, _cBin0 + 0, x1, y1, x2, y2);
  final b1 = _sumI(integral, _cBin0 + 1, x1, y1, x2, y2);
  final b2 = _sumI(integral, _cBin0 + 2, x1, y1, x2, y2);
  final b3 = _sumI(integral, _cBin0 + 3, x1, y1, x2, y2);
  final b4 = _sumI(integral, _cBin0 + 4, x1, y1, x2, y2);
  final b5 = _sumI(integral, _cBin0 + 5, x1, y1, x2, y2);
  final b6 = _sumI(integral, _cBin0 + 6, x1, y1, x2, y2);
  final b7 = _sumI(integral, _cBin0 + 7, x1, y1, x2, y2);
  var binTotal = b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7;
  if (binTotal == 0) binTotal = 1;
  final tonalHistogram = Float64List.fromList([
    b0 / binTotal,
    b1 / binTotal,
    b2 / binTotal,
    b3 / binTotal,
    b4 / binTotal,
    b5 / binTotal,
    b6 / binTotal,
    b7 / binTotal,
  ]);

  return RegionAnalysis(
    x: regionX,
    y: regionY,
    width: regionWidth,
    height: regionHeight,
    averageColor: averageColor,
    averageLabColor: averageLabColor,
    detailScore: math.max(
      0,
      math.min(1, _sumF(integral, _cDetail, x1, y1, x2, y2) / pixelCount),
    ),
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

List<int> _compute5Splits(int lo, int hi) {
  final span = hi - lo;
  return [
    lo,
    _clampInt(jsRound(lo + span * 0.2).toInt(), lo + 1, hi - 4),
    _clampInt(jsRound(lo + span * 0.4).toInt(), lo + 2, hi - 3),
    _clampInt(jsRound(lo + span * 0.6).toInt(), lo + 3, hi - 2),
    _clampInt(jsRound(lo + span * 0.8).toInt(), lo + 4, hi - 1),
    hi,
  ];
}

RgbColor _sampleAvgColor(
  IntegralImage integral,
  int x1,
  int y1,
  int x2,
  int y2,
  double pixelCount,
) {
  return RgbColor(
    roundChannel(_sumI(integral, _cRed, x1, y1, x2, y2) / pixelCount),
    roundChannel(_sumI(integral, _cGreen, x1, y1, x2, y2) / pixelCount),
    roundChannel(_sumI(integral, _cBlue, x1, y1, x2, y2) / pixelCount),
  );
}

SubregionColors _sampleSubregions5x5(
  IntegralImage integral,
  List<int> xs,
  List<int> ys,
) {
  LabColor q(int ax, int ay, int bx, int by) {
    final n = math.max(1, (bx - ax) * (by - ay)).toDouble();
    return rgbToLab(_sampleAvgColor(integral, ax, ay, bx, by, n));
  }

  // Fixed-length, like every grid the scorer reads (see subregionWeights).
  return List.of([
    q(xs[0], ys[0], xs[1], ys[1]),
    q(xs[1], ys[0], xs[2], ys[1]),
    q(xs[2], ys[0], xs[3], ys[1]),
    q(xs[3], ys[0], xs[4], ys[1]),
    q(xs[4], ys[0], xs[5], ys[1]), //
    q(xs[0], ys[1], xs[1], ys[2]),
    q(xs[1], ys[1], xs[2], ys[2]),
    q(xs[2], ys[1], xs[3], ys[2]),
    q(xs[3], ys[1], xs[4], ys[2]),
    q(xs[4], ys[1], xs[5], ys[2]),
    q(xs[0], ys[2], xs[1], ys[3]),
    q(xs[1], ys[2], xs[2], ys[3]),
    q(xs[2], ys[2], xs[3], ys[3]),
    q(xs[3], ys[2], xs[4], ys[3]),
    q(xs[4], ys[2], xs[5], ys[3]),
    q(xs[0], ys[3], xs[1], ys[4]),
    q(xs[1], ys[3], xs[2], ys[4]),
    q(xs[2], ys[3], xs[3], ys[4]),
    q(xs[3], ys[3], xs[4], ys[4]),
    q(xs[4], ys[3], xs[5], ys[4]),
    q(xs[0], ys[4], xs[1], ys[5]),
    q(xs[1], ys[4], xs[2], ys[5]),
    q(xs[2], ys[4], xs[3], ys[5]),
    q(xs[3], ys[4], xs[4], ys[5]),
    q(xs[4], ys[4], xs[5], ys[5]),
  ], growable: false);
}

SubregionEdges _sampleSubregionEdges5x5(
  IntegralImage integral,
  List<int> xs,
  List<int> ys,
) {
  double e(int ax, int ay, int bx, int by) {
    final n = math.max(1, (bx - ax) * (by - ay));
    return clampD(_sumF(integral, _cDetail, ax, ay, bx, by) / n, 0, 1);
  }

  return Float64List.fromList([
    e(xs[0], ys[0], xs[1], ys[1]),
    e(xs[1], ys[0], xs[2], ys[1]),
    e(xs[2], ys[0], xs[3], ys[1]),
    e(xs[3], ys[0], xs[4], ys[1]),
    e(xs[4], ys[0], xs[5], ys[1]), //
    e(xs[0], ys[1], xs[1], ys[2]),
    e(xs[1], ys[1], xs[2], ys[2]),
    e(xs[2], ys[1], xs[3], ys[2]),
    e(xs[3], ys[1], xs[4], ys[2]),
    e(xs[4], ys[1], xs[5], ys[2]),
    e(xs[0], ys[2], xs[1], ys[3]),
    e(xs[1], ys[2], xs[2], ys[3]),
    e(xs[2], ys[2], xs[3], ys[3]),
    e(xs[3], ys[2], xs[4], ys[3]),
    e(xs[4], ys[2], xs[5], ys[3]),
    e(xs[0], ys[3], xs[1], ys[4]),
    e(xs[1], ys[3], xs[2], ys[4]),
    e(xs[2], ys[3], xs[3], ys[4]),
    e(xs[3], ys[3], xs[4], ys[4]),
    e(xs[4], ys[3], xs[5], ys[4]),
    e(xs[0], ys[4], xs[1], ys[5]),
    e(xs[1], ys[4], xs[2], ys[5]),
    e(xs[2], ys[4], xs[3], ys[5]),
    e(xs[3], ys[4], xs[4], ys[5]),
    e(xs[4], ys[4], xs[5], ys[5]),
  ]);
}

SubregionEdgeOrientations _sampleSubregionOrientations5x5(
  IntegralImage integral,
  List<int> xs,
  List<int> ys,
) {
  final out = Float32List(100);
  for (var r = 0; r < 5; r++) {
    for (var c = 0; c < 5; c++) {
      final ax = xs[c], bx = xs[c + 1], ay = ys[r], by = ys[r + 1];
      final b0 = _sumF(integral, _cOrient0 + 0, ax, ay, bx, by);
      final b1 = _sumF(integral, _cOrient0 + 1, ax, ay, bx, by);
      final b2 = _sumF(integral, _cOrient0 + 2, ax, ay, bx, by);
      final b3 = _sumF(integral, _cOrient0 + 3, ax, ay, bx, by);
      final total = b0 + b1 + b2 + b3;
      final idx = (r * 5 + c) * 4;
      if (total > 0) {
        out[idx] = b0 / total;
        out[idx + 1] = b1 / total;
        out[idx + 2] = b2 / total;
        out[idx + 3] = b3 / total;
      }
    }
  }
  return out;
}

ContrastMap computeLocalContrast(SubregionColors s) {
  final contrast = Float64List(25);
  for (var r = 0; r < 5; r++) {
    for (var c = 0; c < 5; c++) {
      final idx = r * 5 + c;
      final L = s[idx].L;
      var sum = 0.0;
      var count = 0;
      if (r > 0) {
        sum += (L - s[(r - 1) * 5 + c].L).abs();
        count++;
      }
      if (r < 4) {
        sum += (L - s[(r + 1) * 5 + c].L).abs();
        count++;
      }
      if (c > 0) {
        sum += (L - s[r * 5 + c - 1].L).abs();
        count++;
      }
      if (c < 4) {
        sum += (L - s[r * 5 + c + 1].L).abs();
        count++;
      }
      contrast[idx] = count > 0 ? (sum / count) / 100 : 0;
    }
  }
  return contrast;
}

LuminanceBalance _deriveLuminanceBalance(SubregionColors s) {
  var topL = 0.0, bottomL = 0.0, leftL = 0.0, rightL = 0.0;
  for (var c = 0; c < 5; c++) {
    topL += s[c].L;
    bottomL += s[20 + c].L;
  }
  for (var r = 0; r < 5; r++) {
    leftL += s[r * 5].L;
    rightL += s[r * 5 + 4].L;
  }
  return LuminanceBalance(
    clampD((topL / 5 - bottomL / 5) / 100, -1, 1),
    clampD((leftL / 5 - rightL / 5) / 100, -1, 1),
  );
}

double _deriveColorVariance(LabColor avg, SubregionColors s) {
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += labDistance(avg, s[i]);
  }
  return clampD(total / 25, 0, 1);
}

/// Sum of integer channel [ch] over [x1,x2)×[y1,y2). Whole numbers, so exact.
double _sumI(IntegralImage integral, int ch, int x1, int y1, int x2, int y2) {
  final a = integral.ints;
  final stride = integral.width + 1;
  return (a[(y2 * stride + x2) * _nI + ch] -
          a[(y1 * stride + x2) * _nI + ch] -
          a[(y2 * stride + x1) * _nI + ch] +
          a[(y1 * stride + x1) * _nI + ch])
      .toDouble();
}

/// Sum of fractional channel [ch] over [x1,x2)×[y1,y2) — the same four terms in the
/// same order as ever, so the same value.
double _sumF(IntegralImage integral, int ch, int x1, int y1, int x2, int y2) {
  final a = integral.floats;
  final stride = integral.width + 1;
  return a[(y2 * stride + x2) * _nF + ch] -
      a[(y1 * stride + x2) * _nF + ch] -
      a[(y2 * stride + x1) * _nF + ch] +
      a[(y1 * stride + x1) * _nF + ch];
}

void preprocessPixels(
  Uint8List data, {
  double colorBoost = 1.0,
  double autoContrast = 0,
  bool grayscale = false,
  double grayContrast = 0,
  bool invert = false,
  bool threshold = false,
}) {
  final contrast = autoContrast;
  final saturation = colorBoost;
  if (contrast <= 0 && saturation <= 1.0 && !grayscale) return;

  final len = data.length;

  if (contrast > 0) {
    final rHist = Uint32List(256);
    final gHist = Uint32List(256);
    final bHist = Uint32List(256);
    final pixelCount = len / 4;
    for (var i = 0; i < len; i += 4) {
      rHist[data[i]]++;
      gHist[data[i + 1]]++;
      bHist[data[i + 2]]++;
    }
    final lo = (pixelCount * 0.01).floor();
    final hi = (pixelCount * 0.99).floor();
    ({int min, int max}) bounds(Uint32List hist) {
      var minV = 0, maxV = 255, acc = 0;
      for (var v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc >= lo) {
          minV = v;
          break;
        }
      }
      acc = 0;
      for (var v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc >= hi) {
          maxV = v;
          break;
        }
      }
      return (min: minV, max: math.max(maxV, minV + 1));
    }

    final rB = bounds(rHist), gB = bounds(gHist), bB = bounds(bHist);

    final rLUT = Uint8List(256);
    final gLUT = Uint8List(256);
    final bLUT = Uint8List(256);
    for (var v = 0; v < 256; v++) {
      final rStretched = ((v - rB.min) / (rB.max - rB.min)) * 255;
      final gStretched = ((v - gB.min) / (gB.max - gB.min)) * 255;
      final bStretched = ((v - bB.min) / (bB.max - bB.min)) * 255;
      rLUT[v] = math
          .max(0, math.min(255, jsRound(v + (rStretched - v) * contrast)))
          .toInt();
      gLUT[v] = math
          .max(0, math.min(255, jsRound(v + (gStretched - v) * contrast)))
          .toInt();
      bLUT[v] = math
          .max(0, math.min(255, jsRound(v + (bStretched - v) * contrast)))
          .toInt();
    }
    for (var i = 0; i < len; i += 4) {
      data[i] = rLUT[data[i]];
      data[i + 1] = gLUT[data[i + 1]];
      data[i + 2] = bLUT[data[i + 2]];
    }
  }

  if (saturation > 1.0) {
    for (var i = 0; i < len; i += 4) {
      final r = data[i], g = data[i + 1], b = data[i + 2];
      final gray = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      data[i] = math
          .max(0, math.min(255, jsRound(gray + (r - gray) * saturation)))
          .toInt();
      data[i + 1] = math
          .max(0, math.min(255, jsRound(gray + (g - gray) * saturation)))
          .toInt();
      data[i + 2] = math
          .max(0, math.min(255, jsRound(gray + (b - gray) * saturation)))
          .toInt();
    }
  }

  // Text mosaic: grayscale → contrast S-curve → optional invert. Runs last so it
  // sees any auto-contrast/color-boost already applied. The S-curve pushes
  // midtones toward black/white as `grayContrast` rises (→ near 2-color at 1).
  if (grayscale) {
    final k = math.max(0.0, math.min(1.0, grayContrast));
    final exp = 1 + 3 * k; // 1 (linear) → 4 (steep)
    // In threshold mode, `k` is the cutoff (clamped off the extremes so the
    // image never collapses to a single flat color).
    final cutoff = math.max(0.1, math.min(0.9, k == 0 ? 0.5 : k));
    for (var i = 0; i < len; i += 4) {
      var n =
          (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) /
          255;
      if (threshold) {
        n = n < cutoff ? 0 : 1; // hard 2-color
      } else if (k > 0) {
        n = n < 0.5
            ? 0.5 * math.pow(2 * n, exp)
            : 1 - 0.5 * math.pow(2 * (1 - n), exp);
      }
      if (invert) n = 1 - n;
      final v = math.max(0, math.min(255, jsRound(n * 255))).toInt();
      data[i] = v;
      data[i + 1] = v;
      data[i + 2] = v;
    }
  }
}

RgbColor blendColor(RgbColor left, RgbColor right, double amount) {
  final t = math.max(0, math.min(1, amount)).toDouble();
  return RgbColor(
    roundChannel(left.r + (right.r - left.r) * t),
    roundChannel(left.g + (right.g - left.g) * t),
    roundChannel(left.b + (right.b - left.b) * t),
  );
}
