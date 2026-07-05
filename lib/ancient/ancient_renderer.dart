import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'ancient_voronoi.dart';

/// Cell luminance below which the dark internal detail (seams/lines) is overlaid
/// in a lightened hue so it stays visible on dark-coloured emoji icons.
const double _darkDetailLum = 118;
const int _spritePx = 128;

const Map<String, String> _shapeEmoji = {
  'basketball': '🏀',
  'flower': '🌸',
};

/// Long side the slider values are calibrated against.
const double _referenceLong = 820;

const Map<String, Color> _groutColors = {
  'dark': Color(0xFF1A1511),
  'stone': Color(0xFF463C30),
  'light': Color(0xFFCDC1AA),
};

int _clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
int _lcg(int s) => (s * 1664525 + 1013904223) & 0xFFFFFFFF;

/// Look settings for the ancient renderer.
class AncientParams {
  const AncientParams({
    required this.stoneSize,
    required this.grout,
    required this.irregularity,
    required this.variation,
    required this.bevel,
    required this.groutColor,
    this.curviness = 0,
    this.shape = 'none',
    this.seedNonce = 0,
  });

  final double stoneSize;
  final double grout;
  final double irregularity;
  final double variation;
  final double bevel;
  final String groutColor;
  final double curviness;

  /// Curved-ancient submode: "none" | "heart" | "basketball" | "flower".
  final String shape;
  final int seedNonce;

  @override
  bool operator ==(Object other) =>
      other is AncientParams &&
      other.stoneSize == stoneSize &&
      other.grout == grout &&
      other.irregularity == irregularity &&
      other.variation == variation &&
      other.bevel == bevel &&
      other.groutColor == groutColor &&
      other.curviness == curviness &&
      other.shape == shape &&
      other.seedNonce == seedNonce;

  @override
  int get hashCode => Object.hash(stoneSize, grout, irregularity, variation,
      bevel, groutColor, curviness, shape, seedNonce);
}

/// One finished stone. [path] is in LOCAL coords (centred on the centroid).
class AncientStone {
  AncientStone({
    required this.path,
    required this.cx,
    required this.cy,
    required this.seedLx,
    required this.seedLy,
    required this.r,
    required this.g,
    required this.b,
    required this.maxR,
    this.motifAngle = 0,
    this.motif,
  });

  final Path path;
  final double cx, cy; // centroid (absolute)
  final double seedLx, seedLy; // seed relative to centroid (bevel centre)
  final int r, g, b;
  final double maxR;

  /// Shape submode: per-stone rotation (for the emoji sprite) and, for the
  /// vector heart, its baked motif path (local coords, centred on the centroid).
  final double motifAngle;
  final Path? motif;
}

class AncientGeometry {
  AncientGeometry({
    required this.stones,
    required this.groutW,
    required this.grout,
    required this.bevel,
    this.shape = 'none',
  });
  final List<AncientStone> stones;
  final double groutW;
  final Color grout;
  final double bevel;

  /// "none" (plain stones) | "heart" | "basketball" | "flower".
  final String shape;
}

/// Quadratic control point for a shared cell edge, computed identically from
/// either adjacent cell so the curved border stays watertight (see web renderer).
List<double> _edgeControl(double ax, double ay, double bx, double by,
    double curviness, int nonce, double maxBow) {
  double x0 = ax, y0 = ay, x1 = bx, y1 = by;
  if (x0 > x1 || (x0 == x1 && y0 > y1)) {
    x0 = bx;
    y0 = by;
    x1 = ax;
    y1 = ay;
  }
  final ex = x1 - x0, ey = y1 - y0;
  final len0 = math.sqrt(ex * ex + ey * ey);
  final len = len0 == 0 ? 1.0 : len0;
  final nx = -ey / len, ny = ex / len;
  int q(double v) => (v * 8).round();
  var h = (q(x0) * 73856093) ^
      (q(y0) * 19349663) ^
      (q(x1) * 83492791) ^
      (q(y1) * 2654435761) ^
      (nonce * 40503);
  h = h & 0xFFFFFFFF;
  final sign = (h / 4294967296.0) * 2 - 1;
  final cap = math.min(0.4 * len, maxBow);
  var off = curviness * len * sign;
  if (off > cap) {
    off = cap;
  } else if (off < -cap) {
    off = -cap;
  }
  return [(x0 + x1) / 2 + nx * off, (y0 + y1) / 2 + ny * off];
}

bool _onEdge(double x, double y, double w, double h) {
  const eps = 0.75;
  return x <= eps || y <= eps || x >= w - eps || y >= h - eps;
}

// ── Shape motifs ────────────────────────────────────────────────────────────

/// The classic heart parametric, sampled + normalised to a unit box (half-extent
/// 1, centred). Computed once.
final List<List<double>> _heartCanonical = () {
  const n = 72;
  final raw = <List<double>>[];
  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (var i = 0; i < n; i++) {
    final t = (i / n) * math.pi * 2;
    final s = math.sin(t);
    final x = 16 * s * s * s;
    final y = -(13 * math.cos(t) -
        5 * math.cos(2 * t) -
        2 * math.cos(3 * t) -
        math.cos(4 * t));
    raw.add([x, y]);
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  final half = math.max(maxX - minX, maxY - minY) / 2;
  return [
    for (final p in raw) [(p[0] - cx) / half, (p[1] - cy) / half]
  ];
}();

/// A heart Path at [radius], rotated by [angle], centred on the origin.
Path _heartPath(double radius, double angle) {
  final cos = math.cos(angle), sin = math.sin(angle);
  final path = Path();
  for (var i = 0; i < _heartCanonical.length; i++) {
    final lx = _heartCanonical[i][0] * radius, ly = _heartCanonical[i][1] * radius;
    final x = lx * cos - ly * sin, y = lx * sin + ly * cos;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

/// Desaturated emoji sprites: a bright luminance sprite for the multiply-tinted
/// body, and a dark-detail alpha mask for the adaptive light seams. Built once.
class AncientSprites {
  AncientSprites._(this._gray, this._detail);
  final Map<String, ui.Image> _gray;
  final Map<String, ui.Image> _detail;

  ui.Image gray(String kind) => _gray[kind]!;
  ui.Image detail(String kind) => _detail[kind]!;

  static AncientSprites? _cache;

  static Future<AncientSprites> load() async {
    if (_cache != null) return _cache!;
    final gray = <String, ui.Image>{};
    final detail = <String, ui.Image>{};
    for (final entry in _shapeEmoji.entries) {
      final masks = await _spriteMasks(entry.value);
      gray[entry.key] = masks.$1;
      detail[entry.key] = masks.$2;
    }
    return _cache = AncientSprites._(gray, detail);
  }
}

Future<ui.Image> _renderEmoji(String emoji, int px) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
      recorder, Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()));
  final tp = TextPainter(
    text: TextSpan(text: emoji, style: TextStyle(fontSize: px * 0.82)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset((px - tp.width) / 2, (px - tp.height) / 2));
  final img = await recorder.endRecording().toImage(px, px);
  return img;
}

Future<ui.Image> _decodePixels(Uint8List pixels, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<(ui.Image, ui.Image)> _spriteMasks(String emoji) async {
  const px = _spritePx;
  final base = await _renderEmoji(emoji, px);
  final data = await base.toByteData(format: ui.ImageByteFormat.rawRgba);
  base.dispose();
  final s = data!.buffer.asUint8List();
  final gray = Uint8List(px * px * 4);
  final detail = Uint8List(px * px * 4);
  for (var i = 0; i < s.length; i += 4) {
    final a = s[i + 3];
    if (a == 0) continue;
    final lum = 0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2];
    final l = math.min(255.0, lum * 0.55 + 100).round();
    gray[i] = gray[i + 1] = gray[i + 2] = l;
    gray[i + 3] = a;
    var dk = 1 - lum / 255;
    dk = dk < 0.4 ? 0 : (dk - 0.4) / 0.6;
    detail[i] = detail[i + 1] = detail[i + 2] = 255;
    detail[i + 3] = (a * dk).round();
  }
  return (
    await _decodePixels(gray, px, px),
    await _decodePixels(detail, px, px),
  );
}

/// Build the stone geometry for a base sampled into [rgba] (`sw`×`sh`) rendered
/// at `W`×`H`. Pure/synchronous — shared by the preview painter and export.
AncientGeometry buildAncientGeometry(
    Uint8List rgba, int sw, int sh, double w, double h, AncientParams p) {
  final empty = AncientGeometry(
      stones: const [], groutW: 0, grout: _groutColors['dark']!, bevel: 0);
  if (w < 2 || h < 2) return empty;

  final longSide = math.max(w, h);
  final s = math.max(3.0, p.stoneSize * (longSide / _referenceLong));
  final seeds = buildSeeds(w, h, s, p.irregularity, p.seedNonce);
  final groutW = p.grout > 0 ? p.grout * (longSide / _referenceLong) : 0.0;
  final grout = _groutColors[p.groutColor] ?? _groutColors['dark']!;
  final curviness = p.curviness;
  final maxBow = 0.7 * s;
  final shapeMode = p.shape != 'none';

  var jstate = (4096 + p.seedNonce * 131) & 0xFFFFFFFF;
  double jr() {
    jstate = _lcg(jstate);
    return jstate / 4294967296.0;
  }

  final stones = <AncientStone>[];
  final n = seeds.count;
  for (var i = 0; i < n; i++) {
    final cell = cellPolygon(seeds, i, w, h);
    if (cell == null || cell.length < 3) continue;

    final sxp = seeds.x(i), syp = seeds.y(i);

    // Base colour at the seed + a small tonal jitter (cut-stone look).
    final bx = ((sxp * sw) / w).floor().clamp(0, sw - 1);
    final by = ((syp * sh) / h).floor().clamp(0, sh - 1);
    final bi = (by * sw + bx) * 4;
    final t = 1 + (jr() - 0.5) * 2 * p.variation;
    final warm = (jr() - 0.5) * 2 * p.variation * 40;
    final cr = _clamp255(rgba[bi] * t + warm);
    final cg = _clamp255(rgba[bi + 1] * t);
    final cb = _clamp255(rgba[bi + 2] * t - warm);

    var ccx = 0.0, ccy = 0.0;
    for (final v in cell) {
      ccx += v.dx;
      ccy += v.dy;
    }
    ccx /= cell.length;
    ccy /= cell.length;

    // Shape submode: draw a motif per seed instead of the cobblestone. Heart is
    // a vector path; basketball/flower render as tinted emoji sprites (angle
    // only). The cell path/backing is replaced by the blurred-photo backdrop.
    if (shapeMode) {
      final hr = s * (0.8 + jr() * 0.28);
      final ang = jr() * math.pi * 2;
      stones.add(AncientStone(
        path: Path(),
        cx: ccx,
        cy: ccy,
        seedLx: 0,
        seedLy: 0,
        r: cr,
        g: cg,
        b: cb,
        maxR: hr,
        motifAngle: ang,
        motif: p.shape == 'heart' ? _heartPath(hr, ang) : null,
      ));
      continue;
    }

    final path = Path()..moveTo(cell[0].dx - ccx, cell[0].dy - ccy);
    var maxR = 1.0;
    for (var v = 0; v < cell.length; v++) {
      final a = cell[v];
      final b = cell[(v + 1) % cell.length];
      final dx = b.dx - sxp, dy = b.dy - syp;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > maxR) maxR = d;
      if (curviness > 0 &&
          !(_onEdge(a.dx, a.dy, w, h) && _onEdge(b.dx, b.dy, w, h))) {
        final c = _edgeControl(a.dx, a.dy, b.dx, b.dy, curviness, p.seedNonce, maxBow);
        path.quadraticBezierTo(c[0] - ccx, c[1] - ccy, b.dx - ccx, b.dy - ccy);
      } else {
        path.lineTo(b.dx - ccx, b.dy - ccy);
      }
    }
    path.close();

    stones.add(AncientStone(
      path: path,
      cx: ccx,
      cy: ccy,
      seedLx: sxp - ccx,
      seedLy: syp - ccy,
      r: cr,
      g: cg,
      b: cb,
      maxR: maxR,
    ));
  }

  return AncientGeometry(
      stones: stones,
      groutW: groutW,
      grout: grout,
      bevel: p.bevel,
      shape: p.shape);
}

/// Enlargement of the gap-filling backing motif vs the crisp top motif.
const double _motifBackScale = 1.6;

Rect _fullSrc(ui.Image img) =>
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());

/// Paint an ancient stone mosaic. In plain modes: grout backdrop + bevelled,
/// grouted stones. In shape modes: a soft blurred-photo backdrop, then two
/// passes of the motif (enlarged flat backing + crisp top) so the picture reads
/// as built only from the shapes.
class AncientPainter extends CustomPainter {
  AncientPainter(this.geo, {this.baseImage, this.sprites});
  final AncientGeometry geo;
  final ui.Image? baseImage;
  final AncientSprites? sprites;

  @override
  void paint(Canvas canvas, Size size) {
    if (geo.shape == 'none') {
      _paintStones(canvas, size);
      return;
    }
    _paintShapes(canvas, size);
  }

  void _paintStones(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = geo.grout);
    final bev = geo.bevel;
    for (final s in geo.stones) {
      canvas.save();
      canvas.translate(s.cx, s.cy);
      final fill = Paint();
      if (bev > 0) {
        final bright = Color.fromARGB(255, _clamp255(s.r * (1 + bev)),
            _clamp255(s.g * (1 + bev)), _clamp255(s.b * (1 + bev)));
        final dark = Color.fromARGB(255, _clamp255(s.r * (1 - bev)),
            _clamp255(s.g * (1 - bev)), _clamp255(s.b * (1 - bev)));
        fill.shader =
            ui.Gradient.radial(Offset(s.seedLx, s.seedLy), s.maxR, [bright, dark]);
      } else {
        fill.color = Color.fromARGB(255, s.r, s.g, s.b);
      }
      canvas.drawPath(s.path, fill);
      if (geo.groutW > 0) {
        canvas.drawPath(
          s.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = geo.groutW
            ..strokeJoin = StrokeJoin.miter
            ..strokeMiterLimit = 3
            ..color = geo.grout,
        );
      }
      canvas.restore();
    }
  }

  void _paintShapes(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFF000000));
    final bg = baseImage;
    if (bg != null) {
      final sigma = size.width * 0.02;
      canvas.drawImageRect(
        bg,
        _fullSrc(bg),
        rect,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)
          ..filterQuality = FilterQuality.low,
      );
      canvas.drawRect(rect, Paint()..color = const Color(0x4D000000));
    }

    final isSprite = geo.shape != 'heart';
    if (isSprite && sprites == null) return; // sprites not ready yet

    // Two passes: enlarged backings fill the gaps, crisp motifs on top.
    for (final s in geo.stones) {
      _drawMotif(canvas, s, _motifBackScale, backing: true);
    }
    for (final s in geo.stones) {
      _drawMotif(canvas, s, 1, backing: false);
    }
  }

  void _drawMotif(Canvas canvas, AncientStone s, double scale,
      {required bool backing}) {
    if (geo.shape == 'heart') {
      _drawHeart(canvas, s, scale, backing: backing);
    } else {
      _drawSprite(canvas, s, scale, backing: backing);
    }
  }

  void _drawHeart(Canvas canvas, AncientStone s, double scale,
      {required bool backing}) {
    final motif = s.motif;
    if (motif == null) return;
    canvas.save();
    canvas.translate(s.cx, s.cy);
    if (scale != 1) canvas.scale(scale, scale);
    if (backing) {
      canvas.drawPath(
          motif,
          Paint()
            ..color = Color.fromARGB(255, _clamp255(s.r * 0.9),
                _clamp255(s.g * 0.9), _clamp255(s.b * 0.9)));
    } else {
      final bev = geo.bevel;
      final fill = Paint();
      if (bev > 0) {
        final bright = Color.fromARGB(255, _clamp255(s.r * (1 + bev)),
            _clamp255(s.g * (1 + bev)), _clamp255(s.b * (1 + bev)));
        final dark = Color.fromARGB(255, _clamp255(s.r * (1 - bev)),
            _clamp255(s.g * (1 - bev)), _clamp255(s.b * (1 - bev)));
        fill.shader = ui.Gradient.radial(Offset.zero, s.maxR, [bright, dark]);
      } else {
        fill.color = Color.fromARGB(255, s.r, s.g, s.b);
      }
      canvas.drawPath(motif, fill);
      if (geo.groutW > 0) {
        canvas.drawPath(
            motif,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = geo.groutW
              ..color = geo.grout);
      }
    }
    canvas.restore();
  }

  void _drawSprite(Canvas canvas, AncientStone s, double scale,
      {required bool backing}) {
    final sp = sprites!;
    final gray = sp.gray(geo.shape), det = sp.detail(geo.shape);
    final ts = backing ? 0.9 : 1.0;
    final cr = _clamp255(s.r * ts), cg = _clamp255(s.g * ts), cb = _clamp255(s.b * ts);
    final tint = Color.fromARGB(255, cr, cg, cb);

    canvas.save();
    canvas.translate(s.cx, s.cy);
    canvas.rotate(s.motifAngle);
    final rad = s.maxR * scale;
    final dst = Rect.fromCenter(center: Offset.zero, width: 2 * rad, height: 2 * rad);
    canvas.drawImageRect(
      gray,
      _fullSrc(gray),
      dst,
      Paint()
        ..colorFilter = ColorFilter.mode(tint, BlendMode.multiply)
        ..filterQuality = FilterQuality.medium,
    );

    // On dark cells the multiplied dark seams vanish — overlay light seams.
    final lum = 0.299 * cr + 0.587 * cg + 0.114 * cb;
    if (lum < _darkDetailLum) {
      final k = math.min(1.0, (_darkDetailLum - lum) / _darkDetailLum);
      final light = Color.fromARGB(
          255,
          (cr + (255 - cr) * 0.75).round(),
          (cg + (255 - cg) * 0.75).round(),
          (cb + (255 - cb) * 0.75).round());
      canvas.saveLayer(dst, Paint()..color = Color.fromRGBO(0, 0, 0, k));
      canvas.drawImageRect(
        det,
        _fullSrc(det),
        dst,
        Paint()
          ..colorFilter = ColorFilter.mode(light, BlendMode.srcIn)
          ..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AncientPainter old) =>
      old.geo != geo || old.baseImage != baseImage || old.sprites != sprites;
}

/// Render the geometry into a raster [ui.Image] at `w`×`h` (for export/save).
Future<ui.Image> renderAncientImage(AncientGeometry geo, int w, int h,
    {ui.Image? baseImage, AncientSprites? sprites}) async {
  final recorder = ui.PictureRecorder();
  final canvas =
      Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  AncientPainter(geo, baseImage: baseImage, sprites: sprites)
      .paint(canvas, Size(w.toDouble(), h.toDouble()));
  final pic = recorder.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}
