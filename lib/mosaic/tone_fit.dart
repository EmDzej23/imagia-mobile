import 'dart:math' as math;

import 'analyze.dart';
import 'local_recolor.dart' show labToRgb;
import 'types.dart';

/// FIT THE PHOTO'S LIGHT TO THE LIBRARY (`settings.fitLightToLibrary`, opt-in, default
/// off). Port of the web's `lib/mosaic/tone-fit.ts` — keep the two identical.
///
/// When the library has no really dark (or bright) photos, every dark part of the base
/// gets the same "darkest available" tiles. Here the MATCHER sees the base photo with its
/// brightness ENDS squeezed into the range the library can reach:
///
///  • Only where the library falls short: if the photo's dark end (2nd percentile of cell
///    brightness, Lab L) is darker than the library's (3rd percentile of photo brightness)
///    by more than [_shortfallTol], the photo's tones from that end up to a knee (the
///    photo's lower quartile) are linearly squeezed onto [library dark end, knee]. Same
///    for the bright end with the upper quartile. Tones between the knees are untouched.
///  • Never stretches; a library that already covers the photo's range changes nothing.
///
/// Monotone; only L moves. The plan keeps the TRUE photo colours: after layout the photo
/// fields of every placement are re-read from the untouched analyzer ([restoreTruePhoto]).

const int _grid = 48;
const double _shortfallTol = 3;
const double _minRoom = 8;

/// Sorted values → value at quantile q ∈ [0,1] (linear between samples).
double _quantile(List<double> sorted, double q) {
  final f = q * (sorted.length - 1);
  final i = f.floor();
  final j = math.min(sorted.length - 1, i + 1);
  return sorted[i] + (f - i) * (sorted[j] - sorted[i]);
}

class _End {
  const _End(this.from, this.to, this.knee);
  final double from, to, knee;
}

/// The brightness curve for this photo + library, or null when the library covers it.
double Function(double)? lightFitCurve(
  List<double> photoL,
  List<double> libraryL,
) {
  if (photoL.length < 16 || libraryL.length < 2) return null;
  final photo = [...photoL]..sort();
  final lib = [...libraryL]..sort();
  final pLo = _quantile(photo, 0.02), pHi = _quantile(photo, 0.98);
  final lLo = _quantile(lib, 0.03), lHi = _quantile(lib, 0.97);
  final mid = (math.max(pLo, lLo) + math.min(pHi, lHi)) / 2;
  _End? lo, hi;
  if (pLo < lLo - _shortfallTol) {
    final knee = math.min(
      mid,
      math.max(_quantile(photo, 0.25), lLo + _minRoom),
    );
    if (knee > lLo && knee > pLo) lo = _End(pLo, lLo, knee);
  }
  if (pHi > lHi + _shortfallTol) {
    final knee = math.max(
      mid,
      math.min(_quantile(photo, 0.75), lHi - _minRoom),
    );
    if (knee < lHi && knee < pHi && (lo == null || knee > lo.knee)) {
      hi = _End(pHi, lHi, knee);
    }
  }
  if (lo == null && hi == null) return null;
  final l = lo, h = hi;
  return (double L) {
    var m = L;
    if (l != null && L < l.knee) {
      m = l.knee - ((l.knee - L) * (l.knee - l.to)) / (l.knee - l.from);
    } else if (h != null && L > h.knee) {
      m = h.knee + ((L - h.knee) * (h.to - h.knee)) / (h.from - h.knee);
    }
    return math.max(0, math.min(100, m)).toDouble();
  };
}

/// The analyzer the matcher should use: light-fitted, or [base] when not needed.
ImageAnalyzer toneFitAnalyzer(
  ImageAnalyzer base,
  List<TileDescriptor> tiles,
  bool enabled,
) {
  if (!enabled || tiles.length < 2) return base;
  final W = base.sourceWidth, H = base.sourceHeight;
  final photo = List<double>.filled(_grid * _grid, 0);
  for (var y = 0; y < _grid; y++) {
    for (var x = 0; x < _grid; x++) {
      photo[y * _grid + x] = base
          .sampleRegion(
            x: (x * W) / _grid,
            y: (y * H) / _grid,
            width: W / _grid,
            height: H / _grid,
          )
          .averageLabColor
          .L;
    }
  }
  final curve = lightFitCurve(photo, [
    for (final t in tiles) t.averageLabColor.L,
  ]);
  if (curve == null) return base;
  LabColor fit(LabColor c) => LabColor(curve(c.L), c.a, c.b);
  return base.withTransform((r) {
    final lab = fit(r.averageLabColor);
    final rgb = labToRgb(lab.L, lab.a, lab.b);
    return RegionAnalysis(
      x: r.x,
      y: r.y,
      width: r.width,
      height: r.height,
      averageColor: RgbColor(rgb[0], rgb[1], rgb[2]),
      averageLabColor: lab,
      detailScore: r.detailScore,
      subregionColors: [for (final c in r.subregionColors) fit(c)],
      subregionEdges: r.subregionEdges,
      contrastMap: r.contrastMap,
      luminanceBalance: r.luminanceBalance,
      colorVariance: r.colorVariance,
      edgeOrientation: r.edgeOrientation,
      tonalHistogram: r.tonalHistogram,
      subregionEdgeOrientations: r.subregionEdgeOrientations,
    );
  });
}

/// Put the TRUE photo colours back on every placement (the plan's recolour targets).
void restoreTruePhoto(List<MosaicPlacement> placements, ImageAnalyzer base) {
  for (final p in placements) {
    final r = base.sampleRegion(
      x: p.x,
      y: p.y,
      width: p.width,
      height: p.height,
    );
    p.averageColor = r.averageColor;
    p.averageLabColor = r.averageLabColor;
    p.subregionColors = r.subregionColors;
  }
}
