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

OptimalPlacementResult optimizePlacementAssignment(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  List<double> saliency,
  int radius,
) {
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
  final candT = Int32List(n * K)..fillRange(0, n * K, -1);
  final candC = Float64List(n * K);
  final curCost = Float64List(n);
  final pool = [for (final b in ids) firstOf[b]!];
  for (var i = 0; i < n; i++) {
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
  void move(int cell, int from, int to) {
    curCost[cell] = costOf(cell, to);
    assign[cell] = to;
    for (final j in nb[cell]) {
      for (var k = 0; k < K; k++) {
        final t = candT[j * K + k];
        if (t == from) {
          near[j * K + k]--;
        } else if (t == to) {
          near[j * K + k]++;
        }
      }
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
  // Cheapest legal move per photo pair: key s*T+t → slot, open addressing.
  var cap = 1;
  while (cap < n * K * 2) {
    cap <<= 1;
  }
  final hKey = Int64List(cap), hSlot = Int32List(cap), hGen = Int32List(cap);
  var gen = 0;
  int hash(int key) => ((key * 0x9e3779b1) & 0x7fffffff) & (cap - 1);
  int slotGet(int key) {
    for (var h = hash(key); ; h = (h + 1) & (cap - 1)) {
      if (hGen[h] != gen) return -1;
      if (hKey[h] == key) return hSlot[h];
    }
  }

  void slotPut(int key, int slot) {
    var h = hash(key);
    while (hGen[h] == gen) {
      h = (h + 1) & (cap - 1);
    }
    hGen[h] = gen;
    hKey[h] = key;
    hSlot[h] = slot;
  }

  final eS = Int32List(n * K), eT = Int32List(n * K), eCell = Int32List(n * K);
  final eW = Float64List(n * K);
  var E = 0;
  double edgeW(int s, int t) {
    final e = slotGet(s * T + t);
    return e < 0 ? double.infinity : eW[e];
  }

  final dist = Float64List(T), pred = Int32List(T), relax = Int32List(T);
  final inQ = Uint8List(T), mark = Int32List(T);
  final outStart = Int32List(T + 1);
  final outEdge = Int32List(n * K);
  var skipSwap = false;

  while (cycles < _maxCycles) {
    gen++;
    E = 0;
    for (var i = 0; i < n; i++) {
      final s = assign[i], base = curCost[i];
      for (var k = 0; k < K; k++) {
        final t = candT[i * K + k];
        if (t < 0 || t == s || near[i * K + k] != 0) continue;
        final d = candC[i * K + k] - base;
        final key = s * T + t;
        final e = slotGet(key);
        if (e < 0) {
          slotPut(key, E);
          eS[E] = s;
          eT[E] = t;
          eW[E] = d;
          eCell[E] = i;
          E++;
        } else if (d < eW[e]) {
          eW[e] = d;
          eCell[e] = i;
        }
      }
    }
    if (!skipSwap) {
      final cand = <List<num>>[];
      for (var e = 0; e < E; e++) {
        final a = eS[e], b = eT[e];
        if (a > b) continue;
        final g = eW[e] + edgeW(b, a);
        if (g < -1e-9) cand.add([g, a, b]);
      }
      if (cand.isNotEmpty) {
        cand.sort((p, q) {
          final c0 = p[0].compareTo(q[0]);
          if (c0 != 0) return c0;
          final c1 = p[1].compareTo(q[1]);
          return c1 != 0 ? c1 : p[2].compareTo(q[2]);
        });
        final usedPhoto = Uint8List(T);
        var applied = 0;
        for (final c in cand) {
          final a = c[1] as int, b = c[2] as int;
          if (usedPhoto[a] != 0 || usedPhoto[b] != 0) continue;
          final ca = eCell[slotGet(a * T + b)], cb = eCell[slotGet(b * T + a)];
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

    // Queue-based Bellman-Ford over the sparse edges, in target order.
    outStart.fillRange(0, T + 1, 0);
    for (var e = 0; e < E; e++) {
      outStart[eS[e] + 1]++;
    }
    for (var t = 0; t < T; t++) {
      outStart[t + 1] += outStart[t];
    }
    final fill = Int32List.fromList(outStart.sublist(0, T));
    for (var e = 0; e < E; e++) {
      outEdge[fill[eS[e]]++] = e;
    }
    for (var s = 0; s < T; s++) {
      final a = outStart[s], b = outStart[s + 1];
      if (b - a > 1) {
        final seg = outEdge.sublist(a, b)..sort((x, y) => eT[x] - eT[y]);
        outEdge.setRange(a, b, seg);
      }
    }
    dist.fillRange(0, T, 0);
    pred.fillRange(0, T, -1);
    relax.fillRange(0, T, 0);
    inQ.fillRange(0, T, 1);
    final queue = <int>[for (var t = 0; t < T; t++) t];
    var hit = -1, sinceCheck = 0;
    for (var head = 0; head < queue.length && hit < 0; head++) {
      final s = queue[head];
      inQ[s] = 0;
      for (var o = outStart[s]; o < outStart[s + 1]; o++) {
        final e = outEdge[o], t = eT[e];
        final nd = dist[s] + eW[e];
        if (nd < dist[t] - 1e-9) {
          dist[t] = nd;
          pred[t] = s;
          if (++relax[t] >= T) {
            hit = t;
            break;
          }
          if (inQ[t] == 0) {
            inQ[t] = 1;
            queue.add(t);
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
      final e = slotGet(from * T + to);
      final cell = e < 0 ? -1 : eCell[e];
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
