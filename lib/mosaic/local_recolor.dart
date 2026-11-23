import 'dart:math' as math;
import 'dart:typed_data';

import 'hexagon.dart' show hexFromRect;
import 'rhombille.dart' show faceShade;
import 'tile_recolor.dart'
    show chromaScale, effectiveRecolorStrength, tileToning, toneChroma, toneMatrix;

/// LOCAL (in-cell) tile recolouring — the exact Dart port of `applyLocalRecolor` /
/// `recolorCellLocal` in foto-mozaik/lib/mosaic/render.ts (the web studio preview).
/// Keep the two identical: `test/local_recolor_test.dart` checks it byte for byte
/// against the web's output (fixture from scripts/local-recolor-fidelity-gen.ts).
///
/// Applied to tiles already drawn into an RGBA buffer. Per cell, with the photo's 5×5
/// colours under it:  out = k·(t − tLow) + tLow + s·(pLow′ − tLow′)
/// (tLow = the toned tile's own 5×5 block means, both low-passes bilinear; primes pulled
/// toward the cell averages by 1 − detail). The tile keeps its detail (at contrast k),
/// the broad light/colour follows the photo — a dark area shifts the tile down instead
/// of squashing it to black, and sub-cell features (a jacket's stripes) appear.

const int _grid = 5;

/// How much of the photo's variation inside a cell the recolour follows (web: 0.4).
const double localDetail = 0.4;

/// Soft cap on the recolour's cell-wide brightness move, in 0–255 luma levels. Mirrors
/// web `RECOLOR_LUMA_CAP` (lib/mosaic/render.ts) — keep the two identical.
const double recolorLumaCap = 25;
const double recolorMisfitKnee = 50;
const double recolorMisfitSlope = 0.7;

/// What to add to every channel so a brightness move [delta] becomes
/// `cap·(1 − e^(−|delta|/cap))`.
double recolorLumaCapBack(double delta) {
  final mag = delta.abs();
  if (mag <= 0.5) return 0;
  // Brightening is not capped (2026-11-10): with a dark library the photo's light areas
  // need lifts of 40–60 levels, and capping them left the face ~25–30 levels too dark —
  // the main reason a competitor's mosaic of the same photos read clearer. Darkening
  // keeps the cap (over-darkened tiles were what the cap was added for).
  if (delta > 0) return 0;
  // Misfit-aware: past [recolorMisfitKnee] the photo is clearly in the wrong brightness
  // and is moved again at [recolorMisfitSlope] (web parity).
  final capped =
      recolorLumaCap * (1 - math.exp(-mag / recolorLumaCap)) +
      recolorMisfitSlope * math.max(0.0, mag - recolorMisfitKnee);
  return (delta < 0 ? -capped : capped) - delta;
}

/// Which pixels belong to a shaped cell (honeycomb / cube face); null = the whole rect.
sealed class RecolorMask {
  const RecolorMask();
  bool contains(double px, double py);
}

/// Flat-top hexagon of full width [w] and height [h], half-open like the web's hexMask.
class HexMask extends RecolorMask {
  const HexMask(this.cx, this.cy, this.w, this.h);
  final double cx, cy, w, h;

  @override
  bool contains(double px, double py) {
    final hw = w / 2, hh = h / 2;
    final ry = py - cy, dy = ry.abs();
    if (ry < -hh || ry >= hh) return false;
    final lim = hw - (dy / hh) * (w / 4), rx = px - cx;
    return rx >= -lim && rx < lim;
  }
}

/// Parallelogram q0 + a·u + b·v, 0 ≤ a, b < 1 — the web's quadMask.
class QuadMask extends RecolorMask {
  QuadMask(this.q)
    : _ux = q[2] - q[0],
      _uy = q[3] - q[1],
      _vx = q[6] - q[0],
      _vy = q[7] - q[1];
  final List<double> q;
  final double _ux, _uy, _vx, _vy;

  @override
  bool contains(double px, double py) {
    final det = _ux * _vy - _uy * _vx;
    final dx = px - q[0], dy = py - q[1];
    final a = (dx * _vy - dy * _vx) / det, b = (_ux * dy - _uy * dx) / det;
    return a >= 0 && a < 1 && b >= 0 && b < 1;
  }
}

/// One cell to recolour: its rectangle in buffer pixels, the photo under it (average
/// + optional 5×5 RGB grid, 75 values row-major) and, for shaped cells, its mask.
class RecolorCell {
  RecolorCell({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.avg,
    this.grid,
    this.mask,
    this.shade = 1,
  });

  final double x, y, w, h;
  final List<double> avg;
  final Float64List? grid;
  final RecolorMask? mask;
  final double shade;
}

/// Uint8ClampedArray assignment: clamp to 0..255, round half to EVEN (what the
/// browser does on every canvas write — needed for byte-exact parity).
///
/// Rounds to nearest, then moves an exact tie (x.5) to the even neighbour. The old
/// above/below-half test was a coin toss per channel — a mispredicted branch on half
/// of every pixel's values; an exact tie is rare, so this one is almost never taken.
@pragma('vm:prefer-inline')
int _u8(double v) {
  if (!(v > 0)) return 0; // also NaN
  if (v >= 255) return 255;
  final r = v.roundToDouble(); // nearest, ties away from zero (v > 0: up)
  final ri = r.toInt();
  // r − v is exact here (both under 256, less than 1 apart).
  return (r - v == 0.5 && ri.isOdd) ? ri - 1 : ri;
}

/// The photo's 5×5 Lab samples as an RGB grid (web: labToRgb per block).
Float64List labGridToRgb(List<List<double>> lab) {
  final out = Float64List(_grid * _grid * 3);
  for (var b = 0; b < _grid * _grid && b < lab.length; b++) {
    final rgb = labToRgb(lab[b][0], lab[b][1], lab[b][2]);
    out[b * 3] = rgb[0];
    out[b * 3 + 1] = rgb[1];
    out[b * 3 + 2] = rgb[2];
  }
  return out;
}

const double _labEpsilon = 0.008856, _labKappa = 903.3;

/// Port of the web's labToRgb (D65, sRGB) — clamped 0..255, not rounded.
List<double> labToRgb(double L, double a, double b) {
  final fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
  double inv(double f) =>
      f * f * f > _labEpsilon ? f * f * f : (116 * f - 16) / _labKappa;
  final x = inv(fx) * 0.95047,
      y = L > _labKappa * _labEpsilon ? fy * fy * fy : L / _labKappa,
      z = inv(fz) * 1.08883;
  final lin = [
    3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
    -0.969266 * x + 1.8760108 * y + 0.041556 * z,
    0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
  ];
  double enc(double v) {
    final c = v <= 0.0031308
        ? 12.92 * v
        // 0.0, not 0: an int here made every max a slow mixed int/double compare.
        : 1.055 * math.pow(math.max(0.0, v), 1 / 2.4) - 0.055;
    return math.max(0, math.min(255, c * 255));
  }

  return [enc(lin[0]), enc(lin[1]), enc(lin[2])];
}

/// Recolour [cells] in [data] (RGBA, [width]×[height]) in place, then apply the output
/// saturation grade — the same result as the web's applyLocalRecolor followed by its
/// grade (fused or not).
void applyLocalRecolor(
  Uint8List data,
  int width,
  int height,
  List<RecolorCell> cells,
  double strength, {
  double detail = localDetail,
  double outputSaturation = 1,
}) {
  final s0 = strength.clamp(0.0, 1.0);
  if (s0 > 0 && cells.isNotEmpty) {
    final toning = tileToning(s0);
    final m = toneMatrix(toning.saturation);
    final t = _TermTables(m);
    // Same order as the web: by top row, ties keep their order (JS sort is stable).
    final entries = <(RecolorCell, int, int)>[];
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      final top = math.max(0, c.y.floor()),
          bottom = math.min(height, (c.y + c.h).ceil());
      if (bottom > top && c.x < width && c.x + c.w > 0)
        entries.add((c, top, i));
    }
    entries.sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$3 - b.$3);
    for (final e in entries) {
      _recolorCell(
        data,
        width,
        height,
        e.$1,
        s0,
        toning.contrast,
        m,
        t,
        detail,
      );
    }
  }
  applySaturation(data, outputSaturation.clamp(1.0, 1.5));
}

/// The web's applySaturation (luminance-preserving matrix), canvas rounding.
void applySaturation(Uint8List data, double s) {
  if (s == 1) return;
  final t = _TermTables(toneMatrix(s));
  final t0 = t.t0, t1 = t.t1, t2 = t.t2;
  final t3 = t.t3, t4 = t.t4, t5 = t.t5;
  final t6 = t.t6, t7 = t.t7, t8 = t.t8;
  for (var i = 0; i < data.length; i += 4) {
    final r = data[i], g = data[i + 1], b = data[i + 2];
    data[i] = _u8(t0[r] + t1[g] + t2[b]);
    data[i + 1] = _u8(t3[r] + t4[g] + t5[b]);
    data[i + 2] = _u8(t6[r] + t7[g] + t8[b]);
  }
}

/// A 3×3 colour matrix as 9 tables of coefficient × byte value. A channel has 256
/// values, so each product is a lookup — the same product, so the same sums and bytes.
class _TermTables {
  _TermTables(List<double> m)
    : t0 = _term(m[0]),
      t1 = _term(m[1]),
      t2 = _term(m[2]),
      t3 = _term(m[3]),
      t4 = _term(m[4]),
      t5 = _term(m[5]),
      t6 = _term(m[6]),
      t7 = _term(m[7]),
      t8 = _term(m[8]);
  final Float64List t0, t1, t2, t3, t4, t5, t6, t7, t8;
  static Float64List _term(double k) =>
      Float64List.fromList([for (var v = 0; v < 256; v++) k * v.toDouble()]);
}

void _recolorCell(
  Uint8List data,
  int width,
  int height,
  RecolorCell cell,
  double s0,
  double k,
  List<double> mt,
  _TermTables tt,
  double detail,
) {
  final t0 = tt.t0, t1 = tt.t1, t2 = tt.t2;
  final t3 = tt.t3, t4 = tt.t4, t5 = tt.t5;
  final t6 = tt.t6, t7 = tt.t7, t8 = tt.t8;
  const n5 = _grid;
  final x0 = math.max(0, cell.x.floor()),
      x1 = math.min(width, (cell.x + cell.w).ceil());
  final y0 = math.max(0, cell.y.floor()),
      y1 = math.min(height, (cell.y + cell.h).ceil());
  if (x1 <= x0 || y1 <= y0) return;
  final cw = x1 - x0;
  final m00 = mt[0], m01 = mt[1], m02 = mt[2];
  final m10 = mt[3], m11 = mt[4], m12 = mt[5];
  final m20 = mt[6], m21 = mt[7], m22 = mt[8];

  final colBlock = Int32List(cw), colA = Int32List(cw), colB = Int32List(cw);
  final colW = Float32List(cw);
  for (var x = x0; x < x1; x++) {
    final u = (x + 0.5 - cell.x) / cell.w;
    colBlock[x - x0] = math.min(n5 - 1, math.max(0, (u * n5).floor()));
    final f = math.max(0.0, math.min(n5 - 1.0, u * n5 - 0.5));
    final a = f.floor();
    colA[x - x0] = a;
    colB[x - x0] = math.min(n5 - 1, a + 1);
    colW[x - x0] = f - a;
  }

  // Pass 1: untoned mean (misfit boost) + toned 5×5 block sums.
  final mask = cell.mask;
  final sums = Float64List(n5 * n5 * 3), counts = Float64List(n5 * n5);
  var mr = 0.0, mg = 0.0, mb = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    final gy =
        math.min(
          n5 - 1,
          math.max(0, (((y + 0.5 - cell.y) / cell.h) * n5).floor()),
        ) *
        n5;
    var i = (y * width + x0) * 4;
    for (var c = 0; c < cw; c++, i += 4) {
      if (mask != null && !mask.contains(x0 + c + 0.5, y + 0.5)) continue;
      final ri = data[i], gi = data[i + 1], bi8 = data[i + 2];
      mr += ri;
      mg += gi;
      mb += bi8;
      n++;
      final bi = gy + colBlock[c], b3 = bi * 3;
      sums[b3] += t0[ri] + t1[gi] + t2[bi8];
      sums[b3 + 1] += t3[ri] + t4[gi] + t5[bi8];
      sums[b3 + 2] += t6[ri] + t7[gi] + t8[bi8];
      counts[bi]++;
    }
  }
  if (n == 0) return;
  // Cube faces: the shading is already drawn, so aim at the shaded photo colour.
  final sh = cell.shade;
  final avg0 = cell.avg;
  final avg = sh == 1 ? avg0 : [avg0[0] * sh, avg0[1] * sh, avg0[2] * sh];
  final s = effectiveRecolorStrength(avg, [mr / n, mg / n, mb / n], s0);

  final gField = Float64List(n5 * n5 * 3);
  final grid = cell.grid;
  final tmr = m00 * (mr / n) + m01 * (mg / n) + m02 * (mb / n);
  final tmg = m10 * (mr / n) + m11 * (mg / n) + m12 * (mb / n);
  final tmb = m20 * (mr / n) + m21 * (mg / n) + m22 * (mb / n);
  final d = detail.clamp(0.0, 1.0);
  for (var bIdx = 0; bIdx < n5 * n5; bIdx++) {
    var src = bIdx;
    if (counts[bIdx] == 0) {
      var best = double.infinity;
      for (var o = 0; o < n5 * n5; o++) {
        if (counts[o] != 0) {
          final dd =
              ((o % n5) - (bIdx % n5)).abs() + ((o ~/ n5) - (bIdx ~/ n5)).abs();
          if (dd < best) {
            best = dd.toDouble();
            src = o;
          }
        }
      }
    }
    final cnt = counts[src] == 0 ? 1.0 : counts[src];
    double r0, g0, b0;
    if (grid != null) {
      r0 = grid[bIdx * 3];
      g0 = grid[bIdx * 3 + 1];
      b0 = grid[bIdx * 3 + 2];
    } else {
      r0 = avg0[0];
      g0 = avg0[1];
      b0 = avg0[2];
    }
    final rr = sh == 1 ? r0 : r0 * sh,
        rg = sh == 1 ? g0 : g0 * sh,
        rb = sh == 1 ? b0 : b0 * sh;
    final tl0 = sums[src * 3] / cnt,
        tl1 = sums[src * 3 + 1] / cnt,
        tl2 = sums[src * 3 + 2] / cnt;
    final tLr = tmr + d * (tl0 - tmr),
        tLg = tmg + d * (tl1 - tmg),
        tLb = tmb + d * (tl2 - tmb);
    final pLr = avg[0] + d * (rr - avg[0]),
        pLg = avg[1] + d * (rg - avg[1]),
        pLb = avg[2] + d * (rb - avg[2]);
    // Only toneChroma of the shift's colour, all of its brightness (web parity).
    gField[bIdx * 3] = s * (pLr - tLr);
    gField[bIdx * 3 + 1] = s * (pLg - tLg);
    gField[bIdx * 3 + 2] = s * (pLb - tLb);
    if (toneChroma < 1) chromaScale(gField, toneChroma, bIdx * 3);
    gField[bIdx * 3] = (1 - k) * tl0 + gField[bIdx * 3];
    gField[bIdx * 3 + 1] = (1 - k) * tl1 + gField[bIdx * 3 + 1];
    gField[bIdx * 3 + 2] = (1 - k) * tl2 + gField[bIdx * 3 + 2];
  }
  {
    // Brightness cap — same as web `applyLocalRecolor`: the cell-wide lift or darkening
    // is softly limited to [recolorLumaCap] luma levels, the excess taken back evenly so
    // hue and the 5×5 pattern are unchanged.
    final delta =
        s *
        (0.299 * (avg[0] - tmr) +
            0.587 * (avg[1] - tmg) +
            0.114 * (avg[2] - tmb));
    final back = recolorLumaCapBack(delta);
    if (back != 0) {
      for (var q = 0; q < n5 * n5 * 3; q++) {
        gField[q] += back;
      }
    }
  }

  // Pass 2.
  for (var y = y0; y < y1; y++) {
    final fy = math.max(
      0.0,
      math.min(n5 - 1.0, ((y + 0.5 - cell.y) / cell.h) * n5 - 0.5),
    );
    final ya = fy.floor(), yb = math.min(n5 - 1, ya + 1);
    final wy = fy - ya, wy1 = 1 - wy;
    final ra = ya * n5, rb = yb * n5;
    var i = (y * width + x0) * 4;
    for (var c = 0; c < cw; c++, i += 4) {
      if (mask != null && !mask.contains(x0 + c + 0.5, y + 0.5)) continue;
      final wx = colW[c].toDouble(), wx1 = 1 - wx;
      final p00 = (ra + colA[c]) * 3, p01 = (ra + colB[c]) * 3;
      final p10 = (rb + colA[c]) * 3, p11 = (rb + colB[c]) * 3;
      final w00 = wx1 * wy1, w01 = wx * wy1, w10 = wx1 * wy, w11 = wx * wy;
      final r = data[i], g = data[i + 1], b = data[i + 2];
      data[i] = _u8(
        k * (t0[r] + t1[g] + t2[b]) +
            gField[p00] * w00 +
            gField[p01] * w01 +
            gField[p10] * w10 +
            gField[p11] * w11,
      );
      data[i + 1] = _u8(
        k * (t3[r] + t4[g] + t5[b]) +
            gField[p00 + 1] * w00 +
            gField[p01 + 1] * w01 +
            gField[p10 + 1] * w10 +
            gField[p11 + 1] * w11,
      );
      data[i + 2] = _u8(
        k * (t6[r] + t7[g] + t8[b]) +
            gField[p00 + 2] * w00 +
            gField[p01 + 2] * w01 +
            gField[p10 + 2] * w10 +
            gField[p11 + 2] * w11,
      );
    }
  }
}

/// The recolour cell of a honeycomb or cube placement drawn at [kx]/[ky] buffer px per
/// base px, shifted by ([offX], [offY]) — the web's shapedRecolorCell. Null for rects.
RecolorCell? shapedRecolorCell({
  required double x,
  required double y,
  required double width,
  required double height,
  required List<double>? quad,
  required String? face,
  required bool hexagon,
  required List<double> avg,
  required Float64List? grid,
  required double kx,
  required double ky,
  required double offX,
  required double offY,
}) {
  if (quad != null) {
    final q = [
      for (var k = 0; k < 8; k++)
        k.isEven ? quad[k] * kx - offX : quad[k] * ky - offY,
    ];
    final xs = [q[0], q[2], q[4], q[6]], ys = [q[1], q[3], q[5], q[7]];
    final bx = xs.reduce(math.min), by = ys.reduce(math.min);
    return RecolorCell(
      x: bx,
      y: by,
      w: xs.reduce(math.max) - bx,
      h: ys.reduce(math.max) - by,
      avg: avg,
      grid: grid,
      mask: QuadMask(q),
      shade: face != null ? (faceShade[face] ?? 1) : 1,
    );
  }
  if (hexagon) {
    final hc = hexFromRect(x, y, width, height);
    final cx = hc.cx * kx - offX, cy = hc.cy * ky - offY;
    final w = hc.s * 2 * kx, h = hc.s * math.sqrt(3) * ky;
    return RecolorCell(
      x: cx - w / 2,
      y: cy - h / 2,
      w: w,
      h: h,
      avg: avg,
      grid: grid,
      mask: HexMask(cx, cy, w, h),
    );
  }
  return null;
}

/// [c] moved by ([dx], [dy]) — mask included (cells drawn into an atlas slot).
RecolorCell offsetRecolorCell(RecolorCell c, double dx, double dy) {
  final m = c.mask;
  final RecolorMask? moved = switch (m) {
    null => null,
    HexMask() => HexMask(m.cx + dx, m.cy + dy, m.w, m.h),
    QuadMask() => QuadMask([
      for (var k = 0; k < 8; k++) m.q[k] + (k.isEven ? dx : dy),
    ]),
  };
  return RecolorCell(
    x: c.x + dx,
    y: c.y + dy,
    w: c.w,
    h: c.h,
    avg: c.avg,
    grid: c.grid,
    mask: moved,
    shade: c.shade,
  );
}
