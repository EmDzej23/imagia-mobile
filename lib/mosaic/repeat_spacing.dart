import 'dart:math' as math;

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
  final grid = <String, List<int>>{};
  for (var i = 0; i < placements.length; i++) {
    final p = placements[i];
    final k = '${(cx(p) / bucket).floor()},${(cy(p) / bucket).floor()}';
    (grid[k] ??= []).add(i);
  }
  final span = (math.max(reachX, reachY) / bucket).ceil();
  return [
    for (var i = 0; i < placements.length; i++)
      () {
        final p = placements[i];
        final x = cx(p), y = cy(p);
        final gx = (x / bucket).floor(), gy = (y / bucket).floor();
        final out = <int>[];
        for (var dy = -span; dy <= span; dy++) {
          for (var dx = -span; dx <= span; dx++) {
            for (final j in grid['${gx + dx},${gy + dy}'] ?? const <int>[]) {
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
  var violations = 0, reassigned = 0;
  for (var i = 0; i < placements.length; i++) {
    final p = placements[i];
    final mine = getBaseTileId(p.tileId);
    final nearIds = {
      for (final j in nb[i]) getBaseTileId(placements[j].tileId),
    };
    if (!nearIds.contains(mine)) continue;
    violations++;
    final allowed = tiles
        .where((t) => !nearIds.contains(getBaseTileId(t.id)))
        .toList();
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
    reassigned++;
  }
  return RepeatSpacingResult(radius, violations, reassigned);
}
