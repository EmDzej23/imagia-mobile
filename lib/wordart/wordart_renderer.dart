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

int _c255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.toInt());

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
    this.seedNonce = 0,
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

  /// Reshuffle key — change to get a new arrangement with the same settings.
  final int seedNonce;

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
      other.seedNonce == seedNonce;

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
        seedNonce,
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
  final attempts = ((w * h) / (minWord * minWord) * _attemptFactor).ceil();

  for (var a = 0; a < attempts; a++) {
    final px = rnd() * w;
    final py = rnd() * h;
    final ci = (by(py) * sw + bx(px)) * 4;
    final cover0 = dark
        ? math.max(base[ci], math.max(base[ci + 1], base[ci + 2])) / 255.0
        : 1 - math.min(base[ci], math.min(base[ci + 1], base[ci + 2])) / 255.0;
    final fillAmt = (1 - emptyAmt) * 0.5;
    final tone0 = _applyContrast(cover0.toDouble(), k);
    double tone;
    var cellLift = 0.0;
    var cellVivid = vivid;
    if (tone0 >= _skipTone) {
      tone = tone0;
      cellVivid = vivid + fillAmt * 0.7;
      if (rnd() > math.pow(tone, _toneGamma)) continue;
    } else {
      if (fillAmt <= 0) continue;
      if (rnd() > fillAmt) continue;
      tone = _skipTone + fillAmt * (0.55 - _skipTone);
      cellLift = fillAmt * 0.4;
    }

    final ang = flowAngle(px, py);
    final cAbs = math.cos(ang).abs(), sAbs = math.sin(ang).abs();
    final cosA = math.cos(ang), sinA = math.sin(ang);
    final phrase = phrases[(rnd() * phrases.length).toInt().clamp(0, phrases.length - 1)];
    final weight = tone > 0.45 ? 900 : 800;
    final m = measurePhrase(weight, phrase);
    final maxL = math.min(_maxLines, m.words.length);

    for (var si = 0; si < sizes.length; si++) {
      final s = sizes[si];
      final scaleNorm = (s - minWord) / denom;
      final toneMin = _skipTone + (0.55 - _skipTone) * scaleNorm;
      if (tone < toneMin) continue;

      // Fit the phrase so its oriented box's largest side ≈ s.
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
      if (bF < 3) break; // this and every smaller size too tiny

      final margin = bF * _inkStroke * 0.5 + 1;
      final obb = _Obb(
        px,
        py,
        (bMw * bF) / 2 + margin,
        (bHPer * bF) / 2 + margin,
        cosA,
        sinA,
      );
      final eX = (obb.hw * cosA).abs() + (obb.hh * sinA).abs();
      final eY = (obb.hw * sinA).abs() + (obb.hh * cosA).abs();
      if (px - eX < 0 || py - eY < 0 || px + eX > w || py + eY > h) continue;
      if (collides(obb)) continue;
      insert(obb);

      final j = (by(py) * sw + bx(px)) * 4;
      var cr = base[j].toDouble(), cg = base[j + 1].toDouble(), cb = base[j + 2].toDouble();
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
      break; // placed → next dart
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
