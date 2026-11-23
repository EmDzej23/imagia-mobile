import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Tile recolouring — the Dart port of `tileRecolorLinear` in
/// foto-mozaik/lib/mosaic/shared.ts (and render-service/src/lib/recolor.ts). Keep all
/// three identical: the on-device preview applies it, and the server compositor applies
/// it to the high-res export, so the two have to agree.
///
/// Per channel, `out = in·mul + add` moves a tile's average colour toward its cell's
/// colour in the base photo by `strength` (0 = untouched, 1 = the averages match).
/// Darkening scales the channel; brightening shifts it up by the difference, so the tile
/// keeps its full contrast instead of turning milky. `mul ≤ 1` and `add ≥ 0` always. On device it's
/// applied as a colour matrix on the tile's own draw ([recolorColorFilter]).
class TileRecolor {
  const TileRecolor(this.mul, this.add);

  /// Per-channel gain (r, g, b), each 0..1.
  final List<double> mul;

  /// Per-channel offset (r, g, b), each 0..255.
  final List<double> add;
}

/// Misfit boost — keep identical to RECOLOR_MISFIT_* / effectiveRecolorStrength in
/// foto-mozaik/lib/mosaic/shared.ts: a tile whose colour is clearly off its cell gets a
/// stronger recolour (up to 0.95), tiles that already fit keep the normal strength.
const double _misfitLo = 25, _misfitHi = 60, _misfitCeil = 0.95;

double effectiveRecolorStrength(
  List<double> region,
  List<double> tile,
  double strength,
) {
  final s = strength.clamp(0.0, 1.0);
  if (!(s > 0) || s >= _misfitCeil) return s;
  final dr = region[0] - tile[0],
      dg = region[1] - tile[1],
      db = region[2] - tile[2];
  final gap = math.sqrt(0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db);
  final t = ((gap - _misfitLo) / (_misfitHi - _misfitLo)).clamp(0.0, 1.0);
  // Fades in with the slider (full from 0.5) — keep identical to the web.
  final ramp = math.min(1.0, s / 0.5);
  return s + (_misfitCeil - s) * t * t * (3 - 2 * t) * ramp;
}

TileRecolor? tileRecolorLinear(
  List<double> region,
  List<double> tile,
  double strength,
) {
  final s = effectiveRecolorStrength(region, tile, strength);
  if (!(s > 0)) return null;
  // The tile is toned (desaturated) first, so the average to move is the toned one.
  final toning = tileToning(strength);
  final m = toneMatrix(toning.saturation);
  final src = [
    for (var c = 0; c < 3; c++)
      (m[c * 3] * tile[0] + m[c * 3 + 1] * tile[1] + m[c * 3 + 2] * tile[2])
          .clamp(0.0, 255.0),
  ];
  final k = toning.contrast;
  final mul = <double>[1, 1, 1];
  final add = <double>[0, 0, 0];
  var changed = k < 1;
  // Only [toneChroma] of the move's colour, all of its brightness (web parity).
  final mv = [for (var c = 0; c < 3; c++) s * (region[c].clamp(0.0, 255.0) - src[c])];
  if (toneChroma < 1) chromaScale(mv, toneChroma);
  for (var c = 0; c < 3; c++) {
    final from = src[c];
    final to = from + mv[c];
    if (k >= 1 && (to - from).abs() < 0.5) continue;
    changed = true;
    final md = from > 0 ? to / from : double.infinity;
    if (md <= k) {
      mul[c] = md;
    } else {
      mul[c] = k;
      add[c] = to - k * from;
    }
  }
  return changed ? TileRecolor(mul, add) : null;
}

/// Tile toning — keep identical to TILE_TONE_* / tileToning in shared.ts: the tile keeps
/// 60% of its own colour and 82% of its contrast at full effect (slider ≥ 0.5).
// Contrast 1 since 2026-11-10 (tiles keep their own blacks and detail; web parity).
const double _toneSaturation = 0.6, _toneContrast = 1;

/// How much of the recolour's COLOUR shift a tile gets — its brightness shift stays
/// whole (recolour version 3, 2026-11-11; TILE_TONE_CHROMA in shared.ts). With the whole
/// shift a strong target colour clipped a tile's other channels to one flat colour.
const double toneChroma = 0.5;

/// Scale the colour part of an RGB move by [chroma] in place, keeping its brightness
/// (Rec.601 luma) — identical to chromaScale in shared.ts / render-service recolor.ts.
void chromaScale(List<double> mv, double chroma, [int o = 0]) {
  final y = 0.299 * mv[o] + 0.587 * mv[o + 1] + 0.114 * mv[o + 2];
  mv[o] = y + chroma * (mv[o] - y);
  mv[o + 1] = y + chroma * (mv[o + 1] - y);
  mv[o + 2] = y + chroma * (mv[o + 2] - y);
}

({double saturation, double contrast}) tileToning(double strength) {
  final f = (strength / 0.5).clamp(0.0, 1.0);
  return (
    saturation: 1 - (1 - _toneSaturation) * f,
    contrast: 1 - (1 - _toneContrast) * f,
  );
}

/// Luminance-preserving saturation matrix, row-major 3×3 — identical to
/// saturationMatrix in shared.ts.
List<double> toneMatrix(double s) {
  const r = 0.213, g = 0.715, b = 0.072;
  return [
    r + (1 - r) * s, g - g * s, b - b * s, //
    r - r * s, g + (1 - g) * s, b - b * s, //
    r - r * s, g - g * s, b + (1 - b) * s, //
  ];
}

/// The recolour as a colour matrix, applied by the tile's own draw call
/// (`Paint.colorFilter`). One draw per cell — the earlier multiply + plus rectangles
/// per cell were very slow on iOS (Impeller handles those blend modes expensively, and
/// the preview repaints every cell on each animation frame). Flutter's matrix offsets
/// are in 0..255, the same units as [TileRecolor.add].
/// Toning is folded in: each output channel = mul·(tone-matrix row · rgb) + add.
ColorFilter recolorColorFilter(TileRecolor? lin, double tone) {
  final m = toneMatrix(tone);
  final mul = lin?.mul ?? const [1.0, 1.0, 1.0];
  final add = lin?.add ?? const [0.0, 0.0, 0.0];
  return ColorFilter.matrix(<double>[
    for (var c = 0; c < 3; c++) ...[
      mul[c] * m[c * 3],
      mul[c] * m[c * 3 + 1],
      mul[c] * m[c * 3 + 2],
      0,
      add[c],
    ],
    0, 0, 0, 1, 0, //
  ]);
}

/// Per-plan cache of each cell's recolour filter, so a repaint (every frame of the
/// reveal, every pan of the zoom) doesn't recompute means and matrices. Reset when the
/// strength or the crops change. A cell whose tile grid isn't ready yet stays unset and
/// is computed on a later paint.
class _CellFilters {
  _CellFilters(this.strength, this.crops, int n)
    : filters = List<Object?>.filled(n, _unset);
  final double strength;
  final Object? crops;
  final List<Object?> filters;
}

const Object _unset = Object();
final Expando<_CellFilters> _cellFilters = Expando('tileRecolorCells');

/// The recolour filter for placement [index] of [plan] (null = draw the tile as is).
ColorFilter? cellRecolorFilter({
  required Object plan,
  required int index,
  required int count,
  required Object? crops,
  required ui.Image img,
  required Rect src,
  required List<double>? region,
  required double strength,
}) {
  if (!(strength > 0) || region == null || index < 0 || index >= count)
    return null;
  var cache = _cellFilters[plan];
  if (cache == null ||
      cache.strength != strength ||
      !identical(cache.crops, crops) ||
      cache.filters.length != count) {
    cache = _CellFilters(strength, crops, count);
    _cellFilters[plan] = cache;
  }
  final hit = cache.filters[index];
  if (!identical(hit, _unset)) return hit as ColorFilter?;
  final mean = tileRegionMean(img, src);
  if (mean == null) return null; // grid not ready — try again next paint
  final lin = tileRecolorLinear(region, mean, strength);
  final tone = tileToning(strength).saturation;
  final f = lin == null && tone >= 1 ? null : recolorColorFilter(lin, tone);
  cache.filters[index] = f;
  return f;
}

// ── Tile colour grids ────────────────────────────────────────────────────────────
//
// The recolour needs the average colour of the part of each tile that's actually shown
// (the server averages the cropped tile). Reading pixels from a ui.Image is async, so
// every tile image gets a 16×16 RGB grid once, in the background, and the painters
// average the grid cells under the source rect synchronously. A painter built with
// `repaint: tileColorGridsVersion` repaints when new grids land.

const int _grid = 16;
final Expando<Uint8List> _grids = Expando('tileColorGrid');
final Expando<bool> _pending = Expando('tileColorGridPending');

/// Bumped whenever new grids are ready — pass as a painter's `repaint` listenable.
final ValueNotifier<int> tileColorGridsVersion = ValueNotifier(0);

int _inFlight = 0;
final List<ui.Image> _queue = [];

/// Average RGB of [src] (in image pixels) of [img], or null while its grid is still
/// being computed (that request is started here).
List<double>? tileRegionMean(ui.Image img, Rect src) {
  final g = _grids[img];
  if (g == null) {
    _request(img);
    return null;
  }
  final w = img.width.toDouble(), h = img.height.toDouble();
  if (w <= 0 || h <= 0) return null;
  var x0 = (src.left / w * _grid).floor(), x1 = (src.right / w * _grid).ceil();
  var y0 = (src.top / h * _grid).floor(), y1 = (src.bottom / h * _grid).ceil();
  x0 = x0.clamp(0, _grid - 1);
  y0 = y0.clamp(0, _grid - 1);
  x1 = x1.clamp(x0 + 1, _grid);
  y1 = y1.clamp(y0 + 1, _grid);
  var r = 0.0, gg = 0.0, b = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * _grid + x) * 4;
      r += g[i];
      gg += g[i + 1];
      b += g[i + 2];
      n++;
    }
  }
  return n == 0 ? null : [r / n, gg / n, b / n];
}

/// [img]'s colour grid, if it has one (to keep it in the analysis cache).
Uint8List? tileColorGridOf(ui.Image img) => _grids[img];

/// Give [img] a colour grid kept from an earlier analysis of the same photo.
void setTileColorGrid(ui.Image img, Uint8List grid) {
  if (grid.length == _grid * _grid * 4) _grids[img] = grid;
}

/// Give [img] its colour grid from pixels already read off the same photo ([rgba],
/// [w]×[h], any size): a box average into the 16×16 grid, no GPU read-back.
void primeTileColorGrid(ui.Image img, Uint8List rgba, int w, int h) {
  if (w < 1 || h < 1 || rgba.length < w * h * 4) return;
  final g = Uint8List(_grid * _grid * 4);
  for (var gy = 0; gy < _grid; gy++) {
    final y0 = gy * h ~/ _grid, y1 = math.max(y0 + 1, (gy + 1) * h ~/ _grid);
    for (var gx = 0; gx < _grid; gx++) {
      final x0 = gx * w ~/ _grid, x1 = math.max(x0 + 1, (gx + 1) * w ~/ _grid);
      var r = 0, gg = 0, b = 0, n = 0;
      for (var y = y0; y < y1 && y < h; y++) {
        var o = (y * w + x0) * 4;
        for (var x = x0; x < x1 && x < w; x++, o += 4) {
          r += rgba[o];
          gg += rgba[o + 1];
          b += rgba[o + 2];
          n++;
        }
      }
      final i = (gy * _grid + gx) * 4;
      if (n > 0) {
        g[i] = (r / n).round();
        g[i + 1] = (gg / n).round();
        g[i + 2] = (b / n).round();
      }
      g[i + 3] = 255;
    }
  }
  _grids[img] = g;
}

/// Compute the colour grids of [imgs] that are missing (for renderers that need them
/// all up front, like the video). A few at a time.
Future<void> ensureTileColorGrids(Iterable<ui.Image> imgs) async {
  final todo = [
    for (final img in imgs)
      if (_grids[img] == null) img,
  ];
  for (var i = 0; i < todo.length; i += 8) {
    final batch = todo.sublist(i, math.min(todo.length, i + 8));
    final grids = await Future.wait(batch.map(_computeGrid));
    for (var k = 0; k < batch.length; k++) {
      final g = grids[k];
      if (g != null) _grids[batch[k]] = g;
    }
  }
}

void _request(ui.Image img) {
  if (_pending[img] == true) return;
  _pending[img] = true;
  _queue.add(img);
  _pump();
}

void _pump() {
  // A few at a time: each is a tiny GPU readback, but hundreds at once would stall.
  while (_inFlight < 4 && _queue.isNotEmpty) {
    final img = _queue.removeLast();
    _inFlight++;
    _computeGrid(img)
        .then((g) {
          if (g != null) _grids[img] = g;
        })
        .whenComplete(() {
          _inFlight--;
          // One repaint when a batch of grids is done, not one per tile.
          if (_queue.isEmpty && _inFlight == 0) tileColorGridsVersion.value++;
          _pump();
        });
  }
}

Future<Uint8List?> _computeGrid(ui.Image img) async {
  try {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      const Rect.fromLTWH(0, 0, _grid * 1.0, _grid * 1.0),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final pic = rec.endRecording();
    final small = await pic.toImage(_grid, _grid);
    pic.dispose();
    final bd = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    small.dispose();
    return bd?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
