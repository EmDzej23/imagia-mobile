import 'dart:math' as math;
import 'dart:typed_data';

import 'analyze.dart';
import 'looks.dart';
import 'repeat_spacing.dart';
import 'shared.dart';
import 'types.dart';

/// FINE PLACEMENT — the last placement pass of every rectangular layout. Dart port of
/// `foto-mozaik/lib/mosaic/fine-placement.ts` — keep the two identical
/// (test/fine_placement_test.dart).
///
/// `optimal_placement.dart` already moves photos to where they fit best, judged by the
/// matcher's 5×5 descriptors and each cell's 12 best photos. This pass judges by PIXELS —
/// every used photo, cropped as it is drawn, against the picture under the cell on a grid of
/// up to 8×8 — and exchanges the photos of two cells whenever that lowers the total.
///
/// Only exchanges, so every photo keeps its count (coverage and repeat caps hold). Never
/// makes worse: close repeats, portrait / landscape / square-only cells. Deterministic: a
/// fixed seed and no time limit, so every device makes the same mosaic.
const List<int> _grids = [8, 6, 5, 4];

/// Cells × photos × samples the cost table may take; past it the grid gets coarser.
const int _maxWork = 30000000;

/// Cells × photos ceiling (48 MB of costs). Past it the pass is skipped.
const int _maxTable = 12000000;
const double _lightWeight = 1.5;
const int _maxPasses = 2;

/// Above this many cells each cell tries a run of this many partners, from a seeded start.
const int _maxPartners = 1000;

class FinePlacementResult {
  const FinePlacementResult(this.swaps, this.before, this.after, this.grid);
  final int swaps;
  final double before;
  final double after;
  final int grid;
}

const _none = FinePlacementResult(0, 0, 0, 0);

/// The visible part of a photo, as drawn in a cell of this aspect: grid×grid Lab (light
/// weighted).
void _samplePhoto(
  TileDescriptor t,
  double ar,
  int grid,
  bool flip,
  bool portraitTop,
  MosaicSettings settings,
  Float32List out,
  int at,
) {
  const F = fineThumbSize;
  final fine = t.fine!;
  final look = hasLook(settings.look) ? settings.look : null;
  final r = resolveTileSourceRect(
    t.width,
    t.height,
    ar,
    portraitTop,
    cropForTile(settings.tileCrops, t.id, ar),
  );
  final x0 = (r.sx / t.width) * F, y0 = (r.sy / t.height) * F;
  final bw = ((r.sw / t.width) * F) / grid;
  final bh = ((r.sh / t.height) * F) / grid;
  final rgb = RgbColor(0, 0, 0);
  for (var gy = 0; gy < grid; gy++) {
    final ya = y0 + gy * bh, yb = ya + bh;
    final iy0 = math.max(0, math.min(F - 1, ya.floor()));
    final iy1 = math.max(iy0 + 1, math.min(F, yb.ceil()));
    for (var gx = 0; gx < grid; gx++) {
      final xa = x0 + gx * bw, xb = xa + bw;
      final ix0 = math.max(0, math.min(F - 1, xa.floor()));
      final ix1 = math.max(ix0 + 1, math.min(F, xb.ceil()));
      var R = 0.0, G = 0.0, B = 0.0, W = 0.0;
      for (var y = iy0; y < iy1; y++) {
        final wy = math.max(1e-6, math.min(y + 1.0, yb) - math.max(y * 1.0, ya));
        for (var x = ix0; x < ix1; x++) {
          final w =
              wy * math.max(1e-6, math.min(x + 1.0, xb) - math.max(x * 1.0, xa));
          final i = (y * F + x) * 3;
          R += w * fine[i];
          G += w * fine[i + 1];
          B += w * fine[i + 2];
          W += w;
        }
      }
      rgb
        ..r = R / W
        ..g = G / W
        ..b = B / W;
      var lab = rgbToLab(rgb);
      if (look != null) lab = lookLab(look, lab);
      final o = at + (gy * grid + (flip ? grid - 1 - gx : gx)) * 3;
      out[o] = lab.L * _lightWeight;
      out[o + 1] = lab.a;
      out[o + 2] = lab.b;
    }
  }
}

FinePlacementResult refineFinePlacement(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  List<double> saliency,
  List<Set<int>> adjacency,
  int spacingRadius,
  ImageAnalyzer analyzer,
) {
  final n = placements.length;
  if (n < 2 || placements.any((p) => p.quad != null)) return _none;

  // Photos in use, as drawn (a mirrored copy is its own entry, the same photo for repeats).
  final descriptor = <String, TileDescriptor>{};
  for (final t in tiles) {
    descriptor.putIfAbsent(getBaseTileId(t.id), () => t);
  }
  final ids = <String>[];
  final at = <String, int>{};
  for (final p in placements) {
    if (at.containsKey(p.tileId)) continue;
    at[p.tileId] = ids.length;
    ids.add(p.tileId);
  }
  final T = ids.length;
  if (T < 2 || n * T > _maxTable) return _none;
  final used = <TileDescriptor>[];
  for (final id in ids) {
    final t = descriptor[getBaseTileId(id)];
    if (t == null || t.fine == null) return _none; // analysed before thumbnails existed
    used.add(t);
  }
  final photoNum = <String, int>{};
  final photo = Int32List(T);
  for (var t = 0; t < T; t++) {
    photo[t] = photoNum.putIfAbsent(
      getBaseTileId(ids[t]),
      () => photoNum.length,
    );
  }
  final grid = _grids.firstWhere(
    (g) => n * T * g * g * 3 <= _maxWork,
    orElse: () => _grids.last,
  );
  final D = grid * grid * 3;
  final portraitTop = settings.mosaicMode == 'square';

  // Cells by shape: a photo's crop depends only on the cell's aspect.
  final groups = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final k = jsRound((placements[i].width / placements[i].height) * 100)
        .toInt();
    (groups[k] ??= []).add(i);
  }
  // cost[t * n + i]: photo t in cell i. By photo, so the search reads it in order.
  final cost = Float32List(n * T), photoS = Float32List(T * D);
  groups.forEach((k, cells) {
    for (var t = 0; t < T; t++) {
      _samplePhoto(
        used[t],
        k / 100,
        grid,
        isTileFlipped(ids[t]),
        portraitTop,
        settings,
        photoS,
        t * D,
      );
    }
    for (final i in cells) {
      final p = placements[i];
      final c = analyzer.sampleFine(p.x, p.y, p.width, p.height, grid);
      for (var j = 0; j < D; j += 3) {
        c[j] = c[j] * _lightWeight;
      }
      for (var t = 0; t < T; t++) {
        var s = 0.0;
        for (var j = 0, o = t * D; j < D; j++, o++) {
          final e = c[j] - photoS[o];
          s += e * e;
        }
        cost[t * n + i] = s / (grid * grid);
      }
    }
  });

  // Bigger and more important cells count for more.
  var areaSum = 0.0;
  for (final p in placements) {
    areaSum += p.width * p.height;
  }
  final meanArea = areaSum / n;
  final weight = Float64List(n);
  for (var i = 0; i < n; i++) {
    weight[i] =
        ((placements[i].width * placements[i].height) / meanArea) *
        (1 + (i < saliency.length ? saliency[i] : 0.0));
  }

  // The orientation rules of the matcher (getTopKCandidates). Large square cells take square
  // photos only, told by size (the web's `strictSquare`, which the app's cells don't have).
  int shapeOf(double ar) => ar < 0.85 ? -1 : (ar > 1.18 ? 1 : 0);
  final shape = Int8List(T), cellShape = Int8List(n);
  final squareOnly = Uint8List(n);
  var minArea = double.infinity;
  for (final p in placements) {
    minArea = math.min(minArea, p.width * p.height);
  }
  for (var t = 0; t < T; t++) {
    shape[t] = shapeOf(used[t].aspectRatio);
  }
  for (var i = 0; i < n; i++) {
    final p = placements[i];
    cellShape[i] = shapeOf(p.width / p.height);
    squareOnly[i] =
        cellShape[i] == 0 &&
            (settings.mosaicMode == 'blocks' ||
                p.width * p.height > 1.5 * minArea)
        ? 1
        : 0;
  }
  bool mismatch(int i, int t) => cellShape[i] != 0
      ? shape[t] != cellShape[i]
      : squareOnly[i] == 1 && shape[t] != 0;

  /// May photo [t] go to cell [i]? Not if the shapes clash — unless its photo already does.
  bool shapeOk(int i, int t, int current) =>
      !mismatch(i, t) || mismatch(i, current);

  final near = buildNeighbourLists(placements, math.max(1, spacingRadius));
  // Touching cells (a big cell's centre can be further away than the radius), counted
  // apart: one kind of repeat must not be traded for the other.
  final touching = [for (final s in adjacency) s.toList(growable: false)];
  final a = Int32List(n);
  for (var i = 0; i < n; i++) {
    a[i] = at[placements[i].tileId]!;
  }

  // Copies of a photo around a cell, kept up to date: [photo * n + cell]. (Counting the
  // neighbours for every candidate swap was most of this pass.)
  final P = photoNum.length;
  final nearCount = Uint8List(P * n), touchCount = Uint8List(P * n);
  for (var i = 0; i < n; i++) {
    final row = photo[a[i]] * n;
    for (final j in near[i]) {
      nearCount[row + j]++;
    }
    for (final j in touching[i]) {
      touchCount[row + j]++;
    }
  }

  /// Cell [i]'s photo changes from [from] to [to]: its neighbours' counts follow.
  void moved(int i, int from, int to) {
    for (final j in near[i]) {
      nearCount[from * n + j]--;
      nearCount[to * n + j]++;
    }
    for (final j in touching[i]) {
      touchCount[from * n + j]--;
      touchCount[to * n + j]++;
    }
  }

  // Which cells are neighbours of the cell being looked at.
  final nearMark = Int32List(n)..fillRange(0, n, -1);
  final touchMark = Int32List(n)..fillRange(0, n, -1);

  var seed = 1;
  double rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x80000000;
  }

  /// Every cell's weighted cost with the photo it has now.
  final now = Float64List(n);
  for (var i = 0; i < n; i++) {
    now[i] = weight[i] * cost[a[i] * n + i];
  }
  double total() {
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += now[i];
    }
    return s;
  }

  final before = total();
  final mine = Float64List(T); // the cell being looked at: its weighted cost per photo
  final order = Int32List(n);
  for (var i = 0; i < n; i++) {
    order[i] = i;
  }
  final all = n <= _maxPartners;
  final tries = all ? n : _maxPartners;
  var swaps = 0;
  for (var pass = 0; pass < _maxPasses; pass++) {
    for (var i = n - 1; i > 0; i--) {
      final j = (rnd() * (i + 1)).floor();
      final v = order[i];
      order[i] = order[j];
      order[j] = v;
    }
    var done = 0;
    for (var o = 0; o < n; o++) {
      final p = order[o];
      final tp = a[p], col = tp * n, ph = photo[tp];
      final wp = weight[p], here = now[p];
      for (var t = 0; t < T; t++) {
        mine[t] = wp * cost[t * n + p];
      }
      for (final j in near[p]) {
        nearMark[j] = p;
      }
      for (final j in touching[p]) {
        touchMark[j] = p;
      }
      final nearMine = nearCount[ph * n + p], touchMine = touchCount[ph * n + p];
      var best = 1e-3;
      var bestQ = -1;
      final start = all ? 0 : (rnd() * n).floor();
      for (var k = 0; k < tries; k++) {
        final q = start + k < n ? start + k : start + k - n;
        final tq = a[q];
        final gain = here + now[q] - weight[q] * cost[col + q] - mine[tq];
        if (gain <= best || photo[tq] == ph) continue;
        if (!shapeOk(p, tq, tp) || !shapeOk(q, tp, tq)) continue;
        // Would the exchange put more copies next to each other? (A neighbour's own copy
        // moves away, so it doesn't count.)
        final other = photo[tq] * n, own = ph * n;
        final n2 = nearMark[q] == p ? 2 : 0, t2 = touchMark[q] == p ? 2 : 0;
        if (nearCount[other + p] + nearCount[own + q] - n2 >
            nearMine + nearCount[other + q]) {
          continue;
        }
        if (touchCount[other + p] + touchCount[own + q] - t2 >
            touchMine + touchCount[other + q]) {
          continue;
        }
        best = gain;
        bestQ = q;
      }
      if (bestQ >= 0) {
        final tq = a[bestQ];
        a[p] = tq;
        a[bestQ] = tp;
        moved(p, ph, photo[tq]);
        moved(bestQ, photo[tq], ph);
        now[p] = mine[a[p]];
        now[bestQ] = weight[bestQ] * cost[col + bestQ];
        done++;
      }
    }
    swaps += done;
    if (done < n * 0.003) break;
  }
  final after = total();
  final name = {for (final p in placements) p.tileId: p.tileName};
  for (var i = 0; i < n; i++) {
    final id = ids[a[i]];
    if (placements[i].tileId == id) continue;
    placements[i].tileId = id;
    placements[i].tileName = name[id]!;
  }
  return FinePlacementResult(swaps, before, after, grid);
}
