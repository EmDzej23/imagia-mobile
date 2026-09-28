import 'dart:math' as math;

import 'types.dart';

/// Flat-top hexagon tiling — the `hexagon` photo mode.
///
/// Geometrically this is the same lattice the rhombille (3D cubes) mode generates: that
/// mode builds hexagons and then cuts each into three rhombi to fake isometric cubes.
/// Here the hexagon stays whole, so the same centre spacing produces a honeycomb.
///
/// A hexagon is far simpler to render than a rhombus: a rhombus needs a shear, which is
/// why the 3D mode carries an explicit four-point quad. A regular hexagon is fully
/// determined by its centre and its circumradius, so nothing extra has to be stored on
/// the placement — the six vertices are derived from the cell rect wherever needed.
///
/// Must match foto-mozaik/lib/mosaic/hexagon.ts.

/// Circumradius -> box. A FLAT-TOP hexagon is 2*s wide and sqrt(3)*s tall — the
/// transpose of the pointy-top form, so it sits wider than it is tall.
const double _widthPerS = 2;
final double _heightPerS = math.sqrt(3);

/// The axis-aligned rect the MATCHER samples for a hexagon.
///
/// The 13-signal scorer only understands rectangles. Rather than teach every signal
/// about hexagons, each cell reports the largest centred rect that fits inside it AT
/// THE HEXAGON'S OWN ASPECT. Matching the proportions matters as much as the fit: the
/// structural signals compare a grid of subregions, so a sample window shaped
/// differently from what gets drawn would align those subregions against the wrong
/// parts of the photo.
///
/// Derivation: the upper-right edge runs from (s, 0) to (s/2, sqrt(3)*s/2), i.e.
/// y = sqrt(3)(s - x). A centred rect of half-width a and half-height b fits when
/// b <= sqrt(3)(s - a); holding a/b = 2/sqrt(3) gives b = s/sqrt(3). So the rect is
/// (4/3)*s wide and (2*sqrt(3)/3)*s tall — 59% of the hexagon's area. The rest is the
/// six corners, and they are the part a single average colour describes worst anyway.
const double hexSampleWPerS = 4 / 3;
final double hexSampleHPerS = (2 * math.sqrt(3)) / 3;

/// The hexagon's aspect ratio — and therefore its sample rect's, and its crop frame's.
final double hexAspect = _widthPerS / _heightPerS; // 2/sqrt(3) ~ 1.1547

/// Pixels of overlap between neighbouring cells, to hide antialiased seams.
const double hexOverdraw = 1;

class HexCell {
  const HexCell(this.cx, this.cy, this.s);

  /// Centre, in base-image pixels.
  final double cx;
  final double cy;

  /// Circumradius: centre to any vertex.
  final double s;
}

class HexRect {
  const HexRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

HexRect hexSampleRect(HexCell cell) {
  final w = cell.s * hexSampleWPerS;
  final h = cell.s * hexSampleHPerS;
  return HexRect(cell.cx - w / 2, cell.cy - h / 2, w, h);
}

/// Recover the hexagon from a placement's rect.
///
/// The inverse of [hexSampleRect], and the reason the mode needs no new field on
/// MosaicPlacement: everything downstream already carries x/y/width/height, and for this
/// mode that rect IS the hexagon, stated in a form the matcher can read.
HexCell hexFromRect(double x, double y, double width, double height) =>
    HexCell(x + width / 2, y + height / 2, height / hexSampleHPerS);

/// The six corners of a FLAT-TOP hexagon, clockwise from the top-left, given the full
/// WIDTH and HEIGHT of its bounding box.
///
/// Stated explicitly rather than derived from angles on a circle. The circle form is
/// the obvious one and it is a trap: a hexagon inscribed in a circle of radius h/2 only
/// reaches y = +/-(sqrt(3)/2)(h/2), so it comes out 15% too short and the tiling opens
/// gaps along every seam. Taking width and height separately also handles the
/// anisotropic case, which a single radius cannot express at all.
List<List<double>> hexCorners(double cx, double cy, double w, double h) => [
      [cx - w / 4, cy - h / 2],
      [cx + w / 4, cy - h / 2],
      [cx + w / 2, cy],
      [cx + w / 4, cy + h / 2],
      [cx - w / 4, cy + h / 2],
      [cx - w / 2, cy],
    ];

/// Lay a hexagon lattice over the canvas.
///
/// [cellsOnShort] is the density control, matching every other mode: roughly how many
/// hexagons fit across the short edge. Cells are generated one ring beyond the canvas on
/// every side so the edges are filled rather than showing a ragged honeycomb border —
/// the renderer clips to the canvas.
List<HexCell> buildHexCells(double width, double height, int cellsOnShort) {
  final shorter = math.min(width, height);
  // Deliberately the same formula the pointy-top version used, so the flip to flat-top
  // changed the SHAPE without changing the cell size — the density slider still means
  // what it meant, and a saved project renders at the same scale.
  final s = math.max(2.0, shorter / (math.sqrt(3) * math.max(1, cellsOnShort)));

  // Flat-top: columns interlock, so the horizontal step is 3/4 of the width and it is
  // the odd COLUMNS that sit half a step down — the transpose of the pointy-top layout.
  final stepX = 1.5 * s;
  final stepY = _heightPerS * s;
  final cols = (width / stepX).ceil() + 2;
  final rows = (height / stepY).ceil() + 2;

  final cells = <HexCell>[];
  for (var c = -1; c < cols; c++) {
    final offset = c % 2 == 0 ? 0.0 : stepY / 2;
    for (var r = -1; r < rows; r++) {
      final cx = c * stepX;
      final cy = r * stepY + offset;
      if (cx + s < 0 || cx - s > width) continue;
      if (cy + stepY / 2 < 0 || cy - stepY / 2 > height) continue;
      cells.add(HexCell(cx, cy, s));
    }
  }
  return cells;
}

/// Neighbour map for a honeycomb, by CENTRE DISTANCE.
///
/// The generic rect-overlap adjacency cannot express this tiling. A hexagon's stored
/// rect is its sample window, 59% of the drawn cell, so neighbouring rects sit a sixth
/// of a cell apart and never overlap — and widening the tolerance does not help, because
/// the rect test checks the two axes independently: the slack that finally reaches the
/// left/right neighbour also reaches a second-ring cell that is not a neighbour at all.
///
/// Distance separates them cleanly. In a hex lattice the six true neighbours sit at
/// exactly sqrt(3)*s ~ 1.73*s and the next ring no closer than 3*s, so any threshold
/// between those two works; 2.2 sits in the middle of that gap.
List<Set<int>> buildHexAdjacency(List<MosaicPlacement> placements) {
  final n = placements.length;
  final adj = List<Set<int>>.generate(n, (_) => <int>{}, growable: false);
  if (n < 2) return adj;

  final cells = placements
      .map((p) => hexFromRect(p.x, p.y, p.width, p.height))
      .toList(growable: false);
  final s = cells[0].s;
  final reach = 2.2 * s;
  final reach2 = reach * reach;

  final cell = math.max(1.0, reach);
  int key(int col, int row) => (col * 73856093) ^ (row * 19349663);
  final buckets = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    buckets
        .putIfAbsent(
            key((cells[i].cx / cell).floor(), (cells[i].cy / cell).floor()),
            () => <int>[])
        .add(i);
  }

  for (var i = 0; i < n; i++) {
    final gc = (cells[i].cx / cell).floor();
    final gr = (cells[i].cy / cell).floor();
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final b = buckets[key(gc + dc, gr + dr)];
        if (b == null) continue;
        for (final j in b) {
          if (j <= i) continue;
          final dx = cells[i].cx - cells[j].cx;
          final dy = cells[i].cy - cells[j].cy;
          if (dx * dx + dy * dy > reach2) continue;
          adj[i].add(j);
          adj[j].add(i);
        }
      }
    }
  }
  return adj;
}
