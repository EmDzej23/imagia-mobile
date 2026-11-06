import 'dart:math' as math;
import 'dart:typed_data';

import 'hexagon.dart' show hexFromRect;
import 'rhombille.dart' show faceShade;
import 'tile_recolor.dart'
    show effectiveRecolorStrength, tileToning, toneMatrix;

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
int _u8(double v) {
  if (!(v > 0)) return 0; // also NaN
  if (v >= 255) return 255;
  final f = v.floorToDouble();
  final d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  final fi = f.toInt();
  return fi.isEven ? fi : fi + 1;
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
        : 1.055 * math.pow(math.max(0, v), 1 / 2.4) - 0.055;
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
      _recolorCell(data, width, height, e.$1, s0, toning.contrast, m, detail);
    }
  }
  applySaturation(data, outputSaturation.clamp(1.0, 1.5));
}

/// The web's applySaturation (luminance-preserving matrix), canvas rounding.
void applySaturation(Uint8List data, double s) {
  if (s == 1) return;
  final m = toneMatrix(s);
  for (var i = 0; i < data.length; i += 4) {
    final r = data[i].toDouble(),
        g = data[i + 1].toDouble(),
        b = data[i + 2].toDouble();
    data[i] = _u8(m[0] * r + m[1] * g + m[2] * b);
    data[i + 1] = _u8(m[3] * r + m[4] * g + m[5] * b);
    data[i + 2] = _u8(m[6] * r + m[7] * g + m[8] * b);
  }
}

void _recolorCell(
  Uint8List data,
  int width,
  int height,
  RecolorCell cell,
  double s0,
  double k,
  List<double> mt,
  double detail,
) {
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
      final r = data[i].toDouble(),
          g = data[i + 1].toDouble(),
          b = data[i + 2].toDouble();
      mr += r;
      mg += g;
      mb += b;
      n++;
      final bi = gy + colBlock[c], b3 = bi * 3;
      sums[b3] += m00 * r + m01 * g + m02 * b;
      sums[b3 + 1] += m10 * r + m11 * g + m12 * b;
      sums[b3 + 2] += m20 * r + m21 * g + m22 * b;
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
    gField[bIdx * 3] = (1 - k) * tl0 + s * (pLr - tLr);
    gField[bIdx * 3 + 1] = (1 - k) * tl1 + s * (pLg - tLg);
    gField[bIdx * 3 + 2] = (1 - k) * tl2 + s * (pLb - tLb);
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
      final r = data[i].toDouble(),
          g = data[i + 1].toDouble(),
          b = data[i + 2].toDouble();
      data[i] = _u8(
        k * (m00 * r + m01 * g + m02 * b) +
            gField[p00] * w00 +
            gField[p01] * w01 +
            gField[p10] * w10 +
            gField[p11] * w11,
      );
      data[i + 1] = _u8(
        k * (m10 * r + m11 * g + m12 * b) +
            gField[p00 + 1] * w00 +
            gField[p01 + 1] * w01 +
            gField[p10 + 1] * w10 +
            gField[p11 + 1] * w11,
      );
      data[i + 2] = _u8(
        k * (m20 * r + m21 * g + m22 * b) +
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
