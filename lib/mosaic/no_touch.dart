library;

import 'dart:math' as math;

import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// EXPERIMENT — strict "no two identical photos may touch" gate.
///
/// The existing defence against visible twins is a SOFT cost: a distance-weighted
/// proximity penalty inside the scorer and SA. It is a tendency, not a guarantee — SA
/// can outvote it whenever the colour gain is large enough, it scales with the variety
/// slider, and minimum-detail mode switches it off wholesale. Measured on the web
/// bench, that leaves real gaps: 11-22 touching pairs at SHIPPING settings, 8% with a
/// twelve-photo library, 29% at minimum detail, and 73-89% at variety 0.
///
/// This turns the tendency into a floor: after every other pass has run, no two cells
/// that SHARE AN EDGE hold the same photo — wherever twins are incidental. Where they
/// are instead what the settings asked for, the pass declines to run rather than
/// rebuild the picture. See [_skipAboveTwinRate].
///
/// Three deliberate choices:
///
/// 1. EDGE adjacency, not corner-touch. Counting corners pushes the constraint degree
///    to 8-12 with mixed cell sizes, which a small library cannot satisfy; a diagonal
///    twin also reads far more weakly than a shared border.
/// 2. SWAPS, never reassignment. Exchanging two cells' tiles leaves the multiset of
///    photos in use untouched, so tile coverage cannot be undone and the variety pass's
///    usage counts survive.
/// 3. A SINGLE pass at the end, with SA left exactly as it was. A hard gate inside the
///    SA loop was tried and measured: it reached the same zero this pass reaches alone,
///    while costing real quality.
///
/// Must match foto-mozaik/lib/mosaic/no-touch.ts — the two engines are a bit-exact
/// pair, and a mosaic that differs here differs on the phone.
///
/// TO REMOVE AFTER TESTING: delete this file and its call site (grep `no_touch`).
/// The flag. On in the app.
const bool strictNoTouchingTwins = true;

/// Slack, in base-image pixels, for "these two rectangles touch". Matches the
/// adjacency builder — cells are laid out on a float grid, so exact equality never
/// holds.
const double _touch = 1;

/// A shared border must be longer than this to count. Filters out the corner case where
/// two cells overlap by a rounding error along the perpendicular axis.
const double _minEdgeOverlap = 2;

/// The most colour damage ONE swap may do. Clearing a twin is worth a small compromise,
/// never a wrong tile.
const double _maxSwapDamage = 0.05;

/// Above this share of touching pairs being twins, the pass declines to run at all.
///
/// This is a CLEANUP, not a re-layout. Measured on a 1500-cell mosaic: a realistic
/// library at the shipping variety produces twins in 0.4-0.7% of touching pairs —
/// incidental, and every one gets fixed. With the variety slider at exactly 0 the soft
/// proximity penalty is switched off wholesale and the SAME mosaic comes back with
/// 74-91%: at that point the twins are the arrangement the settings asked for, and
/// forcing them apart rewrote most of the picture (mean error 0.064 -> 0.114, +78%).
///
/// 0.40 sits in the wide empty gap between those two populations.
const double _skipAboveTwinRate = 0.4;

/// Hard ceiling on swaps, as a fraction of cells. The rate check already turns the pass
/// off for the pathological case; this only bounds the tail.
const double _maxSwapFraction = 0.25;

/// Ceiling when twins are pervasive (variety 0, or a library far too small for the
/// cell count). Repairing those needs to touch most of the picture, so a budget tuned
/// for incidental twins stops well short and leaves the defect half-fixed.
const double _maxSwapFractionHeavy = 0.9;

/// Search width per violation.
const int _legalBasesPerFix = 12;
const int _holdersPerBase = 6;
const int _randomCandidatesPerFix = 24;

/// Passes over the violation list. Stops early as soon as a pass makes no progress.
/// Measured: the search saturates by ~24; beyond that it re-scans dead ends.
const int _maxPasses = 24;

/// How hard the shape mismatch counts against a swap. A colour-only cost happily trades
/// a landscape photo into a portrait cell because the average colour still fits, and
/// the render then crops two thirds of the photo away: measured, worst-case crop went
/// from 26% to 63% before this term existed.
const double _aspectWeight = 0.5;

class NoTouchReport {
  const NoTouchReport(this.initial, this.remaining, this.swaps, this.skipped);
  final int initial;
  final int remaining;
  final int swaps;

  /// True when the pass declined to run — see [_skipAboveTwinRate].
  final bool skipped;
}

/// Filter a touch-adjacency map down to pairs that share an actual EDGE.
List<List<int>> buildEdgeAdjacency(
    List<MosaicPlacement> placements, List<Set<int>> adjacency) {
  final n = placements.length;
  final out = List<List<int>>.generate(n, (_) => <int>[], growable: false);
  for (var i = 0; i < n; i++) {
    final a = placements[i];
    final aR = a.x + a.width;
    final aB = a.y + a.height;
    for (final j in adjacency[i]) {
      final b = placements[j];
      final bR = b.x + b.width;
      final bB = b.y + b.height;
      // Vertical border: right edge of one meets left edge of the other, and the cells
      // overlap along y by more than a rounding error.
      final vertical = ((aR - b.x).abs() <= _touch || (bR - a.x).abs() <= _touch) &&
          math.min(aB, bB) - math.max(a.y, b.y) > _minEdgeOverlap;
      final horizontal = ((aB - b.y).abs() <= _touch || (bB - a.y).abs() <= _touch) &&
          math.min(aR, bR) - math.max(a.x, b.x) > _minEdgeOverlap;
      if (vertical || horizontal) out[i].add(j);
    }
  }
  return out;
}

/// Deterministic PRNG. A repair that used a seedless RNG would make the same photo and
/// settings produce a different mosaic on every build.
class _Mulberry {
  _Mulberry(this._a);
  int _a;
  double call() {
    _a = (_a + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _a;
    t = (t ^ (t >>> 15)) * (1 | t) & 0xFFFFFFFF;
    t = (t + ((t ^ (t >>> 7)) * (61 | t) & 0xFFFFFFFF)) & 0xFFFFFFFF ^ t;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }
}

/// Enforce the gate by SWAPPING tiles between cells.
///
/// Best-effort by design: with a library smaller than a cell's neighbour count the
/// constraint is unsatisfiable, and a guarantee that cannot be met must degrade quietly
/// rather than fail.
NoTouchReport enforceNoTouchingTwins(
  List<MosaicPlacement> placements,
  Map<String, TileDescriptor> tileMap,
  List<Set<int>> adjacency,
  List<double>? saliency,
) {
  final n = placements.length;
  if (n < 2) return const NoTouchReport(0, 0, 0, false);

  final edges = buildEdgeAdjacency(placements, adjacency);
  final baseIds = List<String>.generate(
      n, (i) => getBaseTileId(placements[i].tileId),
      growable: false);

  /// Cost of putting [tile] in cell [idx] — colour error, saliency-weighted, PLUS the
  /// shape mismatch.
  double cost(int idx, TileDescriptor? tile) {
    if (tile == null) return 1e6;
    final p = placements[idx];
    final tsc = tile.subregionColors;
    final err = tsc != null
        ? subregionDistance(p.subregionColors, tsc)
        : labDistance(p.averageLabColor, tile.averageLabColor);
    final shape =
        aspectPenalty(tile.aspectRatio, p.width / p.height) * _aspectWeight;
    final sal = saliency != null ? saliency[idx] : p.detailScore;
    return err * (0.2 + sal * 0.8) + shape;
  }

  TileDescriptor? tileOf(int idx) =>
      tileMap[getBaseTileId(placements[idx].tileId)];

  /// How many edge neighbours of [idx] hold photo [base]. [ignore] is the swap partner,
  /// whose own tile is about to change.
  int twinCount(int idx, String base, int ignore) {
    var c = 0;
    for (final m in edges[idx]) {
      if (m == ignore) continue;
      if (baseIds[m] == base) c++;
    }
    return c;
  }

  // Photo -> the cells currently holding it. Candidates are drawn from here rather than
  // uniformly at random: when four photos cover a thousand cells, a random draw almost
  // always lands on a photo that is already against the cell, and the search stalls.
  final cellsByBase = <String, List<int>>{};
  for (var i = 0; i < n; i++) {
    cellsByBase.putIfAbsent(baseIds[i], () => <int>[]).add(i);
  }

  int countPairs() {
    var c = 0;
    for (var i = 0; i < n; i++) {
      for (final j in edges[i]) {
        if (j > i && baseIds[j] == baseIds[i]) c++;
      }
    }
    return c;
  }

  final initial = countPairs();
  if (initial == 0) return const NoTouchReport(0, 0, 0, false);

  // Twins everywhere means the settings asked for them. Leave the mosaic exactly as the
  // matcher built it, and report the count so the decision is visible.
  var edgePairs = 0;
  for (var i = 0; i < n; i++) {
    for (final j in edges[i]) {
      if (j > i) edgePairs++;
    }
  }
  // The pass used to bow out here when twins were everywhere, reading a high rate as
  // "the settings asked for this". They did not: two copies of the same photo sharing a
  // border is the most obvious flaw a mosaic can have. Variety 0 means "reuse photos
  // freely", not "print them in pairs" — repeating three cells away is the intent,
  // touching is the defect. So it always runs, and the budget scales with the size of
  // the problem instead. Must match no-touch.ts.
  final twinRate = edgePairs > 0 ? initial / edgePairs : 0;
  final budget = math.max(
      8,
      (n *
              (twinRate > _skipAboveTwinRate
                  ? _maxSwapFractionHeavy
                  : _maxSwapFraction))
          .ceil());
  final rnd = _Mulberry(0x5eed);
  var swaps = 0;

  for (var pass = 0; pass < _maxPasses; pass++) {
    final violating = <int>[];
    for (var i = 0; i < n; i++) {
      for (final j in edges[i]) {
        if (j > i && baseIds[j] == baseIds[i]) {
          violating.add(i);
          break;
        }
      }
    }
    if (violating.isEmpty) return NoTouchReport(initial, 0, swaps, false);

    var fixedThisPass = 0;
    for (final i in violating) {
      if (swaps >= budget) break;
      final baseI = baseIds[i];
      // May have been cleared by an earlier swap in this same pass.
      if (twinCount(i, baseI, -1) == 0) continue;

      final tileI = tileOf(i);
      final costI = cost(i, tileI);
      final before = twinCount(i, baseI, -1);

      var bestK = -1;
      var bestViolDelta = 1;
      var bestCostDelta = double.infinity;

      /// Ranked by violations removed first and colour damage second — a swap exists to
      /// clear a twin, and a prettier swap that clears nothing is not what this is for.
      void consider(int k) {
        if (k == i) return;
        final baseK = baseIds[k];
        if (baseK == baseI) return; // swapping identical photos changes nothing
        final after = twinCount(i, baseK, k) + twinCount(k, baseI, i);
        final violDelta = after - (before + twinCount(k, baseK, i));
        if (violDelta > 0 || violDelta > bestViolDelta) return;
        final tileK = tileOf(k);
        final costDelta =
            cost(i, tileK) + cost(k, tileI) - costI - cost(k, tileK);
        if (costDelta > _maxSwapDamage) return; // not worth it — leave the twin
        if (violDelta < bestViolDelta || costDelta < bestCostDelta) {
          bestViolDelta = violDelta;
          bestCostDelta = costDelta;
          bestK = k;
        }
      }

      // Targeted: photos that are NOT against this cell, so the swap can actually clear
      // it. Cheapest colour first, so the search usually settles on its first few.
      final forbidden = <String>{};
      for (final m in edges[i]) {
        forbidden.add(baseIds[m]);
      }
      final legal = <({String base, double c})>[];
      for (final base in cellsByBase.keys) {
        if (base == baseI || forbidden.contains(base)) continue;
        legal.add((base: base, c: cost(i, tileMap[base])));
      }
      legal.sort((a, b) => a.c.compareTo(b.c));
      final limit = math.min(legal.length, _legalBasesPerFix);
      for (var li = 0; li < limit; li++) {
        final holders = cellsByBase[legal[li].base]!;
        final take = math.min(holders.length, _holdersPerBase);
        for (var t = 0; t < take; t++) {
          consider(holders[(rnd() * holders.length).floor()]);
        }
      }
      // A few uniform draws as well: when every photo is forbidden, the only moves left
      // live outside the targeted set.
      for (var c = 0; c < _randomCandidatesPerFix; c++) {
        consider((rnd() * n).floor());
      }

      // A break-even swap is allowed — it is how the search crosses a plateau — but only
      // when it buys colour, and it does not count as progress for the pass.
      if (bestK < 0 || (bestViolDelta == 0 && bestCostDelta >= 0)) continue;
      final k = bestK;
      final id = placements[i].tileId;
      final name = placements[i].tileName;
      placements[i].tileId = placements[k].tileId;
      placements[i].tileName = placements[k].tileName;
      placements[k].tileId = id;
      placements[k].tileName = name;
      final bk = baseIds[k];
      baseIds[k] = baseIds[i];
      baseIds[i] = bk;
      // cellsByBase must follow, or later candidate draws point at stale contents.
      final fromI = cellsByBase[bk];
      if (fromI != null) fromI[fromI.indexOf(k)] = i;
      final fromK = cellsByBase[baseIds[k]];
      if (fromK != null) fromK[fromK.indexOf(i)] = k;
      swaps++;
      if (bestViolDelta < 0) fixedThisPass++;
    }

    if (fixedThisPass == 0 || swaps >= budget) break;
  }

  // ── Last resort: REASSIGN the survivors ───────────────────────────────────
  //
  // Swapping preserves which photos are used, which is why it is the default. It is
  // also why it gets stuck: when one photo covers a whole region there is no partner
  // that clears the twin without creating another, and a visible seam of identical
  // neighbours survives. Here the cell simply takes a different photo. That does shift
  // the usage counts — so it is reached only after the swap passes give up, and only
  // for cells still violating. Must match no-touch.ts.
  for (var i = 0; i < n; i++) {
    if (twinCount(i, baseIds[i], -1) == 0) continue;
    final forbidden = <String>{};
    for (final m in edges[i]) {
      forbidden.add(baseIds[m]);
    }
    String? bestBase;
    var bestCost = double.infinity;
    for (final base in cellsByBase.keys) {
      if (forbidden.contains(base)) continue;
      final c = cost(i, tileMap[base]);
      if (c < bestCost) {
        bestCost = c;
        bestBase = base;
      }
    }
    if (bestBase == null) continue; // every photo borders this cell — genuinely stuck
    final t = tileMap[bestBase];
    if (t == null) continue;
    cellsByBase[baseIds[i]]?.remove(i);
    placements[i].tileId = t.id;
    placements[i].tileName = t.name;
    baseIds[i] = bestBase;
    cellsByBase[bestBase]?.add(i);
  }

  return NoTouchReport(initial, countPairs(), swaps, false);
}
