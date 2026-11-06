import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Collage ("pile") renderer — the Dart port of foto-mozaik/lib/collage/
/// collage-renderer.ts. Keep the two in step.
///
/// A cut-and-paste photo collage: NO base photo, every photo appears exactly once.
/// Whole photos are laid as slightly tilted, overlapping rectangles; cut-outs (the
/// subject cut from its background on our render service) are stickers on top.
/// Every photo has an important part (a whole photo's `keep` box, a cut-out's upper
/// silhouette) that [planPile] never covers: the pile is built top-down, each photo's
/// important part placed on still-empty canvas and the rest tucked under the photos
/// above.
///
/// [planPile] is pure geometry (deterministic for a seed — the same arithmetic as
/// the web, so the same photos and nonce give the same pile); [drawPile] paints a
/// plan. The high-res export sends the plan to Cloud Run (`render-collage`, plan
/// version 2), which mirrors the web's drawPile.

/// 'cutout' | 'full'.
typedef PieceKind = String;

/// Normalised rectangle (x0, y0, x1, y1).
typedef Box = List<double>;

class PieceMask {
  PieceMask(this.w, this.h, this.data);
  final int w;
  final int h;
  final Uint8List data;
}

/// One photo as the collage sees it.
class PilePiece {
  PilePiece({
    required this.id,
    required this.kind,
    this.image,
    required this.aspect,
    this.hero = false,
    this.mask,
    this.keep,
  });

  /// The same piece without its image, for laying out in an isolate.
  PilePiece layoutOnly() => PilePiece(
    id: id,
    kind: kind,
    image: null,
    aspect: aspect,
    hero: hero,
    mask: mask,
    keep: keep,
  );

  /// Everything the layout reads — two pieces with equal signatures lay the same.
  String get layoutSignature =>
      '$id|$kind|${aspect.toStringAsFixed(4)}|$hero|${keep?.join(',')}|${mask == null ? 0 : mask!.w * 1000 + mask!.h}';

  final String id;
  final PieceKind kind;

  /// What the preview draws: the trimmed cut-out (alpha) or the whole photo. Null
  /// for layout-only copies (planPile never reads it — it runs in an isolate).
  final ui.Image? image;

  /// width / height of the photo (whole) or of the cut-out image.
  final double aspect;
  final bool hero;

  /// Cut-outs: a small alpha grid of the silhouette.
  final PieceMask? mask;

  /// Whole photos: the part no other photo may cover ([importanceBox]).
  final Box? keep;
}

class PilePlacement {
  PilePlacement({
    required this.tileId,
    required this.kind,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.angle,
    this.crop,
  });

  final String tileId;
  final PieceKind kind;
  final double cx, cy, w, h;

  /// Radians.
  final double angle;

  /// Whole photos only: source crop, normalised (x0, y0, x1, y1).
  final Box? crop;

  Map<String, dynamic> toJson() => {
    'tileId': tileId,
    'kind': kind,
    'cx': cx,
    'cy': cy,
    'w': w,
    'h': h,
    'angle': angle,
    if (crop != null) 'crop': crop,
  };
}

class PileParams {
  const PileParams({
    required this.format,
    required this.rotation,
    required this.outline,
    required this.shadow,
    required this.background,
    required this.seedNonce,
  });

  /// 'portrait' (2:3) | 'square' | 'landscape' (3:2).
  final String format;

  /// Max tilt in degrees for cut-outs (backdrop photos tilt less).
  final double rotation;

  /// White sticker outline around cut-outs, 0..1.
  final double outline;

  /// Drop shadow, 0..1.
  final double shadow;

  /// '#rrggbb'.
  final String background;
  final int seedNonce;

  @override
  bool operator ==(Object other) =>
      other is PileParams &&
      other.format == format &&
      other.rotation == rotation &&
      other.outline == outline &&
      other.shadow == shadow &&
      other.background == background &&
      other.seedNonce == seedNonce;

  @override
  int get hashCode =>
      Object.hash(format, rotation, outline, shadow, background, seedNonce);
}

/// Long side of the preview — the reference space every plan lives in.
const double collagePreviewLong = 1800;

/// Long side of the high-res download.
const double collageExportLong = 10000;

/// Long side photos are uploaded at while in collage mode (mosaic tiles: 600).
const int collageUploadLong = 2400;

/// Safety cap on photos in one collage.
const int collageMaxPhotos = 1000;

/// Long side of the silhouette grid the layout uses.
const int maskLong = 40;

/// Long side of the grid [importanceBox] reads a photo at.
const int _keepGrid = 48;
const Box _defaultKeep = [0.2, 0.2, 0.8, 0.8];

({double w, double h}) formatSize(
  String format, [
  double long = collagePreviewLong,
]) {
  final r = switch (format) {
    'square' => (1, 1),
    'landscape' => (3, 2),
    _ => (2, 3),
  };
  final a = r.$1, b = r.$2;
  return a >= b
      ? (w: long, h: _jsRound(long * b / a))
      : (w: _jsRound(long * a / b), h: long);
}

List<int> hexToRgb(String hex) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
  if (m == null) return [24, 24, 27];
  final n = int.parse(m.group(1)!, radix: 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

Color hexToColor(String hex) {
  final c = hexToRgb(hex);
  return Color.fromARGB(255, c[0], c[1], c[2]);
}

/// Outline width in reference px for a 0..1 setting.
double outlinePx(double outline, double w, double h) =>
    outline > 0 ? math.max(1, outline * 0.008 * math.max(w, h)) : 0;

/// JavaScript Math.round (half toward +∞).
double _jsRound(double x) => (x + 0.5).floorToDouble();

// ── Deterministic randomness — the same 32-bit arithmetic as the web ─────────────

double Function() _makeRng(int seed) {
  var s = seed & 0xFFFFFFFF;
  if (s == 0) s = 1;
  return () {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    return s / 4294967296;
  };
}

int _hashIds(List<String> ids) {
  var h = 2166136261;
  for (final id in ids) {
    for (var i = 0; i < id.length; i++) {
      h = (h ^ id.codeUnitAt(i)) & 0xFFFFFFFF;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
  }
  return h;
}

List<T> _shuffle<T>(List<T> arr, double Function() rng) {
  final a = List<T>.of(arr);
  for (var i = a.length - 1; i > 0; i--) {
    final j = (rng() * (i + 1)).floor();
    final t = a[i];
    a[i] = a[j];
    a[j] = t;
  }
  return a;
}

// ── Image analysis ──────────────────────────────────────────────────────────────

Future<Uint8List?> _rgbaAt(ui.Image img, int w, int h) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final pic = rec.endRecording();
  final small = await pic.toImage(w, h);
  pic.dispose();
  final bd = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  return bd?.buffer.asUint8List();
}

/// Downsample a cut-out's alpha into a [PieceMask].
Future<PieceMask> buildPieceMask(ui.Image img) async {
  final k = maskLong / math.max(img.width, img.height);
  final w = math.max(1, (img.width * k).round()),
      h = math.max(1, (img.height * k).round());
  final px = await _rgbaAt(img, w, h);
  final data = Uint8List(w * h);
  if (px != null) {
    for (var i = 0; i < data.length; i++) {
      data[i] = px[i * 4 + 3];
    }
  }
  return PieceMask(w, h, data);
}

/// The part of a photo that must stay in view — faces and people first, then
/// whatever stands out, pulled a little toward the middle. A normalised box of
/// 44–72 % of the photo per side. Port of the web's importanceBox.
Future<Box> importanceBox(ui.Image img) async {
  final iw = img.width, ih = img.height;
  if (iw == 0 || ih == 0) return _defaultKeep;
  final k = _keepGrid / math.max(iw, ih);
  final w = math.max(4, (iw * k).round()), h = math.max(4, (ih * k).round());
  final px = await _rgbaAt(img, w, h);
  if (px == null) return _defaultKeep;
  return importanceBoxFromRgba(px, w, h);
}

/// [importanceBox] on an RGBA buffer (exposed for tests).
Box importanceBoxFromRgba(Uint8List px, int w, int h) {
  final n = w * h;
  final L = Float32List(n), A = Float32List(n), B = Float32List(n);
  final skin = Float32List(n);
  var mL = 0.0, mA = 0.0, mB = 0.0;
  for (var i = 0; i < n; i++) {
    final r = px[i * 4].toDouble(),
        g = px[i * 4 + 1].toDouble(),
        b = px[i * 4 + 2].toDouble();
    L[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    A[i] = r - g;
    B[i] = (r + g) / 2 - b;
    mL += L[i];
    mA += A[i];
    mB += B[i];
    // Skin tones (YCbCr box rule) — the faces a collage must never cover.
    final cb = 128 - 0.1687 * r - 0.3313 * g + 0.5 * b,
        cr = 128 + 0.5 * r - 0.4187 * g - 0.0813 * b;
    skin[i] =
        cr >= 135 &&
            cr <= 172 &&
            cb >= 80 &&
            cb <= 130 &&
            L[i] > 50 &&
            r > g &&
            r > b
        ? 1
        : 0;
  }
  mL /= n;
  mA /= n;
  mB /= n;
  final dist = Float32List(n), edge = Float32List(n);
  var maxD = 1e-6, maxE = 1e-6;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final dl = L[i] - mL, da = A[i] - mA, db = B[i] - mB;
      dist[i] = math.sqrt(dl * dl * 1.5 + da * da + db * db);
      final xl = L[y * w + math.max(0, x - 1)],
          xr = L[y * w + math.min(w - 1, x + 1)];
      final yu = L[math.max(0, y - 1) * w + x],
          yd = L[math.min(h - 1, y + 1) * w + x];
      edge[i] = (xr - xl).abs() + (yd - yu).abs();
      if (dist[i] > maxD) maxD = dist[i];
      if (edge[i] > maxE) maxE = edge[i];
    }
  }
  final sal = Float32List(n);
  var mean = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      // a lone "skin" pixel is noise; skin among skin is a face or a body
      var sk = 0.0;
      for (var yy = math.max(0, y - 1); yy <= math.min(h - 1, y + 1); yy++) {
        for (var xx = math.max(0, x - 1); xx <= math.min(w - 1, x + 1); xx++) {
          sk += skin[yy * w + xx];
        }
      }
      final dx = x / (w - 1) - 0.5, dy = y / (h - 1) - 0.42;
      final centre =
          0.35 + 0.65 * math.exp(-(dx * dx + dy * dy) / (2 * 0.28 * 0.28));
      sal[i] =
          (0.55 * dist[i] / maxD +
              0.45 * edge[i] / maxE +
              (sk >= 5 ? 1.2 : 0)) *
          centre;
      mean += sal[i];
    }
  }
  mean /= n;
  var sw = 0.0, sx = 0.0, sy = 0.0;
  for (var i = 0; i < n; i++) {
    sal[i] = math.max(0, sal[i] - mean * 0.8);
    sw += sal[i];
    sx += sal[i] * (i % w);
    sy += sal[i] * (i ~/ w);
  }
  if (sw <= 1e-6) return _defaultKeep;
  final cx = sx / sw, cy = sy / sw;
  var vx = 0.0, vy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = (i % w) - cx, dy = (i ~/ w) - cy;
    vx += sal[i] * dx * dx;
    vy += sal[i] * dy * dy;
  }
  final hw = math.min(0.36, math.max(0.22, (1.3 * math.sqrt(vx / sw)) / w));
  final hh = math.min(0.36, math.max(0.22, (1.3 * math.sqrt(vy / sw)) / h));
  final kx = math.min(1 - hw, math.max(hw, (cx + 0.5) / w)),
      ky = math.min(1 - hh, math.max(hh, (cy + 0.5) / h));
  double q(double v) => _jsRound(v * 100) / 100;
  return [q(kx - hw), q(ky - hh), q(kx + hw), q(ky + hh)];
}

// ── Layout ──────────────────────────────────────────────────────────────────────

int _gridFor(int n) =>
    math.min(200, math.max(100, _jsRound(math.sqrt(n) * 14).toInt()));

class _Geo {
  _Geo(this.cx, this.cy, this.w, this.h, this.ang, this.crop, this.keep);
  final double cx, cy, w, h, ang;
  final Box? crop;
  final Box keep;
  _Geo copyWith({double? cx, double? cy, double? w, double? h}) => _Geo(
    cx ?? this.cx,
    cy ?? this.cy,
    w ?? this.w,
    h ?? this.h,
    ang,
    crop,
    keep,
  );
}

double _fillRatio(PieceMask? m) {
  if (m == null) return math.pi / 4;
  var n = 0;
  for (var i = 0; i < m.data.length; i++) {
    if (m.data[i] >= 128) n++;
  }
  return math.max(0.05, n / m.data.length);
}

/// Lay the pile so every photo shows its important part while the whole print is
/// covered. See the web's planPile for the full reasoning — this is a line-by-line
/// port. Returns placements bottom of the pile first (the order to paint in).
List<PilePlacement> planPile(
  List<PilePiece> pieces,
  double W,
  double H,
  PileParams params,
) {
  if (pieces.isEmpty || W < 2 || H < 2) return [];
  final seed =
      _hashIds([for (final p in pieces) p.id]) ^
      (((params.seedNonce + 1) * 2654435761) & 0xFFFFFFFF);
  final rng = _makeRng(seed);
  final maxTilt = math.max(0, math.min(45, params.rotation)) * math.pi / 180;

  final G = _gridFor(pieces.length);
  final cw = math.max(W, H) / G;
  final gx = (W / cw).ceil(), gy = (H / cw).ceil();
  final N = gx * gy;

  final order = <PilePiece>[
    ...pieces.where((p) => p.hero),
    ..._shuffle(
      pieces.where((p) => !p.hero && p.kind == 'cutout').toList(),
      rng,
    ),
    ..._shuffle(pieces.where((p) => !p.hero && p.kind == 'full').toList(), rng),
  ];
  final n = order.length;
  final weights = [
    for (final p in order)
      if (p.hero)
        3.0
      else
        () {
          final g = (rng() + rng() + rng() - 1.5) * 1.4;
          return math.min(2.4, math.max(0.45, math.exp(g * 0.5))) *
              (p.kind == 'cutout' ? 1.15 : 1);
        }(),
  ];
  final angles = [
    for (final p in order)
      () {
        final t = (rng() * 2 - 1) * math.pow(rng(), 0.5);
        return t * maxTilt * (p.kind == 'cutout' ? 1 : 0.45);
      }(),
  ];

  // Grid state: per cell, the pieces covering it (ascending index = top first).
  final stack = List<List<int>?>.filled(N, null);
  final cellsOf = List<List<int>>.generate(n, (_) => []);
  final protOf = List<Set<int>>.generate(n, (_) => <int>{});
  var empty = N;
  final r = cw * 0.5;

  void raster(
    PilePiece p,
    _Geo g,
    void Function(int cell, bool cov, bool prot) visit,
  ) {
    final cos = math.cos(g.ang), sin = math.sin(g.ang);
    final hw = g.w / 2, hh = g.h / 2;
    final ex = (hw * cos).abs() + (hh * sin).abs(),
        ey = (hw * sin).abs() + (hh * cos).abs();
    final x0 = ((g.cx - ex) / cw).floor(), x1 = ((g.cx + ex) / cw).floor();
    final y0 = ((g.cy - ey) / cw).floor(), y1 = ((g.cy + ey) / cw).floor();
    final isCut = p.kind == 'cutout';
    final m = isCut ? p.mask : null;
    double lxOf(double px, double py) =>
        ((px - g.cx) * cos + (py - g.cy) * sin) / g.w + 0.5;
    double lyOf(double px, double py) =>
        (-(px - g.cx) * sin + (py - g.cy) * cos) / g.h + 0.5;
    bool opaque(double lx, double ly) {
      if (lx < 0 || ly < 0 || lx >= 1 || ly >= 1) return false;
      if (m == null) {
        final ax = (lx - 0.5) / 0.48, ay = (ly - 0.5) / 0.48;
        return ax * ax + ay * ay <= 1;
      }
      return m.data[(ly * m.h).floor() * m.w + (lx * m.w).floor()] >= 128;
    }

    bool opaqueAt(double px, double py) => opaque(lxOf(px, py), lyOf(px, py));
    final ix = r / g.w, iy = r / g.h;
    final k0 = g.keep[0], k1 = g.keep[1], k2 = g.keep[2], k3 = g.keep[3];
    for (var yy = y0; yy <= y1; yy++) {
      final py = (yy + 0.5) * cw;
      for (var xx = x0; xx <= x1; xx++) {
        final px = (xx + 0.5) * cw;
        final lx = lxOf(px, py), ly = lyOf(px, py);
        if (lx < 0 || ly < 0 || lx >= 1 || ly >= 1) continue;
        bool cov, prot;
        if (isCut) {
          final o = opaque(lx, ly);
          prot = o && ly < 0.6;
          cov =
              o &&
              opaqueAt(px - r, py - r) &&
              opaqueAt(px + r, py - r) &&
              opaqueAt(px - r, py + r) &&
              opaqueAt(px + r, py + r);
        } else {
          prot = lx >= k0 && lx <= k2 && ly >= k1 && ly <= k3;
          cov = lx >= ix && lx <= 1 - ix && ly >= iy && ly <= 1 - iy;
        }
        if (!cov && !prot) continue;
        final inside = xx >= 0 && yy >= 0 && xx < gx && yy < gy;
        visit(inside ? yy * gx + xx : -1, cov, prot);
      }
    }
  }

  void commit(int k, PilePiece p, _Geo g) {
    final cells = <int>[];
    final prot = <int>{};
    raster(p, g, (c, cov, pr) {
      if (c < 0) return;
      if (pr) prot.add(c);
      if (!cov) return;
      cells.add(c);
      final s = stack[c];
      if (s == null || s.isEmpty) {
        stack[c] = [k];
        empty--;
        return;
      }
      var i = s.length;
      while (i > 0 && s[i - 1] > k) {
        i--;
      }
      s.insert(i, k);
    });
    cellsOf[k] = cells;
    protOf[k] = prot;
  }

  void uncommit(int k) {
    for (final c in cellsOf[k]) {
      final s = stack[c]!;
      s.remove(k);
      if (s.isEmpty) empty++;
    }
    cellsOf[k] = [];
    protOf[k] = <int>{};
  }

  Float32List holeDistance() {
    final d = Float32List(N);
    const inf = 1e9;
    for (var c = 0; c < N; c++) {
      d[c] = (stack[c]?.isNotEmpty ?? false) ? 0 : inf;
    }
    double at(int x, int y) =>
        (x < 0 || y < 0 || x >= gx || y >= gy) ? 0 : d[y * gx + x];
    for (var y = 0; y < gy; y++) {
      for (var x = 0; x < gx; x++) {
        final c = y * gx + x;
        if (d[c] == 0) continue;
        d[c] = [
          d[c],
          at(x - 1, y) + 1,
          at(x, y - 1) + 1,
          at(x - 1, y - 1) + 1,
          at(x + 1, y - 1) + 1,
        ].reduce(math.min);
      }
    }
    for (var y = gy - 1; y >= 0; y--) {
      for (var x = gx - 1; x >= 0; x--) {
        final c = y * gx + x;
        if (d[c] == 0) continue;
        d[c] = [
          d[c],
          at(x + 1, y) + 1,
          at(x, y + 1) + 1,
          at(x + 1, y + 1) + 1,
          at(x - 1, y + 1) + 1,
        ].reduce(math.min);
      }
    }
    return d;
  }

  ({double w, double h, Box? crop, Box keep}) shape(
    PilePiece p,
    double targetCells,
  ) {
    var aspect = p.aspect > 0 ? p.aspect : 1.0;
    Box? crop;
    Box keep = p.kind == 'cutout' ? [0, 0, 1, 0.6] : (p.keep ?? _defaultKeep);
    if (p.kind == 'full' && (aspect > 2 || aspect < 0.5)) {
      if (aspect > 2) {
        final fw = 2 / aspect, mid = (keep[0] + keep[2]) / 2;
        final x0 = math.min(1 - fw, math.max(0.0, mid - fw / 2));
        crop = [x0, 0, x0 + fw, 1];
        keep = [
          math.max(0, (keep[0] - x0) / fw),
          keep[1],
          math.min(1, (keep[2] - x0) / fw),
          keep[3],
        ];
        aspect = 2;
      } else {
        final fh = aspect / 0.5, mid = (keep[1] + keep[3]) / 2;
        final y0 = math.min(1 - fh, math.max(0.0, mid - fh / 2));
        crop = [0, y0, 1, y0 + fh];
        keep = [
          keep[0],
          math.max(0, (keep[1] - y0) / fh),
          keep[2],
          math.min(1, (keep[3] - y0) / fh),
        ];
        aspect = 0.5;
      }
    }
    final visFrac = p.kind == 'cutout' ? _fillRatio(p.mask) : 0.6;
    final area = (math.max(1.0, targetCells) / visFrac) * cw * cw;
    var w = math.sqrt(area * aspect), h = w / aspect;
    final cap = math.max(W, H) * (p.hero ? 0.95 : 0.85);
    if (math.max(w, h) > cap) {
      final s = cap / math.max(w, h);
      w *= s;
      h *= s;
    }
    final floor = cw * 4;
    if (math.max(w, h) < floor) {
      final s = floor / math.max(w, h);
      w *= s;
      h *= s;
    }
    return (w: w, h: h, crop: crop, keep: keep);
  }

  double keepRadius(double w, double h, Box keep) =>
      math.min((keep[2] - keep[0]) * w, (keep[3] - keep[1]) * h) / 2 / cw;

  // ── 1. top-down placement
  final geos = List<_Geo?>.filled(n, null);
  var wLeft = weights.fold<double>(0, (a, b) => a + b);
  for (var k = 0; k < n; k++) {
    final p = order[k];
    final target = (empty * weights[k]) / wLeft;
    wLeft -= weights[k];
    final ang = angles[k];
    var sh = shape(p, target);
    final d = holeDistance();
    var maxD = 0.0;
    for (var c = 0; c < N; c++) {
      if (d[c] > maxD) maxD = d[c];
    }
    _Geo? best;
    var bestScore = 0.0;
    _Geo? leastBad;
    var leastBadV = 0.0;
    for (var attempt = 0; attempt < 6 && best == null; attempt++) {
      final kr = keepRadius(sh.w, sh.h, sh.keep);
      if (maxD > 0 && kr > maxD * 1.1) {
        final s = (maxD * 1.1) / kr;
        sh = (
          w: math.max(cw * 3, sh.w * s),
          h: math.max(cw * 3, sh.h * s),
          crop: sh.crop,
          keep: sh.keep,
        );
      }
      final need = math.max(1.0, keepRadius(sh.w, sh.h, sh.keep) * 0.8);
      final spots = <int>[];
      for (var c = 0; c < N; c++) {
        if (d[c] >= need) spots.add(c);
      }
      if (spots.isEmpty) {
        for (var c = 0; c < N; c++) {
          if (d[c] > 0) spots.add(c);
        }
      }
      final kcx = (sh.keep[0] + sh.keep[2]) / 2 - 0.5,
          kcy = (sh.keep[1] + sh.keep[3]) / 2 - 0.5;
      final cos = math.cos(ang), sin = math.sin(ang);
      final ox = kcx * sh.w, oy = kcy * sh.h;
      final tries = p.hero ? 16 : 28;
      for (var t = 0; t < tries; t++) {
        double ax, ay;
        if (p.hero) {
          ax = W * (0.38 + rng() * 0.24);
          ay = H * (0.38 + rng() * 0.24);
        } else if (spots.isNotEmpty) {
          final c = spots[(rng() * spots.length).floor()];
          ax = ((c % gx) + 0.5 + (rng() - 0.5)) * cw;
          ay = ((c ~/ gx) + 0.5 + (rng() - 0.5)) * cw;
        } else {
          ax = rng() * W;
          ay = rng() * H;
        }
        final g = _Geo(
          ax - (ox * cos - oy * sin),
          ay - (ox * sin + oy * cos),
          sh.w,
          sh.h,
          ang,
          sh.crop,
          sh.keep,
        );
        var gain = 0.0, protTot = 0, protBad = 0, off = 0, cov = 0;
        raster(p, g, (c, cv, pr) {
          final covered = c >= 0 && (stack[c]?.isNotEmpty ?? false);
          if (pr) {
            protTot++;
            if (c < 0 || covered) protBad++;
          }
          if (cv) {
            cov++;
            if (c < 0) {
              off++;
            } else if (!covered) {
              gain += 1 + 1.5 / math.max(1, d[c]);
            }
          }
        });
        if (cov == 0) continue;
        final bad = protTot > 0 ? protBad / protTot : 0.0;
        final offFrac = off / cov;
        if (leastBad == null || bad + offFrac * 0.5 < leastBadV) {
          leastBad = g;
          leastBadV = bad + offFrac * 0.5;
        }
        if (bad > 0.03 || offFrac > 0.35) continue;
        final score = gain * (0.8 + rng() * 0.4);
        if (best == null || score > bestScore) {
          best = g;
          bestScore = score;
        }
      }
      if (best == null) {
        sh = (w: sh.w * 0.82, h: sh.h * 0.82, crop: sh.crop, keep: sh.keep);
      }
    }
    final g =
        best ??
        leastBad ??
        _Geo(W / 2, H / 2, sh.w, sh.h, ang, sh.crop, sh.keep);
    geos[k] = g;
    commit(k, p, g);
  }

  // ── 2. fill what's left: grow photos (lowest first) over the holes.
  const scales = [1.08, 1.17, 1.28, 1.42, 1.6, 1.8];
  for (var round = 0; round < 8 && empty > 0; round++) {
    var grew = false;
    for (var k = n - 1; k >= 0 && empty > 0; k--) {
      final p = order[k], g0 = geos[k]!;
      final reach = math.max(g0.w, g0.h) * 0.85;
      var near = false;
      final cx0 = math.max(0, ((g0.cx - reach) / cw).floor()),
          cx1 = math.min(gx - 1, ((g0.cx + reach) / cw).floor());
      final cy0 = math.max(0, ((g0.cy - reach) / cw).floor()),
          cy1 = math.min(gy - 1, ((g0.cy + reach) / cw).floor());
      for (var y = cy0; y <= cy1 && !near; y++) {
        for (var x = cx0; x <= cx1; x++) {
          if (!(stack[y * gx + x]?.isNotEmpty ?? false)) {
            near = true;
            break;
          }
        }
      }
      if (!near) continue;
      final cos = math.cos(g0.ang), sin = math.sin(g0.ang);
      final kcx = (g0.keep[0] + g0.keep[2]) / 2,
          kcy = (g0.keep[1] + g0.keep[3]) / 2;
      final anchors = <List<double>>[
        [kcx, kcy],
        [0, 0],
        [1, 0],
        [0, 1],
        [1, 1],
        [0.5, 0],
        [0.5, 1],
        [0, 0.5],
        [1, 0.5],
      ];
      final cands = <(_Geo, double)>[];
      for (final a in anchors) {
        final ux = a[0], uy = a[1];
        final lx = (ux - 0.5) * g0.w, ly = (uy - 0.5) * g0.h;
        final ax = g0.cx + (lx * cos - ly * sin),
            ay = g0.cy + (lx * sin + ly * cos);
        for (final s in scales) {
          if (math.max(g0.w, g0.h) * s > math.max(W, H) * 1.15) break;
          final w = g0.w * s, h = g0.h * s;
          final ox = (ux - 0.5) * w, oy = (uy - 0.5) * h;
          cands.add((
            g0.copyWith(
              w: w,
              h: h,
              cx: ax - (ox * cos - oy * sin),
              cy: ay - (ox * sin + oy * cos),
            ),
            s,
          ));
        }
      }
      for (final f in const [0.08, 0.16]) {
        for (final dd in const [
          [1, 0],
          [-1, 0],
          [0, 1],
          [0, -1],
          [1, 1],
          [1, -1],
          [-1, 1],
          [-1, -1],
        ]) {
          cands.add((
            g0.copyWith(
              cx: g0.cx + dd[0] * f * g0.w,
              cy: g0.cy + dd[1] * f * g0.h,
            ),
            1.0,
          ));
        }
      }
      final mine = cellsOf[k].toSet();
      _Geo? pick;
      var pickGain = 0.0;
      for (final (g, s) in cands) {
        var gain = 0, hides = 0, protTot = 0, protBad = 0, cov = 0, off = 0;
        final now = <int>{};
        raster(p, g, (c, cv, pr) {
          if (pr) {
            protTot++;
            if (c < 0) {
              protBad++;
            } else {
              final st = stack[c];
              if (st != null && st.isNotEmpty && st[0] < k) protBad++;
            }
          }
          if (!cv) return;
          cov++;
          if (c < 0) {
            off++;
            return;
          }
          now.add(c);
          if (mine.contains(c)) return;
          final st = stack[c];
          if (st == null || st.isEmpty) {
            gain++;
            return;
          }
          if (st[0] < k) return; // goes under a photo above — hidden, harmless
          if (protOf[st[0]].contains(c)) hides++;
        });
        if (hides > 0 || gain == 0) continue;
        if (protTot > 0 && protBad / protTot > 0.06) continue;
        if (cov > 0 && off / cov > 0.45) continue;
        var lost = 0;
        if (s == 1) {
          for (final c in mine) {
            if (!now.contains(c) && stack[c]!.length == 1) lost++;
          }
        }
        final net = gain - lost;
        if (net <= 0) continue;
        final score = net / s;
        if (pick == null || score > pickGain) {
          pick = g;
          pickGain = score;
        }
      }
      if (pick != null) {
        uncommit(k);
        geos[k] = pick;
        commit(k, p, pick);
        grew = true;
      }
    }
    if (!grew) break;
  }

  // Bottom of the pile first — the order drawPile paints in.
  return [
    for (var k = n - 1; k >= 0; k--)
      PilePlacement(
        tileId: order[k].id,
        kind: order[k].kind,
        cx: geos[k]!.cx,
        cy: geos[k]!.cy,
        w: geos[k]!.w,
        h: geos[k]!.h,
        angle: geos[k]!.ang,
        crop: geos[k]!.crop,
      ),
  ];
}

/// Shadow geometry shared with the Cloud Run compositor (in reference px).
({double blur, double offset}) shadowGeometry(double w, double h) {
  final blur = math.max(2.0, _jsRound(math.min(w, h) * 0.035));
  return (blur: blur, offset: _jsRound(blur * 0.6));
}

/// Paint a plan in REFERENCE px (the caller scales the canvas). `images` overrides
/// a piece's image (a sharper copy for zoom); it must keep the same aspect.
void drawPile(
  Canvas canvas,
  List<PilePiece> pieces,
  List<PilePlacement> placements,
  PileParams params,
  double W,
  double H, {
  ui.Image? Function(String id)? sharper,
  Rect? visible,
}) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, W, H),
    Paint()..color = hexToColor(params.background),
  );
  final byId = {for (final p in pieces) p.id: p};
  final ol = outlinePx(params.outline, W, H);
  final shadowAmt = params.shadow.clamp(0.0, 1.0);
  final imgPaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;
  for (final pl in placements) {
    final piece = byId[pl.tileId];
    if (piece == null || pl.w < 1 || pl.h < 1) continue;
    if (visible != null) {
      final rad = math.sqrt(pl.w * pl.w + pl.h * pl.h) / 2 + ol * 2;
      if (pl.cx + rad < visible.left ||
          pl.cx - rad > visible.right ||
          pl.cy + rad < visible.top ||
          pl.cy - rad > visible.bottom) {
        continue;
      }
    }
    final img = sharper?.call(pl.tileId) ?? piece.image;
    if (img == null) continue;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    if (iw == 0 || ih == 0) continue;
    final dst = Rect.fromCenter(center: Offset.zero, width: pl.w, height: pl.h);
    final full = Rect.fromLTWH(0, 0, iw, ih);
    final src = pl.kind == 'full' && pl.crop != null
        ? Rect.fromLTRB(
            pl.crop![0] * iw,
            pl.crop![1] * ih,
            pl.crop![2] * iw,
            pl.crop![3] * ih,
          )
        : full;

    // Shadow: falls down-right ON SCREEN whatever the tilt (canvas shadows ignore
    // the transform on the web, and the server counter-rotates to match).
    if (shadowAmt > 0) {
      final sg = shadowGeometry(pl.w, pl.h);
      final shadowColor = Color.fromRGBO(0, 0, 0, 0.55 * shadowAmt);
      final sigma = sg.blur / 2;
      canvas.save();
      canvas.translate(pl.cx + sg.offset, pl.cy + sg.offset);
      canvas.rotate(pl.angle);
      if (pl.kind == 'full') {
        canvas.drawRect(
          dst,
          Paint()
            ..color = shadowColor
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
        );
      } else {
        // The silhouette, darkened and blurred (grown by the outline when there is one).
        final grown = ol >= 0.5 ? dst.inflate(ol) : dst;
        canvas.drawImageRect(
          img,
          full,
          grown,
          Paint()
            ..colorFilter = ColorFilter.mode(shadowColor, BlendMode.srcIn)
            ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        );
      }
      canvas.restore();
    }

    canvas.save();
    canvas.translate(pl.cx, pl.cy);
    canvas.rotate(pl.angle);
    if (pl.kind == 'cutout' && ol >= 0.5) {
      // Sticker outline: the silhouette in white, stamped around a circle.
      final white = Paint()
        ..colorFilter = const ColorFilter.mode(
          Color(0xFFFFFFFF),
          BlendMode.srcIn,
        )
        ..filterQuality = FilterQuality.low;
      final steps = math.max(12, math.min(32, (ol * 2).round()));
      for (var s = 0; s < steps; s++) {
        final a = s / steps * math.pi * 2;
        canvas.drawImageRect(
          img,
          full,
          dst.shift(Offset(math.cos(a) * ol, math.sin(a) * ol)),
          white,
        );
      }
      canvas.drawImageRect(img, full, dst, white);
    }
    canvas.drawImageRect(img, src, dst, imgPaint);
    canvas.restore();
  }
}

/// The payload for a high-res collage render (Cloud Run `render-collage`, v2).
Map<String, dynamic> collagePlanJson({
  required List<PilePlacement> placements,
  required PileParams params,
}) {
  final ref = formatSize(params.format, collagePreviewLong);
  final out = formatSize(params.format, collageExportLong);
  return {
    'version': 2,
    'refWidth': ref.w,
    'refHeight': ref.h,
    'outputWidth': out.w,
    'outputHeight': out.h,
    'background': hexToRgb(params.background),
    'outline': outlinePx(params.outline, ref.w, ref.h),
    'shadow': params.shadow,
    'placements': [for (final p in placements) p.toJson()],
  };
}
