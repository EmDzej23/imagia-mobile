import 'dart:math' as math;
import 'dart:typed_data';

import 'matching.dart';
import 'shared.dart';
import 'types.dart';

/// REPEAT SPACING — port of foto-mozaik/lib/mosaic/repeat-spacing.ts (keep identical, so
/// the phone and the web build the same mosaic): no photo may appear again within
/// [requestedRadius] cells of itself. A cell with a copy too close gets the best-scoring
/// photo that is NOT in its neighbourhood; a photo's last copy is never removed. The
/// radius shrinks for small libraries (needs twice the (2r+1)² neighbourhood).
class RepeatSpacingResult {
  RepeatSpacingResult(this.radius, this.violations, this.reassigned);
  final int radius;
  final int violations;
  final int reassigned;
}

int spacingRadiusFor(List<TileDescriptor> tiles, num requested) {
  final distinct = {for (final t in tiles) getBaseTileId(t.id)}.length;
  var radius = math.max(0, requested.floor());
  while (radius > 0 && 2 * (2 * radius + 1) * (2 * radius + 1) > distinct) {
    radius--;
  }
  return radius;
}

/// For every cell, the cells within [radius] cells of it (Chebyshev, by centre, in units
/// of the median cell size).
List<List<int>> buildNeighbourLists(
  List<MosaicPlacement> placements,
  int radius,
) {
  final ws = placements.map((p) => p.width).toList()..sort();
  final hs = placements.map((p) => p.height).toList()..sort();
  final cw = ws[ws.length >> 1], ch = hs[hs.length >> 1];
  final reachX = radius * cw + cw * 0.5, reachY = radius * ch + ch * 0.5;
  double cx(MosaicPlacement p) => p.x + p.width / 2;
  double cy(MosaicPlacement p) => p.y + p.height / 2;
  final bucket = math.max(cw, ch);
  // Buckets in a flat array over the occupied range (was a map keyed by "x,y" strings —
  // a string built per lookup). Same buckets, same order, so the same lists.
  final n = placements.length;
  final bx = Int32List(n), by = Int32List(n);
  var minX = 0, minY = 0, maxX = 0, maxY = 0;
  for (var i = 0; i < n; i++) {
    final p = placements[i];
    bx[i] = (cx(p) / bucket).floor();
    by[i] = (cy(p) / bucket).floor();
    if (i == 0 || bx[i] < minX) minX = bx[i];
    if (i == 0 || bx[i] > maxX) maxX = bx[i];
    if (i == 0 || by[i] < minY) minY = by[i];
    if (i == 0 || by[i] > maxY) maxY = by[i];
  }
  final gw = maxX - minX + 1, gh = maxY - minY + 1;
  final grid = List<List<int>?>.filled(n == 0 ? 0 : gw * gh, null);
  for (var i = 0; i < n; i++) {
    (grid[(by[i] - minY) * gw + (bx[i] - minX)] ??= <int>[]).add(i);
  }
  final span = (math.max(reachX, reachY) / bucket).ceil();
  return [
    for (var i = 0; i < n; i++)
      () {
        final p = placements[i];
        final x = cx(p), y = cy(p);
        final gx = bx[i], gy = by[i];
        final out = <int>[];
        for (var dy = -span; dy <= span; dy++) {
          final ry = gy + dy - minY;
          if (ry < 0 || ry >= gh) continue;
          for (var dx = -span; dx <= span; dx++) {
            final rx = gx + dx - minX;
            if (rx < 0 || rx >= gw) continue;
            final cell = grid[ry * gw + rx];
            if (cell == null) continue;
            for (final j in cell) {
              if (j == i) continue;
              final q = placements[j];
              if ((cx(q) - x).abs() <= reachX && (cy(q) - y).abs() <= reachY)
                out.add(j);
            }
          }
        }
        return out;
      }(),
  ];
}

RepeatSpacingResult enforceRepeatSpacing(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  num requestedRadius,
) {
  final radius = spacingRadiusFor(tiles, requestedRadius);
  if (radius == 0 ||
      placements.length < 2 ||
      placements.any((p) => p.quad != null)) {
    return RepeatSpacingResult(radius, 0, 0);
  }
  final nb = buildNeighbourLists(placements, radius);
  final usageCounts = <String, int>{};
  for (final p in placements) {
    final id = getBaseTileId(p.tileId);
    usageCounts[id] = (usageCounts[id] ?? 0) + 1;
  }
  // Photos as ints, and "near this cell" as a stamp per photo — the same membership
  // test as a set of ids built per cell, without hashing strings for every neighbour.
  final idNum = <String, int>{};
  int num(String baseId) => idNum.putIfAbsent(baseId, () => idNum.length);
  final cellId = Int32List(placements.length);
  for (var i = 0; i < placements.length; i++) {
    cellId[i] = num(getBaseTileId(placements[i].tileId));
  }
  final tileId = Int32List.fromList([
    for (final t in tiles) num(getBaseTileId(t.id)),
  ]);
  var nearMark = Int32List(idNum.length + 1);
  var stamp = 0;
  var violations = 0, reassigned = 0;
  for (var i = 0; i < placements.length; i++) {
    final p = placements[i];
    final mine = getBaseTileId(p.tileId);
    stamp++;
    for (final j in nb[i]) {
      nearMark[cellId[j]] = stamp;
    }
    if (nearMark[cellId[i]] != stamp) continue;
    violations++;
    final allowed = <TileDescriptor>[
      for (var t = 0; t < tiles.length; t++)
        if (nearMark[tileId[t]] != stamp) tiles[t],
    ];
    if (allowed.isEmpty) continue;
    final match = selectBestTileMatch(
      MatchInput(
        region: p,
        tiles: allowed,
        settings: settings,
        usageCounts: usageCounts,
        tilePoolSize: tiles.length,
        placementCount: placements.length,
      ),
    );
    final next = getBaseTileId(match.tile.id);
    usageCounts[mine] = (usageCounts[mine] ?? 1) - 1;
    usageCounts[next] = (usageCounts[next] ?? 0) + 1;
    p.tileId = match.tile.id;
    p.tileName = match.tile.name;
    p.score = match.score;
    cellId[i] = num(next);
    if (nearMark.length < idNum.length) {
      nearMark = Int32List(idNum.length * 2)
        ..setRange(0, nearMark.length, nearMark);
    }
    reassigned++;
  }
  return RepeatSpacingResult(radius, violations, reassigned);
}
