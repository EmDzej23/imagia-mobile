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

class IntegralImage {
  IntegralImage({
    required this.width,
    required this.height,
    required this.red,
    required this.green,
    required this.blue,
    required this.detail,
    required this.edgeH,
    required this.edgeV,
    required this.lumBin0,
    required this.lumBin1,
    required this.lumBin2,
    required this.lumBin3,
    required this.lumBin4,
    required this.lumBin5,
    required this.lumBin6,
    required this.lumBin7,
    required this.orientBin0,
    required this.orientBin1,
    required this.orientBin2,
    required this.orientBin3,
  });

  final int width;
  final int height;
  final Float64List red;
  final Float64List green;
  final Float64List blue;
  final Float64List detail;
  final Float64List edgeH;
  final Float64List edgeV;
  final Float64List lumBin0;
  final Float64List lumBin1;
  final Float64List lumBin2;
  final Float64List lumBin3;
  final Float64List lumBin4;
  final Float64List lumBin5;
  final Float64List lumBin6;
  final Float64List lumBin7;
  final Float64List orientBin0;
  final Float64List orientBin1;
  final Float64List orientBin2;
  final Float64List orientBin3;
}

class ImageAnalyzer {
  ImageAnalyzer({
    required this.sourceWidth,
    required this.sourceHeight,
    required IntegralImage integral,
  }) : _integral = integral;

  final double sourceWidth;
  final double sourceHeight;
  final IntegralImage _integral;

  RegionAnalysis sampleRegion(
      {required double x,
      required double y,
      required double width,
      required double height}) {
    return sampleRegionFromIntegral(
        x, y, width, height, sourceWidth, sourceHeight, _integral);
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
  }) {
    preprocessPixels(rgba, colorBoost: colorBoost, autoContrast: autoContrast);
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
    double sourceWidth, double sourceHeight,
    [int maxDim = defaultAnalysisDimension]) {
  final longestSide = math.max(sourceWidth, sourceHeight);
  final scale = math.min(1.0, maxDim / longestSide);
  return (
    sampleWidth: math.max(10, jsRound(sourceWidth * scale)).toInt(),
    sampleHeight: math.max(10, jsRound(sourceHeight * scale)).toInt(),
  );
}

IntegralImage buildIntegralImage(Uint8List data, int width, int height) {
  final size = (width + 1) * (height + 1);
  final red = Float64List(size);
  final green = Float64List(size);
  final blue = Float64List(size);
  final detail = Float64List(size);
  final edgeH = Float64List(size);
  final edgeV = Float64List(size);
  final lumBin0 = Float64List(size);
  final lumBin1 = Float64List(size);
  final lumBin2 = Float64List(size);
  final lumBin3 = Float64List(size);
  final lumBin4 = Float64List(size);
  final lumBin5 = Float64List(size);
  final lumBin6 = Float64List(size);
  final lumBin7 = Float64List(size);
  final orientBin0 = Float64List(size);
  final orientBin1 = Float64List(size);
  final orientBin2 = Float64List(size);
  final orientBin3 = Float64List(size);
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
    var rowRed = 0.0, rowGreen = 0.0, rowBlue = 0.0, rowDetail = 0.0;
    var rowEdgeH = 0.0, rowEdgeV = 0.0;
    var rowB0 = 0.0, rowB1 = 0.0, rowB2 = 0.0, rowB3 = 0.0;
    var rowB4 = 0.0, rowB5 = 0.0, rowB6 = 0.0, rowB7 = 0.0;
    var rowOr0 = 0.0, rowOr1 = 0.0, rowOr2 = 0.0, rowOr3 = 0.0;

    for (var x = 0; x < width; x += 1) {
      final offset = (y * width + x) * 4;
      final r = data[offset].toDouble();
      final g = data[offset + 1].toDouble();
      final b = data[offset + 2].toDouble();
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
      red[integralIndex] = red[prev] + rowRed;
      green[integralIndex] = green[prev] + rowGreen;
      blue[integralIndex] = blue[prev] + rowBlue;
      detail[integralIndex] = detail[prev] + rowDetail;
      edgeH[integralIndex] = edgeH[prev] + rowEdgeH;
      edgeV[integralIndex] = edgeV[prev] + rowEdgeV;
      lumBin0[integralIndex] = lumBin0[prev] + rowB0;
      lumBin1[integralIndex] = lumBin1[prev] + rowB1;
      lumBin2[integralIndex] = lumBin2[prev] + rowB2;
      lumBin3[integralIndex] = lumBin3[prev] + rowB3;
      lumBin4[integralIndex] = lumBin4[prev] + rowB4;
      lumBin5[integralIndex] = lumBin5[prev] + rowB5;
      lumBin6[integralIndex] = lumBin6[prev] + rowB6;
      lumBin7[integralIndex] = lumBin7[prev] + rowB7;
      orientBin0[integralIndex] = orientBin0[prev] + rowOr0;
      orientBin1[integralIndex] = orientBin1[prev] + rowOr1;
      orientBin2[integralIndex] = orientBin2[prev] + rowOr2;
      orientBin3[integralIndex] = orientBin3[prev] + rowOr3;
    }
  }

  return IntegralImage(
    width: width,
    height: height,
    red: red,
    green: green,
    blue: blue,
    detail: detail,
    edgeH: edgeH,
    edgeV: edgeV,
    lumBin0: lumBin0,
    lumBin1: lumBin1,
    lumBin2: lumBin2,
    lumBin3: lumBin3,
    lumBin4: lumBin4,
    lumBin5: lumBin5,
    lumBin6: lumBin6,
    lumBin7: lumBin7,
    orientBin0: orientBin0,
    orientBin1: orientBin1,
    orientBin2: orientBin2,
    orientBin3: orientBin3,
  );
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
      ((regionX / sourceWidth) * integral.width).floor(), 0, integral.width - 1);
  final y1 = _clampInt(((regionY / sourceHeight) * integral.height).floor(), 0,
      integral.height - 1);
  final x2 = _clampInt(
      (((regionX + regionWidth) / sourceWidth) * integral.width).ceil(),
      x1 + 1,
      integral.width);
  final y2 = _clampInt(
      (((regionY + regionHeight) / sourceHeight) * integral.height).ceil(),
      y1 + 1,
      integral.height);
  final pixelCount = math.max(1, (x2 - x1) * (y2 - y1));

  final averageColor =
      _sampleAvgColor(integral, x1, y1, x2, y2, pixelCount.toDouble());
  final averageLabColor = rgbToLab(averageColor);

  final w = integral.width;
  final regionW = x2 - x1;
  final regionH = y2 - y1;

  SubregionColors subregionColors;
  SubregionEdges subregionEdges;
  SubregionEdgeOrientations subregionEdgeOrientations;

  if (regionW < 5 || regionH < 5) {
    final uniformEdge = clampD(
        _sumIntegral(integral.detail, w, x1, y1, x2, y2) / pixelCount, 0, 1);
    subregionColors = List<LabColor>.generate(
        25, (_) => LabColor(averageLabColor.L, averageLabColor.a, averageLabColor.b));
    subregionEdges = List<double>.filled(25, uniformEdge);
    subregionEdgeOrientations = Float32List(100);
  } else {
    final xSplits = _compute5Splits(x1, x2);
    final ySplits = _compute5Splits(y1, y2);
    subregionColors = _sampleSubregions5x5(integral, xSplits, ySplits);
    subregionEdges = _sampleSubregionEdges5x5(integral, xSplits, ySplits);
    subregionEdgeOrientations =
        _sampleSubregionOrientations5x5(integral, xSplits, ySplits);
  }

  final contrastMap = computeLocalContrast(subregionColors);
  final luminanceBalance = _deriveLuminanceBalance(subregionColors);
  final colorVariance = _deriveColorVariance(averageLabColor, subregionColors);

  final totalEdgeH = _sumIntegral(integral.edgeH, w, x1, y1, x2, y2);
  final totalEdgeV = _sumIntegral(integral.edgeV, w, x1, y1, x2, y2);
  final edgeSum = totalEdgeH + totalEdgeV;
  final edgeOrientation =
      edgeSum > 0 ? clampD((totalEdgeH - totalEdgeV) / edgeSum, -1, 1) : 0.0;

  final b0 = _sumIntegral(integral.lumBin0, w, x1, y1, x2, y2);
  final b1 = _sumIntegral(integral.lumBin1, w, x1, y1, x2, y2);
  final b2 = _sumIntegral(integral.lumBin2, w, x1, y1, x2, y2);
  final b3 = _sumIntegral(integral.lumBin3, w, x1, y1, x2, y2);
  final b4 = _sumIntegral(integral.lumBin4, w, x1, y1, x2, y2);
  final b5 = _sumIntegral(integral.lumBin5, w, x1, y1, x2, y2);
  final b6 = _sumIntegral(integral.lumBin6, w, x1, y1, x2, y2);
  final b7 = _sumIntegral(integral.lumBin7, w, x1, y1, x2, y2);
  var binTotal = b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7;
  if (binTotal == 0) binTotal = 1;
  final tonalHistogram = <double>[
    b0 / binTotal,
    b1 / binTotal,
    b2 / binTotal,
    b3 / binTotal,
    b4 / binTotal,
    b5 / binTotal,
    b6 / binTotal,
    b7 / binTotal,
  ];

  return RegionAnalysis(
    x: regionX,
    y: regionY,
    width: regionWidth,
    height: regionHeight,
    averageColor: averageColor,
    averageLabColor: averageLabColor,
    detailScore: math.max(
        0,
        math.min(
            1, _sumIntegral(integral.detail, w, x1, y1, x2, y2) / pixelCount)),
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

RgbColor _sampleAvgColor(IntegralImage integral, int x1, int y1, int x2, int y2,
    double pixelCount) {
  return RgbColor(
    roundChannel(
        _sumIntegral(integral.red, integral.width, x1, y1, x2, y2) / pixelCount),
    roundChannel(
        _sumIntegral(integral.green, integral.width, x1, y1, x2, y2) /
            pixelCount),
    roundChannel(
        _sumIntegral(integral.blue, integral.width, x1, y1, x2, y2) /
            pixelCount),
  );
}

SubregionColors _sampleSubregions5x5(
    IntegralImage integral, List<int> xs, List<int> ys) {
  LabColor q(int ax, int ay, int bx, int by) {
    final n = math.max(1, (bx - ax) * (by - ay)).toDouble();
    return rgbToLab(_sampleAvgColor(integral, ax, ay, bx, by, n));
  }

  return [
    q(xs[0], ys[0], xs[1], ys[1]), q(xs[1], ys[0], xs[2], ys[1]), q(xs[2], ys[0], xs[3], ys[1]), q(xs[3], ys[0], xs[4], ys[1]), q(xs[4], ys[0], xs[5], ys[1]), //
    q(xs[0], ys[1], xs[1], ys[2]), q(xs[1], ys[1], xs[2], ys[2]), q(xs[2], ys[1], xs[3], ys[2]), q(xs[3], ys[1], xs[4], ys[2]), q(xs[4], ys[1], xs[5], ys[2]),
    q(xs[0], ys[2], xs[1], ys[3]), q(xs[1], ys[2], xs[2], ys[3]), q(xs[2], ys[2], xs[3], ys[3]), q(xs[3], ys[2], xs[4], ys[3]), q(xs[4], ys[2], xs[5], ys[3]),
    q(xs[0], ys[3], xs[1], ys[4]), q(xs[1], ys[3], xs[2], ys[4]), q(xs[2], ys[3], xs[3], ys[4]), q(xs[3], ys[3], xs[4], ys[4]), q(xs[4], ys[3], xs[5], ys[4]),
    q(xs[0], ys[4], xs[1], ys[5]), q(xs[1], ys[4], xs[2], ys[5]), q(xs[2], ys[4], xs[3], ys[5]), q(xs[3], ys[4], xs[4], ys[5]), q(xs[4], ys[4], xs[5], ys[5]),
  ];
}

SubregionEdges _sampleSubregionEdges5x5(
    IntegralImage integral, List<int> xs, List<int> ys) {
  final w = integral.width;
  double e(int ax, int ay, int bx, int by) {
    final n = math.max(1, (bx - ax) * (by - ay));
    return clampD(_sumIntegral(integral.detail, w, ax, ay, bx, by) / n, 0, 1);
  }

  return [
    e(xs[0], ys[0], xs[1], ys[1]), e(xs[1], ys[0], xs[2], ys[1]), e(xs[2], ys[0], xs[3], ys[1]), e(xs[3], ys[0], xs[4], ys[1]), e(xs[4], ys[0], xs[5], ys[1]), //
    e(xs[0], ys[1], xs[1], ys[2]), e(xs[1], ys[1], xs[2], ys[2]), e(xs[2], ys[1], xs[3], ys[2]), e(xs[3], ys[1], xs[4], ys[2]), e(xs[4], ys[1], xs[5], ys[2]),
    e(xs[0], ys[2], xs[1], ys[3]), e(xs[1], ys[2], xs[2], ys[3]), e(xs[2], ys[2], xs[3], ys[3]), e(xs[3], ys[2], xs[4], ys[3]), e(xs[4], ys[2], xs[5], ys[3]),
    e(xs[0], ys[3], xs[1], ys[4]), e(xs[1], ys[3], xs[2], ys[4]), e(xs[2], ys[3], xs[3], ys[4]), e(xs[3], ys[3], xs[4], ys[4]), e(xs[4], ys[3], xs[5], ys[4]),
    e(xs[0], ys[4], xs[1], ys[5]), e(xs[1], ys[4], xs[2], ys[5]), e(xs[2], ys[4], xs[3], ys[5]), e(xs[3], ys[4], xs[4], ys[5]), e(xs[4], ys[4], xs[5], ys[5]),
  ];
}

SubregionEdgeOrientations _sampleSubregionOrientations5x5(
    IntegralImage integral, List<int> xs, List<int> ys) {
  final w = integral.width;
  final out = Float32List(100);
  for (var r = 0; r < 5; r++) {
    for (var c = 0; c < 5; c++) {
      final ax = xs[c], bx = xs[c + 1], ay = ys[r], by = ys[r + 1];
      final b0 = _sumIntegral(integral.orientBin0, w, ax, ay, bx, by);
      final b1 = _sumIntegral(integral.orientBin1, w, ax, ay, bx, by);
      final b2 = _sumIntegral(integral.orientBin2, w, ax, ay, bx, by);
      final b3 = _sumIntegral(integral.orientBin3, w, ax, ay, bx, by);
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
  final contrast = List<double>.filled(25, 0);
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

double _sumIntegral(
    Float64List integral, int width, int x1, int y1, int x2, int y2) {
  final stride = width + 1;
  return integral[y2 * stride + x2] -
      integral[y1 * stride + x2] -
      integral[y2 * stride + x1] +
      integral[y1 * stride + x1];
}

void preprocessPixels(Uint8List data,
    {double colorBoost = 1.0, double autoContrast = 0}) {
  final contrast = autoContrast;
  final saturation = colorBoost;
  if (contrast <= 0 && saturation <= 1.0) return;

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
      data[i] =
          math.max(0, math.min(255, jsRound(gray + (r - gray) * saturation))).toInt();
      data[i + 1] =
          math.max(0, math.min(255, jsRound(gray + (g - gray) * saturation))).toInt();
      data[i + 2] =
          math.max(0, math.min(255, jsRound(gray + (b - gray) * saturation))).toInt();
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
