import 'dart:typed_data';

import 'analyze.dart';
import 'local_recolor.dart' show labToRgb;
import 'shared.dart';
import 'types.dart';

/// "Look" (`settings.look`) — port of foto-mozaik/lib/mosaic/looks.ts; keep the two
/// identical (the export is graded by the server with the web code, so the preview must
/// match it). The app offers "cinematic" (a Settings switch, as on the web); the other
/// looks are web-admin experiments, ported so a project saved with one still matches
/// and previews the same.
///
/// One colour transform over the photo AND every tile, so the whole mosaic shares one
/// palette. It acts twice:
///  • Matching: the matcher compares photo and tiles AFTER the look ([lookAnalyzer],
///    [lookTiles]); the plan keeps the true photo colours.
///  • Render: the finished picture (tiles + recolour + saturation grade) goes through
///    [applyLookToPixels].

const List<String> mosaicLooks = [
  'none',
  'bw',
  'sepia',
  'duotone',
  'cinematic',
  'pop',
];

bool hasLook(String? look) => look != null && look != 'none';

const _duoDark = [22.0, 30.0, 66.0];
const _duoLight = [255.0, 214.0, 170.0];

double _clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v);
double _grey(double r, double g, double b) =>
    0.2126 * r + 0.7152 * g + 0.0722 * b;

/// The look applied to one sRGB colour (0..255 in, 0..255 out, unrounded).
List<double> lookRgb(String look, double r, double g, double b) {
  switch (look) {
    case 'bw':
      final y = _grey(r, g, b);
      return [y, y, y];
    case 'sepia':
      return [
        _clamp(0.393 * r + 0.769 * g + 0.189 * b),
        _clamp(0.349 * r + 0.686 * g + 0.168 * b),
        _clamp(0.272 * r + 0.534 * g + 0.131 * b),
      ];
    case 'duotone':
      final x = _grey(r, g, b) / 255;
      final t = x * x * (3 - 2 * x);
      return [
        _duoDark[0] + (_duoLight[0] - _duoDark[0]) * t,
        _duoDark[1] + (_duoLight[1] - _duoDark[1]) * t,
        _duoDark[2] + (_duoLight[2] - _duoDark[2]) * t,
      ];
    case 'cinematic':
      final y = _grey(r, g, b) / 255;
      final sh = (1 - y) * (1 - y), hi = y * y;
      const m = 0.7;
      final gy = y * 255;
      var nr = gy + (r - gy) * m,
          ng = gy + (g - gy) * m,
          nb = gy + (b - gy) * m;
      nr += -34 * sh + 40 * hi;
      ng += 14 * sh + 8 * hi;
      nb += 34 * sh - 36 * hi;
      double s(double v) {
        final x = _clamp(v) / 255;
        return 255 * (0.7 * x + 0.3 * x * x * (3 - 2 * x));
      }

      return [s(nr), s(ng), s(nb)];
    case 'pop':
      final y = _grey(r, g, b);
      var step = (y / 64).floor();
      if (step > 3) step = 3;
      final target = const [30.0, 100.0, 175.0, 245.0][step];
      final k = target / (y > 1 ? y : 1);
      const sat = 1.6;
      final ny = target;
      return [
        _clamp(ny + (r * k - ny) * sat),
        _clamp(ny + (g * k - ny) * sat),
        _clamp(ny + (b * k - ny) * sat),
      ];
    default:
      return [r, g, b];
  }
}

LabColor lookLab(String look, LabColor c) {
  final rgb = labToRgb(c.L, c.a, c.b);
  final o = lookRgb(look, rgb[0], rgb[1], rgb[2]);
  return rgbToLab(RgbColor(o[0], o[1], o[2]));
}

RgbColor _lookAvgRgb(String look, RgbColor c) {
  final o = lookRgb(look, c.r, c.g, c.b);
  return RgbColor(jsRound(o[0]), jsRound(o[1]), jsRound(o[2]));
}

/// The analyzer the matcher should use: colours seen through the look (on top of any
/// transform [base] already has, e.g. the light fit).
ImageAnalyzer lookAnalyzer(ImageAnalyzer base, String? look) {
  if (!hasLook(look)) return base;
  final l = look!;
  return base.thenTransform(
    (r) => RegionAnalysis(
      x: r.x,
      y: r.y,
      width: r.width,
      height: r.height,
      averageColor: _lookAvgRgb(l, r.averageColor),
      averageLabColor: lookLab(l, r.averageLabColor),
      detailScore: r.detailScore,
      subregionColors: List<LabColor>.of([
        for (final c in r.subregionColors) lookLab(l, c),
      ], growable: false),
      subregionEdges: r.subregionEdges,
      contrastMap: r.contrastMap,
      luminanceBalance: r.luminanceBalance,
      colorVariance: r.colorVariance,
      edgeOrientation: r.edgeOrientation,
      tonalHistogram: r.tonalHistogram,
      subregionEdgeOrientations: r.subregionEdgeOrientations,
    ),
    fine: (c) => lookLab(l, c),
  );
}

final Expando<Map<String, TileDescriptor>> _tileCache = Expando('lookTiles');

/// Tile descriptors seen through the look (cached per descriptor, so replans are cheap).
List<TileDescriptor> lookTiles(List<TileDescriptor> tiles, String? look) {
  if (!hasLook(look)) return tiles;
  final l = look!;
  return [
    for (final t in tiles)
      (_tileCache[t] ??= {})[l] ??= TileDescriptor(
        id: t.id,
        name: t.name,
        width: t.width,
        height: t.height,
        aspectRatio: t.aspectRatio,
        orientation: t.orientation,
        averageColor: _lookAvgRgb(l, t.averageColor),
        averageLabColor: lookLab(l, t.averageLabColor),
        detailScore: t.detailScore,
        subregionColors: t.subregionColors == null
            ? null
            : List<LabColor>.of([
                for (final c in t.subregionColors!) lookLab(l, c),
              ], growable: false),
        subregionEdges: t.subregionEdges,
        contrastMap: t.contrastMap,
        luminanceBalance: t.luminanceBalance,
        colorVariance: t.colorVariance,
        edgeOrientation: t.edgeOrientation,
        tonalHistogram: t.tonalHistogram,
        subregionEdgeOrientations: t.subregionEdgeOrientations,
        fine: t.fine,
      ),
  ];
}

/// The 3×3 saturation matrix (saturationMatrix in shared.ts) as 9 tables of
/// round(coefficient × value × 4096) — JS Math.round, like the web.
List<Int32List> _satTables(double s, double lr, double lg, double lb) {
  final m = [
    lr + (1 - lr) * s,
    lg - lg * s,
    lb - lb * s,
    lr - lr * s,
    lg + (1 - lg) * s,
    lb - lb * s,
    lr - lr * s,
    lg - lg * s,
    lb + (1 - lb) * s,
  ];
  return [
    for (final c in m)
      Int32List.fromList([
        for (var v = 0; v < 256; v++) jsRound(c * v * 4096).toInt(),
      ]),
  ];
}

List<Uint8List>? _cinematicLut;

/// Per channel: [light level (0–255) × 256 + channel value] → output byte.
List<Uint8List> _cinematicTables() {
  final cached = _cinematicLut;
  if (cached != null) return cached;
  const split = [
    [-34.0, 40.0],
    [14.0, 8.0],
    [34.0, -36.0],
  ];
  final t = [Uint8List(65536), Uint8List(65536), Uint8List(65536)];
  for (var yl = 0; yl < 256; yl++) {
    final y = yl / 255, sh = (1 - y) * (1 - y), hi = y * y;
    for (var ch = 0; ch < 3; ch++) {
      final add = split[ch][0] * sh + split[ch][1] * hi;
      for (var c = 0; c < 256; c++) {
        var x = (yl + (c - yl) * 0.7 + add) / 255;
        x = x <= 0 ? 0 : (x >= 1 ? 1 : x);
        t[ch][(yl << 8) | c] = jsRound(
          255 * (0.7 * x + 0.3 * x * x * (3 - 2 * x)),
        ).toInt();
      }
    }
  }
  return _cinematicLut = t;
}

/// Apply the look to raw pixels in place (RGB or RGBA, [channels] 3 or 4), optionally
/// after the output-saturation grade ([saturation] ≠ 1). The same bytes as the web's
/// applyLookToPixels and the server's (render-service/src/lib/look.ts).
void applyLookToPixels(
  Uint8List d,
  int channels,
  String? look, [
  double saturation = 1,
]) {
  if (!hasLook(look) && saturation == 1) return;
  const lr = 0.213, lg = 0.715, lb = 0.072;
  final sat = saturation != 1 ? _satTables(saturation, lr, lg, lb) : null;
  final cine = look == 'cinematic' ? _cinematicTables() : null;
  final generic = hasLook(look) && cine == null;
  int byte(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : jsRound(v).toInt());
  final n = d.length;
  for (var i = 0; i < n; i += channels) {
    var r = d[i], g = d[i + 1], b = d[i + 2];
    if (sat != null) {
      var v = (sat[0][r] + sat[1][g] + sat[2][b] + 2048) >> 12;
      final nr = v < 0 ? 0 : (v > 255 ? 255 : v);
      v = (sat[3][r] + sat[4][g] + sat[5][b] + 2048) >> 12;
      final ng = v < 0 ? 0 : (v > 255 ? 255 : v);
      v = (sat[6][r] + sat[7][g] + sat[8][b] + 2048) >> 12;
      final nb = v < 0 ? 0 : (v > 255 ? 255 : v);
      r = nr;
      g = ng;
      b = nb;
    }
    if (cine != null) {
      final k = (0.2126 * r + 0.7152 * g + 0.0722 * b + 0.5).toInt() << 8;
      d[i] = cine[0][k | r];
      d[i + 1] = cine[1][k | g];
      d[i + 2] = cine[2][k | b];
    } else if (generic) {
      final o = lookRgb(look!, r.toDouble(), g.toDouble(), b.toDouble());
      d[i] = byte(o[0]);
      d[i + 1] = byte(o[1]);
      d[i + 2] = byte(o[2]);
    } else {
      d[i] = r;
      d[i + 1] = g;
      d[i + 2] = b;
    }
  }
}
