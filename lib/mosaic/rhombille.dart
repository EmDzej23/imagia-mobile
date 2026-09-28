import 'dart:math' as math;

import 'shared.dart';

/// Rhombille ("tumbling blocks") tiling — the 3D cube-wall layout.
///
/// The plane is covered by regular hexagons, each split into THREE 60/120 rhombi
/// meeting at its centre. Read as a group those three rhombi are the top, left and
/// right faces of an isometric cube, which is what produces the 3D illusion — the
/// geometry is flat, the depth is entirely in the eye.
///
/// NOT part of the tile-matching grid: the grid layout assumes axis-aligned cells in a
/// rectangular MxN lattice, and a rhombille lattice is neither. This module produces
/// the cells; matching then runs over them exactly as for any other mode, because a
/// cell still reports an axis-aligned sample rect for the scorer (see [sampleRect]).
///
/// Must match foto-mozaik/lib/mosaic/rhombille.ts.

/// Which cube face a rhombus represents. Drives shading, and nothing else.
typedef RhombFace = String; // 'top' | 'left' | 'right'

final double _sqrt32 = math.sqrt(3) / 2;

class RhombCell {
  RhombCell({
    required this.face,
    required this.quad,
    required this.ox,
    required this.oy,
    required this.ux,
    required this.uy,
    required this.vx,
    required this.vy,
    required this.cx,
    required this.cy,
  });

  final RhombFace face;

  /// The four corners, clockwise from [ox],[oy]. Base-image pixels.
  final List<double> quad;

  /// Corner the affine map starts from, plus its two edge vectors.
  final double ox, oy, ux, uy, vx, vy;

  /// Centroid — the centre of the axis-aligned rect handed to the matcher.
  final double cx, cy;
}

/// Per-face shading multiplier.
///
/// Without it the three faces read as a flat pattern of diamonds; with it they read as
/// lit solids and the cubes pop. Light is assumed from above, so the top face is
/// brightest and the two sides fall away — the convention every isometric illustration
/// uses. Must match FACE_SHADE on the web and in the render service.
const Map<RhombFace, double> faceShade = {
  'top': 1.0,
  'left': 0.78,
  'right': 0.9,
};

/// The three rhombi of one hexagon.
///
/// Each is given as origin + two edge vectors rather than as four points, because that
/// is exactly the form a canvas transform wants: the unit square's x-axis maps to `u`
/// and its y-axis to `v`. The quad is derived from them so the two cannot disagree.
List<RhombCell> _hexRhombi(double cx, double cy, double s) {
  // Pointy-top hexagon corners in screen space (y grows downward). v0 is the top
  // vertex, then clockwise.
  final v0 = [cx, cy - s];
  final v1 = [cx + _sqrt32 * s, cy - s / 2];
  final v3 = [cx, cy + s];
  final v5 = [cx - _sqrt32 * s, cy - s / 2];
  // v2 and v4 are implied by the edge vectors below.

  final specs = <({RhombFace face, List<double> o, List<double> u, List<double> v})>[
    // Top face: the "lid" of the cube — v5 -> v0 -> v1 -> centre.
    (face: 'top', o: v5, u: [_sqrt32 * s, -s / 2], v: [_sqrt32 * s, s / 2]),
    // Left face: v5 -> centre -> v3 -> v4.
    //
    // Traversed from v5, NOT from v4. Both describe the same rhombus, but the basis
    // vectors decide how the PHOTO sits on it: the source's y-axis maps to `v`, so `v`
    // has to be the wall's vertical edge (0, s). Starting at v4 made `u` point straight
    // up, which laid every photo on this face on its side — a 90-degree rotation that
    // showed up as the one wrong facet per cube.
    (face: 'left', o: v5, u: [_sqrt32 * s, s / 2], v: [0.0, s]),
    // Right face: centre -> v1 -> v2 -> v3.
    (face: 'right', o: [cx, cy], u: [_sqrt32 * s, -s / 2], v: [0.0, s]),
  ];
  // Referenced so the corner names above stay honest about the traversal.
  assert(v0.length == 2 && v1.length == 2 && v3.length == 2);

  return specs.map((spec) {
    final ox = spec.o[0], oy = spec.o[1];
    final ux = spec.u[0], uy = spec.u[1];
    final vx = spec.v[0], vy = spec.v[1];
    return RhombCell(
      face: spec.face,
      quad: [ox, oy, ox + ux, oy + uy, ox + ux + vx, oy + uy + vy, ox + vx, oy + vy],
      ox: ox, oy: oy, ux: ux, uy: uy, vx: vx, vy: vy,
      // Centroid of a parallelogram is origin + (u + v) / 2.
      cx: ox + (ux + vx) / 2,
      cy: oy + (uy + vy) / 2,
    );
  }).toList();
}

/// Cover `width x height` with rhombi.
///
/// [cellsOnShort] is the density control, matching the other modes: roughly how many
/// cubes fit across the short edge. Hexagons are generated one ring beyond the canvas
/// on every side so the edges are filled rather than showing a ragged hexagonal border
/// — the renderer clips to the canvas.
List<RhombCell> buildRhombilleCells(
    double width, double height, int cellsOnShort) {
  final shorter = math.min(width, height);
  // Hexagon circumradius from the requested cube count. A pointy-top hexagon is
  // sqrt(3)*s wide, so `cellsOnShort` cubes across the short edge means
  // s = short / (sqrt(3) * n).
  final s = math.max(2.0, shorter / (math.sqrt(3) * math.max(1, cellsOnShort)));

  final stepX = math.sqrt(3) * s; // horizontal centre spacing
  final stepY = 1.5 * s; // vertical centre spacing
  final cols = (width / stepX).ceil() + 2;
  final rows = (height / stepY).ceil() + 2;

  final cells = <RhombCell>[];
  for (var r = -1; r < rows; r++) {
    // Odd rows sit half a step right — that interlock is what makes hexagons tile.
    final offset = r % 2 == 0 ? 0.0 : stepX / 2;
    for (var c = -1; c < cols; c++) {
      final cx = c * stepX + offset;
      final cy = r * stepY;
      for (final cell in _hexRhombi(cx, cy, s)) {
        // Drop rhombi entirely off-canvas; keep any that touch it.
        var minX = double.infinity, maxX = -double.infinity;
        var minY = double.infinity, maxY = -double.infinity;
        for (var i = 0; i < 4; i++) {
          minX = math.min(minX, cell.quad[i * 2]);
          maxX = math.max(maxX, cell.quad[i * 2]);
          minY = math.min(minY, cell.quad[i * 2 + 1]);
          maxY = math.max(maxY, cell.quad[i * 2 + 1]);
        }
        if (maxX < 0 || minX > width || maxY < 0 || minY > height) continue;
        cells.add(cell);
      }
    }
  }
  return cells;
}

/// The axis-aligned rect the MATCHER samples for a rhombus.
///
/// The scorer only understands rectangles, and a rhombus is not one. Rather than teach
/// the whole 13-signal pipeline about parallelograms, each cell reports the largest
/// axis-aligned square that sits comfortably inside it, centred on its centroid. The
/// match is then made against the part of the photo the rhombus actually covers, which
/// is what matters; the corners it misses are a small fraction of the area.
({double x, double y, double width, double height}) sampleRect(
    RhombCell cell, double side) {
  final half = side / 2;
  return (x: cell.cx - half, y: cell.cy - half, width: side, height: side);
}

/// Edge length of the rhombi — all are equal, so measure one.
double rhombEdge(RhombCell cell) =>
    math.sqrt(cell.ux * cell.ux + cell.uy * cell.uy);

/// Centre of the CUBE a rhombus belongs to — the hexagon's centre, which is the corner
/// the three faces share. Used to group the three faces as one solid.
({double x, double y}) cubeCentre(List<double> quad, RhombFace face) {
  // The hexagon centre is a different CORNER of each rhombus, because each face is
  // traversed from a different origin — see the spec list in `_hexRhombi`.
  switch (face) {
    case 'top':
      return (x: quad[6], y: quad[7]);
    case 'left':
      return (x: quad[2], y: quad[3]);
    default: // right — the centre IS its origin
      return (x: quad[0], y: quad[1]);
  }
}

/// Stable key for the cube a rhombus belongs to, so the three faces animate together.
String cubeKey(List<double> quad, RhombFace face) {
  final c = cubeCentre(quad, face);
  // Rounded, so the three faces of one cube — computed from different corners and
  // therefore differing in the last bits — collapse to the same key.
  return '${jsRound(c.x).toInt()},${jsRound(c.y).toInt()}';
}
