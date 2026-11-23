import 'dart:math' as math;
import 'dart:typed_data';

import 'matching.dart';
import 'repeat_spacing.dart';
import 'shared.dart';
import 'types.dart';

/// OPTIMAL PLACEMENT — port of foto-mozaik/lib/mosaic/optimal-placement.ts (keep
/// identical, so the phone and the web build the same mosaic). Redistributes the cells
/// so every photo sits where it fits best over the whole mosaic, keeping each photo's
/// count and the repeat-spacing rule: negative-cycle cancelling between photos, with a
/// fast path that applies every improving direct swap on disjoint photos per round.
const int _candidates = 12;
const int _maxCycles = 4000;

class OptimalPlacementResult {
  OptimalPlacementResult(this.before, this.after, this.cycles);
  final double before;
  final double after;
  final int cycles;
}

/// The first tile of each photo (base id) in [tiles], in order — the optimiser's pool
/// when every photo is in use.
List<TileDescriptor> _photoPool(List<TileDescriptor> tiles) {
  final firstOf = <String, TileDescriptor>{};
  for (final t in tiles) {
    firstOf.putIfAbsent(getBaseTileId(t.id), () => t);
  }
  return firstOf.values.toList();
}

/// Each cell's best candidate photos and their costs over the whole photo pool. They
/// depend on the cells and the photos only — not on which photo a cell has — so they
/// can be worked out early, on another isolate, while the passes before the optimiser
/// run; [optimizePlacementAssignment] uses them when every photo is in use (the
/// pool it would build is then this one).
class PlacementCandidates {
  PlacementCandidates(this.poolIds, this.k, this.candT, this.candC);

  /// Base ids of the pool, in order; [candT] indexes into it (-1 = none).
  final List<String> poolIds;
  final int k;
  final Int32List candT;
  final Float64List candC;
}

PlacementCandidates computePlacementCandidates(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  List<double> saliency,
) {
  final pool = _photoPool(tiles);
  final ids = [for (final t in pool) getBaseTileId(t.id)];
  final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final n = placements.length;
  final K = math.min(_candidates, pool.length);
  final candT = Int32List(n * K)..fillRange(0, n * K, -1);
  final candC = Float64List(n * K);
  for (var i = 0; i < n; i++) {
    final sal = i < saliency.length ? saliency[i] : 0.0;
    final top = getTopKCandidates(placements[i], pool, settings, sal, K);
    for (var k = 0; k < top.length && k < K; k++) {
      candT[i * K + k] = index[getBaseTileId(top[k].tile.id)]!;
      candC[i * K + k] = top[k].baseCost;
    }
  }
  return PlacementCandidates(ids, K, candT, candC);
}

OptimalPlacementResult optimizePlacementAssignment(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  List<double> saliency,
  int radius, {

  /// From [computePlacementCandidates] for these cells and [tiles]; used when it
  /// covers exactly the photos in use, else ignored.
  PlacementCandidates? precomputed,
}) {
  final n = placements.length;
  if (n < 2 || tiles.length < 2 || placements.any((p) => p.quad != null)) {
    return OptimalPlacementResult(0, 0, 0);
  }
  // Photo nodes: only photos IN USE, in pool order. Everything is sparse (cells ×
  // candidates), never photos × photos — a 6,000-photo library costs no more than 60.
  final firstOf = <String, TileDescriptor>{};
  for (final t in tiles) {
    firstOf.putIfAbsent(getBaseTileId(t.id), () => t);
  }
  final usedIds = {for (final p in placements) getBaseTileId(p.tileId)};
  final ids = [
    for (final b in firstOf.keys)
      if (usedIds.contains(b)) b,
  ];
  final T = ids.length;
  if (T < 2 || usedIds.length != T) return OptimalPlacementResult(0, 0, 0);
  final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final assign = Int32List(n);
  for (var i = 0; i < n; i++) {
    assign[i] = index[getBaseTileId(placements[i].tileId)]!;
  }

  final K = math.min(_candidates, T);
  final pool = [for (final b in ids) firstOf[b]!];
  final pre =
      precomputed != null &&
          precomputed.k == K &&
          precomputed.candT.length == n * K &&
          _sameIds(precomputed.poolIds, ids)
      ? precomputed
      : null;
  final candT = pre?.candT ?? (Int32List(n * K)..fillRange(0, n * K, -1));
  final candC = pre?.candC ?? Float64List(n * K);
  final curCost = Float64List(n);
  // With the candidates already known, only the current photo's cost is missing — the
  // same value the loop below takes from the list, or scores on its own.
  for (var i = 0; pre != null && i < n; i++) {
    var found = false;
    for (var k = 0; k < K; k++) {
      if (candT[i * K + k] == assign[i]) {
        curCost[i] = candC[i * K + k];
        found = true;
        break;
      }
    }
    if (!found) {
      final sal = i < saliency.length ? saliency[i] : 0.0;
      final one = getTopKCandidates(
        placements[i],
        [pool[assign[i]]],
        settings,
        sal,
        1,
      );
      curCost[i] = one.isNotEmpty ? one.first.baseCost : 0;
    }
  }
  for (var i = 0; pre == null && i < n; i++) {
    final p = placements[i];
    final sal = i < saliency.length ? saliency[i] : 0.0;
    final top = getTopKCandidates(p, pool, settings, sal, K);
    RegionCandidate? cur;
    for (final c in top) {
      if (getBaseTileId(c.tile.id) == ids[assign[i]]) {
        cur = c;
        break;
      }
    }
    if (cur == null) {
      final one = getTopKCandidates(p, [pool[assign[i]]], settings, sal, 1);
      if (one.isNotEmpty) cur = one.first;
    }
    curCost[i] = cur?.baseCost ?? 0;
    for (var k = 0; k < top.length && k < K; k++) {
      candT[i * K + k] = index[getBaseTileId(top[k].tile.id)]!;
      candC[i * K + k] = top[k].baseCost;
    }
  }
  double costOf(int i, int t) {
    for (var k = 0; k < K; k++) {
      if (candT[i * K + k] == t) return candC[i * K + k];
    }
    return double.infinity;
  }

  final nb = radius > 0
      ? buildNeighbourLists(placements, radius)
      : List.generate(n, (_) => <int>[]);
  // near[i*K+k] = copies of cell i's k-th candidate photo around cell i.
  final near = Uint16List(n * K);
  for (var i = 0; i < n; i++) {
    for (final j in nb[i]) {
      final a = assign[j];
      for (var k = 0; k < K; k++) {
        if (candT[i * K + k] == a) near[i * K + k]++;
      }
    }
  }
  // The cells on each photo — a photo's out-edges come from these cells only.
  final cellsOf = List<List<int>>.generate(T, (_) => <int>[]);
  for (var i = 0; i < n; i++) {
    cellsOf[assign[i]].add(i);
  }
  // A photo whose cells changed (photo, cost, or a neighbour's photo) — its edges are
  // rebuilt at the start of the next round; every other photo keeps its edges.
  final dirty = Uint8List(T)..fillRange(0, T, 1);
  final dirtyList = <int>[for (var t = 0; t < T; t++) t];
  void markDirty(int s) {
    if (dirty[s] == 0) {
      dirty[s] = 1;
      dirtyList.add(s);
    }
  }

  void move(int cell, int from, int to) {
    curCost[cell] = costOf(cell, to);
    assign[cell] = to;
    cellsOf[from].remove(cell);
    cellsOf[to].add(cell);
    markDirty(from);
    markDirty(to);
    for (final j in nb[cell]) {
      var hit = false;
      for (var k = 0; k < K; k++) {
        final t = candT[j * K + k];
        if (t == from) {
          near[j * K + k]--;
          hit = true;
        } else if (t == to) {
          near[j * K + k]++;
          hit = true;
        }
      }
      if (hit) markDirty(assign[j]);
    }
  }

  bool spacingOk(int c) {
    final a = assign[c];
    for (final j in nb[c]) {
      if (assign[j] == a) return false;
    }
    return true;
  }

  var before = 0.0;
  for (var i = 0; i < n; i++) {
    before += curCost[i];
  }
  var cycles = 0, rejected = 0;

  // Cheapest legal move per photo pair (s → t): over the cells on s, the lowest
  // candidate cost minus the cell's current cost, the lowest cell index on a tie.
  // Stored per source photo, sorted by target, so the Bellman-Ford pass walks them in
  // target order with no sorting, and a pair is found by binary search.
  final outT = List<Int32List>.filled(T, Int32List(0));
  final outW = List<Float64List>.filled(T, Float64List(0));
  final outCell = List<Int32List>.filled(T, Int32List(0));
  final bestD = Float64List(T), bestCell = Int32List(T), seenAt = Int32List(T);
  var stamp = 0;
  final touched = Int32List(T);

  void rebuild(int s) {
    stamp++;
    var m = 0;
    for (final i in cellsOf[s]) {
      final base = curCost[i];
      for (var k = 0; k < K; k++) {
        final t = candT[i * K + k];
        if (t < 0 || t == s || near[i * K + k] != 0) continue;
        final d = candC[i * K + k] - base;
        if (seenAt[t] != stamp) {
          seenAt[t] = stamp;
          bestD[t] = d;
          bestCell[t] = i;
          touched[m++] = t;
        } else if (d < bestD[t] || (d == bestD[t] && i < bestCell[t])) {
          bestD[t] = d;
          bestCell[t] = i;
        }
      }
    }
    // Ascending targets (insertion sort: a photo has a few dozen at most).
    for (var x = 1; x < m; x++) {
      final v = touched[x];
      var y = x - 1;
      while (y >= 0 && touched[y] > v) {
        touched[y + 1] = touched[y];
        y--;
      }
      touched[y + 1] = v;
    }
    final ot = Int32List(m), ow = Float64List(m), oc = Int32List(m);
    for (var x = 0; x < m; x++) {
      final t = touched[x];
      ot[x] = t;
      ow[x] = bestD[t];
      oc[x] = bestCell[t];
    }
    outT[s] = ot;
    outW[s] = ow;
    outCell[s] = oc;
  }

  // Index of edge s → t in s's list, or -1.
  int find(int s, int t) {
    final ot = outT[s];
    var lo = 0, hi = ot.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = ot[mid];
      if (v == t) return mid;
      if (v < t) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  final dist = Float64List(T), pred = Int32List(T), relax = Int32List(T);
  final inQ = Uint8List(T), mark = Int32List(T);
  final queue = Int32List(T);
  var skipSwap = false;
  // Swap candidates: gain, then the two photos (a < b).
  var candCap = 256;
  var cG = Float64List(candCap),
      cA = Int32List(candCap),
      cB = Int32List(candCap);
  var cOrder = Int32List(candCap);

  while (cycles < _maxCycles) {
    for (final s in dirtyList) {
      dirty[s] = 0;
      rebuild(s);
    }
    dirtyList.clear();
    if (!skipSwap) {
      var nc = 0;
      for (var a = 0; a < T; a++) {
        final ot = outT[a], ow = outW[a];
        for (var x = 0; x < ot.length; x++) {
          final b = ot[x];
          if (a > b) continue;
          final r = find(b, a);
          if (r < 0) continue;
          final g = ow[x] + outW[b][r];
          if (g < -1e-9) {
            if (nc == candCap) {
              candCap *= 2;
              cG = Float64List(candCap)..setRange(0, nc, cG);
              cA = Int32List(candCap)..setRange(0, nc, cA);
              cB = Int32List(candCap)..setRange(0, nc, cB);
              cOrder = Int32List(candCap);
            }
            cG[nc] = g;
            cA[nc] = a;
            cB[nc] = b;
            nc++;
          }
        }
      }
      if (nc > 0) {
        final order = Int32List.sublistView(cOrder, 0, nc);
        for (var x = 0; x < nc; x++) {
          order[x] = x;
        }
        // (gain, a, b) — unique per pair, so the order is total.
        order.sort((p, q) {
          final c0 = cG[p].compareTo(cG[q]);
          if (c0 != 0) return c0;
          final c1 = cA[p] - cA[q];
          return c1 != 0 ? c1 : cB[p] - cB[q];
        });
        final usedPhoto = Uint8List(T);
        var applied = 0;
        for (var x = 0; x < nc; x++) {
          final a = cA[order[x]], b = cB[order[x]];
          if (usedPhoto[a] != 0 || usedPhoto[b] != 0) continue;
          final ca = outCell[a][find(a, b)], cb = outCell[b][find(b, a)];
          if (ca == cb) continue;
          usedPhoto[a] = 1;
          usedPhoto[b] = 1;
          final oldA = curCost[ca], oldB = curCost[cb];
          move(ca, a, b);
          move(cb, b, a);
          if (!(spacingOk(ca) && spacingOk(cb))) {
            move(ca, b, a);
            move(cb, a, b);
            curCost[ca] = oldA;
            curCost[cb] = oldB;
            continue;
          }
          applied++;
        }
        if (applied > 0) {
          cycles += applied;
          continue;
        }
        skipSwap = true;
        continue;
      }
    }
    skipSwap = false;

    // Queue-based Bellman-Ford over the sparse edges, in target order. Each photo is in
    // the queue at most once, so a ring of T slots holds it.
    dist.fillRange(0, T, 0);
    pred.fillRange(0, T, -1);
    relax.fillRange(0, T, 0);
    inQ.fillRange(0, T, 1);
    for (var t = 0; t < T; t++) {
      queue[t] = t;
    }
    var head = 0, size = T;
    var hit = -1, sinceCheck = 0;
    while (size > 0 && hit < 0) {
      final s = queue[head];
      head = head + 1 == T ? 0 : head + 1;
      size--;
      inQ[s] = 0;
      final ot = outT[s], ow = outW[s];
      for (var o = 0; o < ot.length; o++) {
        final t = ot[o];
        final nd = dist[s] + ow[o];
        if (nd < dist[t] - 1e-9) {
          dist[t] = nd;
          pred[t] = s;
          if (++relax[t] >= T) {
            hit = t;
            break;
          }
          if (inQ[t] == 0) {
            inQ[t] = 1;
            final tail = head + size;
            queue[tail >= T ? tail - T : tail] = t;
            size++;
          }
          if (++sinceCheck >= T) {
            sinceCheck = 0;
            hit = _predCycleNode(pred, T, mark);
            if (hit >= 0) break;
          }
        }
      }
    }
    if (hit < 0) break;
    var x = hit;
    for (var k = 0; k < T; k++) {
      x = pred[x];
    }
    final cyc = <int>[];
    var v = x;
    do {
      cyc.add(v);
      v = pred[v];
    } while (v != x && cyc.length <= T);
    if (v != x) break;
    final cycle = cyc.reversed.toList();
    final moves = <List<int>>[];
    final seen = <int>{};
    for (var k = 0; k < cycle.length; k++) {
      final to = cycle[k], from = cycle[(k - 1 + cycle.length) % cycle.length];
      final e = find(from, to);
      final cell = e < 0 ? -1 : outCell[from][e];
      if (cell < 0 || seen.contains(cell)) {
        moves.clear();
        break;
      }
      seen.add(cell);
      moves.add([cell, from, to]);
    }
    if (moves.isEmpty) break;
    final oldCost = [for (final m in moves) curCost[m[0]]];
    for (final m in moves) {
      move(m[0], m[1], m[2]);
    }
    if (!moves.every((m) => spacingOk(m[0]))) {
      for (var k = 0; k < moves.length; k++) {
        move(moves[k][0], moves[k][2], moves[k][1]);
        curCost[moves[k][0]] = oldCost[k];
      }
      if (cycle.length == 2) skipSwap = true;
      if (++rejected > 50) break;
      continue;
    }
    cycles++;
  }
  var after = 0.0;
  for (var i = 0; i < n; i++) {
    after += curCost[i];
    if (getBaseTileId(placements[i].tileId) != ids[assign[i]]) {
      final t = firstOf[ids[assign[i]]]!;
      placements[i].tileId = t.id;
      placements[i].tileName = t.name;
      placements[i].score = curCost[i];
    }
  }
  return OptimalPlacementResult(before, after, cycles);
}

bool _sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A node on a cycle of the predecessor graph, or -1. O(T).
int _predCycleNode(Int32List pred, int T, Int32List mark) {
  mark.fillRange(0, T, 0);
  for (var v = 0; v < T; v++) {
    if (mark[v] != 0) continue;
    var u = v;
    while (u >= 0 && mark[u] == 0) {
      mark[u] = v + 1;
      u = pred[u];
    }
    if (u >= 0 && mark[u] == v + 1) return u;
  }
  return -1;
}
