import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Word-art (tile-less) renderer — a typographic portrait. Dart port of the web
/// renderer `foto-mozaik/lib/wordart/wordart-renderer.ts`. Words are the ONLY
/// ink (no background fill beyond a photo-derived ground): they land only where
/// the image has content, packed at many sizes (big first) with NO overlaps,
/// oriented along the local image flow, each taking the photo's colour.
///
/// Mirrors the ancient pattern: an immutable [WordArtParams], a pure
/// [buildWordArtGeometry], a [WordArtPainter], and [renderWordArtImage] used by
/// BOTH the live preview and (conceptually) export.
///
/// PARITY NOTE: text is measured/drawn with Flutter's engine (Skia/Inter) while
/// the server export uses napi-canvas/Inter. Per-word advance widths differ
/// slightly between the two shapers, so packing is very close but not pixel-
/// identical to the server render. The algorithm/constants themselves match the
/// web renderer exactly.

const double _referenceLong = 820;
const double _lineInk = 0.8; // ink height of one line (× font size)
const double _lineStep = 0.86; // baseline-to-baseline for wrapped phrases
const int _maxLines = 3;
const double _skipTone = 0.14; // below this "ink" the spot stays bare paper
const double _toneGamma = 1.1; // >1 concentrates words into darker/salient areas
const double _attemptFactor = 1.35; // dart budget ≈ this × (area / smallest²)
const double _scaleStep = 0.76; // ratio between candidate word sizes
const double _minScale = 0.09; // smallest word = this × the largest
const double _inkStroke = 0.045; // extra stroke (× font size) to fatten glyphs
const double _gradEps = 0.02; // below this gradient → keep word upright
const int _fullPalette = 64; // palette ≥ this → no quantisation
const double _readMargin = 62; // min luminance gap the ink keeps from the ground
const double _mute = 0.55; // desaturate the ground toward its own grey
// Detail-aware composition: words shrink where the photo has fine detail
// (eyes/lips/contours) so features resolve; big words fill the flat masses; and
// each word's colour is averaged over its footprint (less speckle). Must match
// the web renderer's V2_* constants exactly.
const double _detailShrink = 0.62; // max fraction a word's size is cut in busy areas
const double _detailGamma = 0.85; // <1 lifts mid detail so features (not just hard edges) shrink
const double _dartBoost = 1.6; // extra dart-acceptance in detailed areas
const double _detailNorm = 2.2; // detail normalised against this × the image mean edge energy

int _c255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.toInt());

/// Parse a CSS colour ('#rgb', '#rrggbb', 'rgb(r,g,b)') to a [Color], or null.
Color? _parseCssColor(String? s) {
  if (s == null) return null;
  final str = s.trim();
  if (str.isEmpty) return null;
  final rgb = RegExp(r'rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)').firstMatch(str);
  if (rgb != null) {
    return Color.fromARGB(255, int.parse(rgb.group(1)!),
        int.parse(rgb.group(2)!), int.parse(rgb.group(3)!));
  }
  final hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').firstMatch(str);
  if (hex != null) {
    var h = hex.group(1)!;
    if (h.length == 3) {
      h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
    }
    return Color.fromARGB(
      255,
      int.parse(h.substring(0, 2), radix: 16),
      int.parse(h.substring(2, 4), radix: 16),
      int.parse(h.substring(4, 6), radix: 16),
    );
  }
  return null;
}

/// Look settings for the word-art renderer.
class WordArtParams {
  const WordArtParams({
    required this.phrases,
    this.palette = 64,
    required this.density,
    this.rotation = 0,
    this.contrast = 1,
    this.ground = 0.3,
    this.vivid = 0.3,
    this.empty = 1,
    this.coverage = 0,
    this.seedNonce = 0,
    this.caption = '',
    this.captionColor,
  });

  /// Phrases — each kept whole per placement (multi-word phrases wrap).
  final List<String> phrases;

  /// Quantise the photo to this many colours; ≥[_fullPalette] keeps raw colour,
  /// ≤1 also keeps raw colour, 2..63 median-cuts to K representative colours.
  final int palette;

  /// Largest word size at the reference long-side (words fill down from here).
  final double density;

  /// Max tilt (deg) a word may take when following the local flow (0 = upright).
  final double rotation;

  /// SIGNED −1..1 contrast. Sign picks the mode (≥0 light-on-dark, <0
  /// dark-on-white); magnitude deepens darks / lifts lights.
  final double contrast;

  /// 0..1 ground brightness — how dark the background floor is (0 darkest).
  final double ground;

  /// 0..1 letter vividness — 0 = true photo colours, up = more saturated.
  final double vivid;

  /// 0..1 empty space — 1 leaves dark areas bare (default); lower fills them in
  /// with shaded local colour so no area stays empty (0 = fully covered).
  final double empty;

  /// 0..1 coverage — packs whole phrases into the between-word gaps so the subject
  /// fills in denser (0 = as-was). The true background stays bare.
  final double coverage;

  /// Reshuffle key — change to get a new arrangement with the same settings.
  final int seedNonce;

  /// Optional photo title — drawn ONCE (upper-cased), larger than every word, in the
  /// bottom-left; the words pack around its reserved box. Empty = off.
  final String caption;

  /// Explicit title colour as a CSS string ('#rrggbb' or 'rgb(r,g,b)'). Null = auto
  /// (the base photo's colour at the title's position).
  final String? captionColor;

  @override
  bool operator ==(Object other) =>
      other is WordArtParams &&
      _listEq(other.phrases, phrases) &&
      other.palette == palette &&
      other.density == density &&
      other.rotation == rotation &&
      other.contrast == contrast &&
      other.ground == ground &&
      other.vivid == vivid &&
      other.empty == empty &&
      other.coverage == coverage &&
      other.seedNonce == seedNonce &&
      other.caption == caption &&
      other.captionColor == captionColor;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(phrases),
        palette,
        density,
        rotation,
        contrast,
        ground,
        vivid,
        empty,
        coverage,
        seedNonce,
        caption,
        captionColor,
      );

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One placed phrase (all coords in OUTPUT space).
class WordArtPlacement {
  const WordArtPlacement({
    required this.cx,
    required this.cy,
    required this.size,
    required this.angle,
    required this.weight,
    required this.lines,
    required this.color,
  });

  final double cx;
  final double cy;
  final double size; // font size in px
  final double angle; // radians
  final int weight; // 800 or 900
  final List<String> lines;
  final Color color;
}

/// Result of the pure packing pass: the ground colour + placed words.
class WordArtGeometry {
  const WordArtGeometry({required this.ground, required this.placements});
  final Color ground;
  final List<WordArtPlacement> placements;
}

// ── small internal carriers ────────────────────────────────────────────────
class _Measured {
  _Measured(this.words, this.widths, this.spaceW);
  final List<String> words;
  final List<double> widths; // per-unit (measured at 100px / 100)
  final double spaceW;
}

class _Line {
  _Line(this.text, this.w);
  final String text;
  final double w;
}

/// Oriented bounding box (cs/sn hold cos/sin of the angle).
class _Obb {
  _Obb(this.cx, this.cy, this.hw, this.hh, this.cs, this.sn);
  final double cx, cy, hw, hh, cs, sn;
}

double Function() _makeRng(int seed) {
  var s = seed & 0xFFFFFFFF;
  return () {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    return s / 4294967296.0;
  };
}

/// Push a 0..1 tone toward the extremes as [k] rises.
double _applyContrast(double n, double k) {
  if (k <= 0) return n;
  final e = 1 + 2.4 * k;
  return n < 0.5
      ? 0.5 * math.pow(2 * n, e).toDouble()
      : 1 - 0.5 * math.pow(2 * (1 - n), e).toDouble();
}

/// The word's ink colour — close to the real sampled photo colour, saturated by
/// [vivid], nudged by [tone]/[lift], then pushed to keep [_readMargin] of
/// luminance contrast from the ground [bgLum] so it stays legible.
Color _inkColor(double r, double g, double b, double vivid, double tone,
    bool dark, double bgLum, double lift) {
  final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  final sat = 1 + 1.6 * vivid;
  var nr = lum + (r - lum) * sat;
  var ng = lum + (g - lum) * sat;
  var nb = lum + (b - lum) * sat;
  if (dark) {
    final vp = 0.15 * tone + lift;
    nr += (255 - nr) * vp;
    ng += (255 - ng) * vp;
    nb += (255 - nb) * vp;
  } else {
    final vp = math.max(0.0, 0.15 * tone - lift);
    nr *= 1 - vp;
    ng *= 1 - vp;
    nb *= 1 - vp;
  }
  final nlum = 0.299 * nr + 0.587 * ng + 0.114 * nb;
  if (dark) {
    final minL = bgLum + _readMargin;
    if (nlum < minL) {
      final add = minL - nlum;
      nr += add;
      ng += add;
      nb += add;
    }
  } else {
    final maxL = bgLum - _readMargin;
    if (nlum > maxL) {
      final m = math.max(0.0, maxL) / math.max(1.0, nlum);
      nr *= m;
      ng *= m;
      nb *= m;
    }
  }
  return Color.fromARGB(255, _c255(nr), _c255(ng), _c255(nb));
}

/// Median-cut quantise the sampled buffer to [k] representative colours.
List<List<double>> _buildPalette(Uint8List base, int n, int k) {
  final step = math.max(1, (n / 4000).floor());
  var pts = <List<double>>[];
  for (var i = 0; i < n; i += step) {
    final j = i * 4;
    pts.add([base[j].toDouble(), base[j + 1].toDouble(), base[j + 2].toDouble()]);
  }
  if (pts.isEmpty) {
    return [
      [0, 0, 0]
    ];
  }
  final boxes = <List<List<double>>>[pts];
  while (boxes.length < k) {
    var bi = -1;
    var brange = -1.0;
    var axis = 0;
    for (var x = 0; x < boxes.length; x++) {
      final box = boxes[x];
      if (box.length < 2) continue;
      final mn = [255.0, 255.0, 255.0], mx = [0.0, 0.0, 0.0];
      for (final p in box) {
        for (var c = 0; c < 3; c++) {
          if (p[c] < mn[c]) mn[c] = p[c];
          if (p[c] > mx[c]) mx[c] = p[c];
        }
      }
      for (var c = 0; c < 3; c++) {
        final r = mx[c] - mn[c];
        if (r > brange) {
          brange = r;
          bi = x;
          axis = c;
        }
      }
    }
    if (bi < 0) break;
    final box = boxes[bi];
    box.sort((a, b) => a[axis].compareTo(b[axis]));
    final mid = box.length >> 1;
    boxes.replaceRange(bi, bi + 1, [box.sublist(0, mid), box.sublist(mid)]);
  }
  pts = [];
  return boxes.map((box) {
    var r = 0.0, g = 0.0, b = 0.0;
    for (final p in box) {
      r += p[0];
      g += p[1];
      b += p[2];
    }
    final m = box.isEmpty ? 1 : box.length;
    return [r / m, g / m, b / m];
  }).toList();
}

/// Nearest palette colour to (r,g,b).
List<double> _nearest(List<List<double>> pal, double r, double g, double b) {
  var best = pal[0];
  var bd = double.infinity;
  for (final p in pal) {
    final d = (p[0] - r) * (p[0] - r) +
        (p[1] - g) * (p[1] - g) +
        (p[2] - b) * (p[2] - b);
    if (d < bd) {
      bd = d;
      best = p;
    }
  }
  return best;
}

/// Greedily pack [words] into [lines] lines, balanced by (per-unit) width.
List<_Line> _wrapToLines(
    List<String> words, List<double> widths, double spaceW, int lines) {
  var total = 0.0;
  for (final x in widths) {
    total += x;
  }
  total += spaceW * (words.length - 1);
  final target = total / lines;
  final out = <_Line>[];
  final cur = <String>[];
  var curW = 0.0;
  for (var i = 0; i < words.length; i++) {
    final add = cur.isNotEmpty ? spaceW + widths[i] : widths[i];
    if (cur.isNotEmpty && out.length < lines - 1 && curW + add > target) {
      out.add(_Line(cur.join(' '), curW));
      cur
        ..clear()
        ..add(words[i]);
      curW = widths[i];
    } else {
      cur.add(words[i]);
      curW += add;
    }
  }
  out.add(_Line(cur.join(' '), curW));
  return out;
}

/// Pure packing pass. [rgba] is the pre-sampled base buffer (sw×sh) — it is NOT
/// re-sampled here. [w]/[h] are the OUTPUT dimensions.
WordArtGeometry buildWordArtGeometry(
    Uint8List rgba, int sw, int sh, double w, double h, WordArtParams p) {
  if (w < 2 || h < 2) {
    return const WordArtGeometry(ground: Color(0xFF000000), placements: []);
  }

  final phrases = p.phrases
      .map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
      .where((s) => s.isNotEmpty)
      .toList();
  if (phrases.isEmpty) phrases.add('WORD');

  final base = rgba;
  final np = sw * sh;
  final lumA = Float32List(np);
  for (var i = 0; i < np; i++) {
    final j = i * 4;
    lumA[i] =
        (0.299 * base[j] + 0.587 * base[j + 1] + 0.114 * base[j + 2]) / 255.0;
  }

  // Integral images over R,G,B (footprint-averaged colour) + a normalised local
  // detail map (edge energy) for detail-aware word sizing — the port of the web
  // renderer's composition precompute. (sw+1)×(sh+1); row/col 0 are zero.
  final iw = sw + 1;
  final intR = Float64List(iw * (sh + 1));
  final intG = Float64List(iw * (sh + 1));
  final intB = Float64List(iw * (sh + 1));
  final intD = Float64List(iw * (sh + 1));
  double detailScale = 1;
  {
    final detA = Float32List(np);
    var dsum = 0.0;
    for (var y = 0; y < sh; y++) {
      final yt = math.max(0, y - 1), yb = math.min(sh - 1, y + 1);
      for (var x = 0; x < sw; x++) {
        final xl = math.max(0, x - 1), xr = math.min(sw - 1, x + 1);
        final gx = lumA[y * sw + xr] - lumA[y * sw + xl];
        final gy = lumA[yb * sw + x] - lumA[yt * sw + x];
        final d = math.sqrt(gx * gx + gy * gy);
        detA[y * sw + x] = d;
        dsum += d;
      }
    }
    final dmean = (dsum / np) == 0 ? 1e-4 : dsum / np;
    detailScale = 1 / (_detailNorm * dmean);
    for (var y = 0; y < sh; y++) {
      var rowR = 0.0, rowG = 0.0, rowB = 0.0, rowD = 0.0;
      final oRow = (y + 1) * iw;
      final pRow = y * iw;
      for (var x = 0; x < sw; x++) {
        final j = (y * sw + x) * 4;
        rowR += base[j];
        rowG += base[j + 1];
        rowB += base[j + 2];
        rowD += detA[y * sw + x];
        intR[oRow + x + 1] = intR[pRow + x + 1] + rowR;
        intG[oRow + x + 1] = intG[pRow + x + 1] + rowG;
        intB[oRow + x + 1] = intB[pRow + x + 1] + rowB;
        intD[oRow + x + 1] = intD[pRow + x + 1] + rowD;
      }
    }
  }
  // Average of an integral image over the inclusive sample-pixel rect.
  double rectAvg(Float64List img, int x0, int y0, int x1, int y1) {
    x0 = x0 < 0 ? 0 : (x0 > sw - 1 ? sw - 1 : x0);
    x1 = x1 < 0 ? 0 : (x1 > sw - 1 ? sw - 1 : x1);
    y0 = y0 < 0 ? 0 : (y0 > sh - 1 ? sh - 1 : y0);
    y1 = y1 < 0 ? 0 : (y1 > sh - 1 ? sh - 1 : y1);
    if (x1 < x0) x1 = x0;
    if (y1 < y0) y1 = y0;
    final a = img[y0 * iw + x0], b = img[y0 * iw + (x1 + 1)];
    final c = img[(y1 + 1) * iw + x0], d = img[(y1 + 1) * iw + (x1 + 1)];
    final cnt = (x1 - x0 + 1) * (y1 - y0 + 1);
    return (d - b - c + a) / cnt;
  }

  final dark = p.contrast >= 0;

  // Ground colour derived from the photo: muted tint of its average colour,
  // lightness following a sigmoid of the contrast, floored so it's never pure.
  var ar = 0.0, ag = 0.0, ab = 0.0;
  var an = 0;
  final astep = math.max(1, (np / 6000).floor());
  for (var i = 0; i < np; i += astep) {
    final q = i * 4;
    ar += base[q];
    ag += base[q + 1];
    ab += base[q + 2];
    an++;
  }
  ar /= an;
  ag /= an;
  ab /= an;
  final agl = 0.299 * ar + 0.587 * ag + 0.114 * ab;
  var mr = ar + (agl - ar) * _mute;
  var mg = ag + (agl - ag) * _mute;
  var mb = ab + (agl - ab) * _mute;
  final t = 1 / (1 + math.exp(7 * p.contrast));
  final darkFloor = 12 + 120 * p.ground;
  final bgLum = darkFloor + (238 - darkFloor) * t;
  final f = bgLum / math.max(1.0, 0.299 * mr + 0.587 * mg + 0.114 * mb);
  mr *= f;
  mg *= f;
  mb *= f;
  final ground = Color.fromARGB(255, _c255(mr), _c255(mg), _c255(mb));

  final k0 = p.palette;
  final palette =
      (k0 >= 2 && k0 < _fullPalette) ? _buildPalette(base, np, k0) : null;

  final longSide = math.max(w, h);
  final maxWord = math.max(16.0, p.density * (longSide / _referenceLong));
  final minWord = maxWord * _minScale;
  final maxRot = (math.min(80.0, math.max(0.0, p.rotation)) * math.pi) / 180.0;
  final k = p.contrast.abs();
  final vivid = p.vivid;
  final emptyAmt = math.max(0.0, math.min(1.0, p.empty));

  int bx(double px) {
    final v = ((px * sw) / w).toInt();
    return v < 0 ? 0 : (v > sw - 1 ? sw - 1 : v);
  }

  int by(double py) {
    final v = ((py * sh) / h).toInt();
    return v < 0 ? 0 : (v > sh - 1 ? sh - 1 : v);
  }

  // Normalised local detail (0 = flat, 1 = busy) over an OUTPUT-coord window
  // `halfOut` around (px,py). Drives detail-aware word sizing.
  final oxToS = sw / w, oyToS = sh / h;
  double detailNormAt(double px, double py, double halfOut) {
    final cx = bx(px), cy = by(py);
    final hx = math.max(0, (halfOut * oxToS).round());
    final hy = math.max(0, (halfOut * oyToS).round());
    final d = rectAvg(intD, cx - hx, cy - hy, cx + hx, cy + hy) * detailScale;
    return d <= 0 ? 0.0 : (d >= 1 ? 1.0 : math.pow(d, _detailGamma).toDouble());
  }

  // Mean photo colour over a word's footprint (OUTPUT-coord AABB) — less speckle.
  List<double> footprintColor(
      double px, double py, double exOut, double eyOut) {
    final x0 = bx(px - exOut), x1 = bx(px + exOut);
    final y0 = by(py - eyOut), y1 = by(py + eyOut);
    return [
      rectAvg(intR, x0, y0, x1, y1),
      rectAvg(intG, x0, y0, x1, y1),
      rectAvg(intB, x0, y0, x1, y1),
    ];
  }

  double flowAngle(double px, double py) {
    final x = bx(px), y = by(py);
    final xl = math.max(0, x - 1), xr = math.min(sw - 1, x + 1);
    final yt = math.max(0, y - 1), yb = math.min(sh - 1, y + 1);
    final gx = lumA[y * sw + xr] - lumA[y * sw + xl];
    final gy = lumA[yb * sw + x] - lumA[yt * sw + x];
    if (math.sqrt(gx * gx + gy * gy) < _gradEps) return 0;
    var ang = math.atan2(gy, gx) + math.pi / 2;
    while (ang > math.pi / 2) {
      ang -= math.pi;
    }
    while (ang <= -math.pi / 2) {
      ang += math.pi;
    }
    return math.max(-maxRot, math.min(maxRot, ang));
  }

  // Collision via a spatial hash of placed oriented boxes.
  final bucket = math.max(4.0, minWord);
  final hash = <int, List<int>>{};
  final boxes = <_Obb>[];
  const hb = 100003;
  int bkey(int ix, int iy) {
    final a = ((ix % hb) + hb) % hb;
    final b = ((iy % hb) + hb) % hb;
    return a * 131071 + b;
  }

  double envX(_Obb o) => (o.hw * o.cs).abs() + (o.hh * o.sn).abs();
  double envY(_Obb o) => (o.hw * o.sn).abs() + (o.hh * o.cs).abs();

  bool obbOverlap(_Obb a, _Obb b) {
    final dx = b.cx - a.cx, dy = b.cy - a.cy;
    final axes = [a.cs, a.sn, -a.sn, a.cs, b.cs, b.sn, -b.sn, b.cs];
    for (var i = 0; i < 8; i += 2) {
      final lx = axes[i], ly = axes[i + 1];
      final dist = (dx * lx + dy * ly).abs();
      final ra = (a.hw * (a.cs * lx + a.sn * ly)).abs() +
          (a.hh * (-a.sn * lx + a.cs * ly)).abs();
      final rb = (b.hw * (b.cs * lx + b.sn * ly)).abs() +
          (b.hh * (-b.sn * lx + b.cs * ly)).abs();
      if (dist > ra + rb) return false;
    }
    return true;
  }

  bool collides(_Obb o) {
    final ex = envX(o), ey = envY(o);
    final i0 = ((o.cx - ex) / bucket).floor(), i1 = ((o.cx + ex) / bucket).floor();
    final j0 = ((o.cy - ey) / bucket).floor(), j1 = ((o.cy + ey) / bucket).floor();
    for (var ix = i0; ix <= i1; ix++) {
      for (var iy = j0; iy <= j1; iy++) {
        final arr = hash[bkey(ix, iy)];
        if (arr == null) continue;
        for (final bi in arr) {
          if (obbOverlap(o, boxes[bi])) return true;
        }
      }
    }
    return false;
  }

  void insert(_Obb o) {
    final bi = boxes.length;
    boxes.add(o);
    final ex = envX(o), ey = envY(o);
    final i0 = ((o.cx - ex) / bucket).floor(), i1 = ((o.cx + ex) / bucket).floor();
    final j0 = ((o.cy - ey) / bucket).floor(), j1 = ((o.cy + ey) / bucket).floor();
    for (var ix = i0; ix <= i1; ix++) {
      for (var iy = j0; iy <= j1; iy++) {
        (hash[bkey(ix, iy)] ??= <int>[]).add(bi);
      }
    }
  }

  final rnd = _makeRng(1000 + p.seedNonce * 7919);

  // Measure phrase widths once per (weight, phrase) — measured at 100px.
  final measureCache = <String, _Measured>{};
  _Measured measurePhrase(int weight, String phrase) {
    final key = '$weight|$phrase';
    final hit = measureCache[key];
    if (hit != null) return hit;
    final fw = weight == 900 ? FontWeight.w900 : FontWeight.w800;
    double measure(String s) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
              fontFamily: 'Inter', fontWeight: fw, fontSize: 100),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width;
    }

    final pw = phrase.split(' ');
    final widths = [for (final wd in pw) measure(wd) / 100.0];
    var spaceW = 0.0;
    if (pw.length > 1) {
      final full = measure(phrase) / 100.0;
      var sum = 0.0;
      for (final x in widths) {
        sum += x;
      }
      spaceW = (full - sum) / (pw.length - 1);
      if (spaceW < 0) spaceW = 0;
    }
    final v = _Measured(pw, widths, spaceW);
    measureCache[key] = v;
    return v;
  }

  // Candidate word sizes, largest first.
  final denom = math.max(1e-6, maxWord - minWord);
  final sizes = <double>[];
  for (var s = maxWord; s >= minWord; s *= _scaleStep) {
    sizes.add(s);
  }

  final placements = <WordArtPlacement>[];
  final fillAmt = (1 - emptyAmt) * 0.5;
  // Fair phrase distribution: round-robin on placement count (pick the least-used, random
  // among ties) so no phrase hogs the big/medium slots. Matches the web renderer.
  final useCount = List<int>.filled(phrases.length, 0);

  // Place ONE word at (px,py), trying sizes from [startSizeIdx] down. Shared by the main
  // pass and the gap-fill pass. Returns true if a word landed.
  bool placeWordAt(double px, double py, double tone, double cellVivid,
      double cellLift, int startSizeIdx,
      [List<double>? sizeList, bool skipToneGate = false]) {
    final useSizes = sizeList ?? sizes;
    final ang = flowAngle(px, py);
    final cAbs = math.cos(ang).abs(), sAbs = math.sin(ang).abs();
    final cosA = math.cos(ang), sinA = math.sin(ang);
    var pick = 0;
    if (phrases.length > 1) {
      var mn = 1 << 30;
      for (var i = 0; i < phrases.length; i++) {
        if (useCount[i] < mn) mn = useCount[i];
      }
      var cnt = 0;
      for (var i = 0; i < phrases.length; i++) {
        if (useCount[i] == mn) cnt++;
      }
      var r = (rnd() * cnt).toInt();
      for (var i = 0; i < phrases.length; i++) {
        if (useCount[i] == mn) {
          if (r == 0) {
            pick = i;
            break;
          }
          r--;
        }
      }
    }
    final phrase = phrases[pick];
    final weight = tone > 0.45 ? 900 : 800;
    final m = measurePhrase(weight, phrase);
    final maxL = math.min(_maxLines, m.words.length);

    // Cap the starting word size by local detail — busy areas (features) start
    // smaller so they resolve; flat masses keep the big words.
    var si0 = startSizeIdx;
    {
      final dRel = detailNormAt(px, py, math.max(minWord, maxWord * 0.2));
      final cap = maxWord * (1 - _detailShrink * dRel);
      while (si0 < useSizes.length - 1 && useSizes[si0] > cap) {
        si0++;
      }
    }

    for (var si = si0; si < useSizes.length; si++) {
      final s = useSizes[si];
      if (!skipToneGate) {
        final scaleNorm = (s - minWord) / denom;
        final toneMin = _skipTone + (0.55 - _skipTone) * scaleNorm;
        if (tone < toneMin) continue;
      }

      var bF = 0.0;
      var bLines = <_Line>[];
      var bMw = 0.0, bHPer = 0.0;
      for (var l = 1; l <= maxL; l++) {
        final lns = _wrapToLines(m.words, m.widths, m.spaceW, l);
        var mw = 0.0;
        for (final ln in lns) {
          if (ln.w > mw) mw = ln.w;
        }
        final hPer = _lineInk + (lns.length - 1) * _lineStep;
        final awPer = mw * cAbs + hPer * sAbs;
        final ahPer = mw * sAbs + hPer * cAbs;
        final fF = s / math.max(awPer, ahPer);
        if (fF > bF) {
          bF = fF;
          bLines = lns;
          bMw = mw;
          bHPer = hPer;
        }
      }
      if (bF < 3) break;

      // Reserve the placement's footprint (+ a hair of margin for the stroke).
      // A wrapped phrase reserves ONE box PER LINE, each only as wide as THAT line
      // (single-line → one box, identical to a whole-phrase box). This frees the
      // empty gutters beside a short line (e.g. "ME" under "POLJUBI") so later,
      // smaller words can fill them. Matches the web renderer.
      final margin = bF * _inkStroke * 0.5 + 1;
      final fullHw = (bMw * bF) / 2 + margin;
      final fullHh = (bHPer * bF) / 2 + margin;
      final cellBoxes = <_Obb>[];
      if (bLines.length > 1) {
        final lineStepPx = bF * _lineStep;
        final lineHh = (_lineInk * bF) / 2 + margin;
        var lyc = -((bLines.length - 1) * lineStepPx) / 2; // line centre (local y)
        for (final ln in bLines) {
          // local (0, lyc) → world via the word rotation (cs=cosA, sn=sinA).
          cellBoxes.add(_Obb(px - lyc * sinA, py + lyc * cosA,
              (ln.w * bF) / 2 + margin, lineHh, cosA, sinA));
          lyc += lineStepPx;
        }
      } else {
        cellBoxes.add(_Obb(px, py, fullHw, fullHh, cosA, sinA));
      }
      // Bounds check uses the full envelope (the whole phrase must fit on-canvas).
      final eX = (fullHw * cosA).abs() + (fullHh * sinA).abs();
      final eY = (fullHw * sinA).abs() + (fullHh * cosA).abs();
      if (px - eX < 0 || py - eY < 0 || px + eX > w || py + eY > h) continue;
      var blocked = false;
      for (final cb in cellBoxes) {
        if (collides(cb)) {
          blocked = true;
          break;
        }
      }
      if (blocked) continue;
      for (final cb in cellBoxes) {
        insert(cb);
      }
      useCount[pick]++;

      // Average the photo colour over the placed word's footprint (less speckle).
      final fc = footprintColor(px, py, eX, eY);
      var cr = fc[0], cg = fc[1], cb = fc[2];
      if (palette != null) {
        final pcol = _nearest(palette, cr, cg, cb);
        cr = pcol[0];
        cg = pcol[1];
        cb = pcol[2];
      }
      final col = _inkColor(cr, cg, cb, cellVivid, tone, dark, bgLum, cellLift);
      placements.add(WordArtPlacement(
        cx: px,
        cy: py,
        size: bF,
        angle: ang,
        weight: weight,
        lines: [for (final ln in bLines) ln.text],
        color: col,
      ));
      return true;
    }
    return false;
  }

  // Optional photo title — one large horizontal word reserved in the bottom-left; the fill
  // packs around its box (inserted BEFORE the loop). Always upper-cased.
  final caption =
      p.caption.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  if (caption.isNotEmpty) {
    double measureCap(String str) {
      final tp = TextPainter(
        text: TextSpan(
          text: str,
          style: const TextStyle(
              fontFamily: 'Inter', fontWeight: FontWeight.w900, fontSize: 100),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width / 100.0;
    }

    final capUnitW = math.max(1e-3, measureCap(caption));
    final pad = longSide * 0.04;
    final targetW = w * 0.42;
    final maxCapW = w - 2 * pad;
    var capSize = maxWord * 1.8;
    if (capUnitW * capSize > targetW) capSize = targetW / capUnitW;
    capSize = math.max(capSize, maxWord * 1.05);
    if (capUnitW * capSize > maxCapW) capSize = maxCapW / capUnitW;
    capSize = math.max(8.0, capSize);

    final capW = capUnitW * capSize;
    final capH = capSize * _lineInk;
    final capCx = pad + capW / 2;
    final capCy = h - pad - capH / 2;
    final capMargin = capSize * _inkStroke * 0.5 + 1;
    insert(_Obb(capCx, capCy, capW / 2 + capMargin, capH / 2 + capMargin, 1, 0));

    Color capCol;
    final chosen = _parseCssColor(p.captionColor);
    if (chosen != null) {
      capCol = chosen;
    } else {
      final cj = (by(capCy) * sw + bx(capCx)) * 4;
      var ccr = base[cj].toDouble(),
          ccg = base[cj + 1].toDouble(),
          ccb = base[cj + 2].toDouble();
      if (palette != null) {
        final pc = _nearest(palette, ccr, ccg, ccb);
        ccr = pc[0];
        ccg = pc[1];
        ccb = pc[2];
      }
      capCol = _inkColor(ccr, ccg, ccb, vivid, 1, dark, bgLum, 0);
    }
    placements.add(WordArtPlacement(
      cx: capCx,
      cy: capCy,
      size: capSize,
      angle: 0,
      weight: 900,
      lines: [caption],
      color: capCol,
    ));
  }

  final attempts = ((w * h) / (minWord * minWord) * _attemptFactor).ceil();

  for (var a = 0; a < attempts; a++) {
    final px = rnd() * w;
    final py = rnd() * h;
    final ci = (by(py) * sw + bx(px)) * 4;
    final cover0 = dark
        ? math.max(base[ci], math.max(base[ci + 1], base[ci + 2])) / 255.0
        : 1 - math.min(base[ci], math.min(base[ci + 1], base[ci + 2])) / 255.0;
    final tone0 = _applyContrast(cover0.toDouble(), k);
    double tone;
    var cellLift = 0.0;
    var cellVivid = vivid;
    if (tone0 >= _skipTone) {
      tone = tone0;
      cellVivid = vivid + fillAmt * 0.7;
      // denser where stronger; also lands more darts on detailed areas (features).
      final keep = math.min(
          1.0,
          math.pow(tone, _toneGamma).toDouble() *
              (1 + _dartBoost * detailNormAt(px, py, math.max(minWord, maxWord * 0.2))));
      if (rnd() > keep) continue;
    } else {
      if (fillAmt <= 0) continue;
      if (rnd() > fillAmt) continue;
      tone = _skipTone + fillAmt * (0.55 - _skipTone);
      cellLift = fillAmt * 0.4;
    }

    placeWordAt(px, py, tone, cellVivid, cellLift, 0);
  }

  // GAP-FILL PASS: sweep a grid; where a pocket is uncovered AND inkable (same rules as the
  // main pass), drop the biggest word that fits — tighter tiling, fewer visible gaps.
  var fillStartIdx = 0;
  while (fillStartIdx < sizes.length - 1 &&
      sizes[fillStartIdx] > maxWord * 0.55) {
    fillStartIdx++;
  }
  final fillStep = math.max(minWord * 1.4, bucket);
  final probeHalf = minWord * 0.45;
  for (var gy = fillStep * 0.5; gy < h; gy += fillStep) {
    for (var gx = fillStep * 0.5; gx < w; gx += fillStep) {
      final px = gx + (rnd() - 0.5) * fillStep;
      final py = gy + (rnd() - 0.5) * fillStep;
      if (px < 0 || py < 0 || px >= w || py >= h) continue;
      if (collides(_Obb(px, py, probeHalf, probeHalf, 1, 0))) continue;
      final ci = (by(py) * sw + bx(px)) * 4;
      final cover0 = dark
          ? math.max(base[ci], math.max(base[ci + 1], base[ci + 2])) / 255.0
          : 1 - math.min(base[ci], math.min(base[ci + 1], base[ci + 2])) / 255.0;
      final tone0 = _applyContrast(cover0.toDouble(), k);
      double tone;
      var cellLift = 0.0;
      var cellVivid = vivid;
      if (tone0 >= _skipTone) {
        tone = tone0;
        cellVivid = vivid + fillAmt * 0.7;
      } else {
        if (fillAmt <= 0) continue;
        tone = _skipTone + fillAmt * (0.55 - _skipTone);
        cellLift = fillAmt * 0.4;
      }
      placeWordAt(px, py, tone, cellVivid, cellLift, fillStartIdx);
    }
  }

  // COVERAGE PASS: packs WHOLE PHRASES (down to a small-but-readable size) into the
  // between-word gaps and pushes ink into the subject's mid/shadow tones, so the
  // picture reads as a denser field of words. Reuses placeWordAt with a smaller size
  // ladder + no tone gate; the true background stays bare. Mirrors the web renderer.
  final coverage = math.max(0.0, math.min(1.0, p.coverage));
  if (coverage > 0) {
    final covMin = math.max(5.0, minWord * (1 - 0.55 * coverage));
    final covTop = math.max(covMin + 1, maxWord * 0.45);
    final covSizes = <double>[];
    for (var s = covTop; s >= covMin; s *= _scaleStep) {
      covSizes.add(s);
    }
    final covStep = math.max(covMin, minWord * (1.25 - 0.95 * coverage));
    final covFloor = _skipTone * (1 - 0.6 * coverage);
    final covProbeHalf = covMin * 0.4;
    final covRnd = _makeRng(4271 + p.seedNonce * 613);
    for (var gy = covStep * 0.5; gy < h; gy += covStep) {
      for (var gx = covStep * 0.5; gx < w; gx += covStep) {
        final px = gx + (covRnd() - 0.5) * covStep;
        final py = gy + (covRnd() - 0.5) * covStep;
        if (px < 0 || py < 0 || px >= w || py >= h) continue;
        if (collides(_Obb(px, py, covProbeHalf, covProbeHalf, 1, 0))) continue;
        final ci = (by(py) * sw + bx(px)) * 4;
        final cover0 = dark
            ? math.max(base[ci], math.max(base[ci + 1], base[ci + 2])) / 255.0
            : 1 - math.min(base[ci], math.min(base[ci + 1], base[ci + 2])) / 255.0;
        final tone0 = _applyContrast(cover0.toDouble(), k);
        if (tone0 < covFloor) continue; // leave the true background bare
        final tone = math.max(tone0, _skipTone);
        placeWordAt(px, py, tone, vivid, 0, 0, covSizes, true);
      }
    }
  }

  return WordArtGeometry(ground: ground, placements: placements);
}

/// Paints the ground then each placed phrase (stroke + fill, rotated).
class WordArtPainter extends CustomPainter {
  WordArtPainter(this.geo);
  final WordArtGeometry geo;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = geo.ground,
    );
    for (final pl in geo.placements) {
      canvas.save();
      canvas.translate(pl.cx, pl.cy);
      if (pl.angle != 0) canvas.rotate(pl.angle);
      final fw = pl.weight == 900 ? FontWeight.w900 : FontWeight.w800;
      final lineH = pl.size * _lineStep;
      final strokeW = pl.size * _inkStroke;
      var ly = -((pl.lines.length - 1) * lineH) / 2;
      for (final ln in pl.lines) {
        // Stroke first (fattens the glyph), then fill on top — same colour.
        final strokePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeJoin = StrokeJoin.round
          ..color = pl.color;
        final tpStroke = TextPainter(
          text: TextSpan(
            text: ln,
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: fw,
              fontSize: pl.size,
              foreground: strokePaint,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        tpStroke.paint(
            canvas, Offset(-tpStroke.width / 2, ly - tpStroke.height / 2));

        final tpFill = TextPainter(
          text: TextSpan(
            text: ln,
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: fw,
              fontSize: pl.size,
              color: pl.color,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        tpFill.paint(canvas, Offset(-tpFill.width / 2, ly - tpFill.height / 2));
        ly += lineH;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant WordArtPainter old) => old.geo != geo;
}

/// Rasterise the word-art geometry to a [ui.Image] (preview + export).
Future<ui.Image> renderWordArtImage(
    WordArtGeometry geo, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas =
      Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  WordArtPainter(geo).paint(canvas, Size(w.toDouble(), h.toDouble()));
  final pic = recorder.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

/// Serialise a computed layout into the shape the server's `bakedLayout` expects
/// (`{ ground, words:[{cx,cy,angle,size,weight,color,strokeWidth,lines:[{text,y}]}], w, h }`),
/// so the high-res export reproduces THIS exact arrangement instead of re-packing.
Map<String, dynamic> wordArtLayoutJson(WordArtGeometry geo, int w, int h) {
  String css(Color c) {
    final v = c.toARGB32();
    return 'rgb(${(v >> 16) & 0xFF},${(v >> 8) & 0xFF},${v & 0xFF})';
  }

  final words = <Map<String, dynamic>>[];
  for (final pl in geo.placements) {
    final lineH = pl.size * _lineStep;
    var ly = -((pl.lines.length - 1) * lineH) / 2;
    final lines = <Map<String, dynamic>>[];
    for (final ln in pl.lines) {
      lines.add({'text': ln, 'y': ly});
      ly += lineH;
    }
    words.add({
      'cx': pl.cx,
      'cy': pl.cy,
      'angle': pl.angle,
      'size': pl.size,
      'weight': pl.weight,
      'color': css(pl.color),
      'strokeWidth': pl.size * _inkStroke,
      'lines': lines,
    });
  }
  return {'ground': css(geo.ground), 'words': words, 'w': w, 'h': h};
}

/// Suggest a small set of dominant colours from a decoded RGBA buffer, for the
/// word-art title-colour picker. Dart port of the web `suggestColorsFromImage`
/// (`foto-mozaik/lib/wordart/suggest-colors.ts`): coarse 4-bit/channel quantise
/// → frequency-rank → greedily drop near-duplicates. Returns `#rrggbb` strings,
/// most dominant first. [rgba] is row-major RGBA for a [w]×[h] image.
List<String> suggestColorsFromRgba(Uint8List rgba, int w, int h,
    {int count = 6}) {
  if (w < 1 || h < 1 || rgba.length < w * h * 4) return const [];
  // Coarse sampling stride so we scan ~64×64 pixels regardless of source size.
  final stepX = math.max(1, w ~/ 64);
  final stepY = math.max(1, h ~/ 64);
  final buckets = <int, List<int>>{}; // key -> [n, rSum, gSum, bSum]
  for (var y = 0; y < h; y += stepY) {
    final row = y * w * 4;
    for (var x = 0; x < w; x += stepX) {
      final i = row + x * 4;
      if (rgba[i + 3] < 128) continue; // skip transparent
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      final e = buckets[key];
      if (e != null) {
        e[0]++;
        e[1] += r;
        e[2] += g;
        e[3] += b;
      } else {
        buckets[key] = [1, r, g, b];
      }
    }
  }

  final list = buckets.values
      .map((e) => [
            e[0],
            (e[1] / e[0]).round(),
            (e[2] / e[0]).round(),
            (e[3] / e[0]).round(),
          ])
      .toList()
    ..sort((a, b) => b[0] - a[0]);

  final picked = <List<int>>[];
  for (final bk in list) {
    if (picked.length >= count) break;
    final tooClose = picked.any((p) =>
        (p[1] - bk[1]).abs() + (p[2] - bk[2]).abs() + (p[3] - bk[3]).abs() < 56);
    if (tooClose) continue;
    picked.add(bk);
  }

  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return picked.map((p) => '#${hex(p[1])}${hex(p[2])}${hex(p[3])}').toList();
}
