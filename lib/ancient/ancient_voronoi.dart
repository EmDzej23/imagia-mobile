import 'dart:typed_data';
import 'dart:ui';

/// Seeds on a jittered lattice. Each Voronoi cell is computed on demand by
/// clipping the bounds box against the perpendicular bisectors with nearby
/// seeds — for a grid-distributed point set this yields the exact Voronoi cell,
/// watertight (neighbours share the identical bisector edge) and robust (convex
/// Sutherland-Hodgman clipping, no triangulation / degeneracy handling needed).
class AncientSeeds {
  AncientSeeds(this.points, this.cols, this.rows, this.cellSize);

  /// Flat x,y pairs, indexed `gy * cols + gx`.
  final Float64List points;
  final int cols;
  final int rows;
  final double cellSize;

  int get count => cols * rows;
  double x(int i) => points[i * 2];
  double y(int i) => points[i * 2 + 1];
}

int _lcg(int s) => (s * 1664525 + 1013904223) & 0xFFFFFFFF;

/// Jittered grid of seeds spanning `w`×`h` at spacing `s`. `nonce` reshuffles.
AncientSeeds buildSeeds(
    double w, double h, double s, double irregularity, int nonce) {
  final cols = (w / s).ceil() + 1;
  final rows = (h / s).ceil() + 1;
  final pts = Float64List(cols * rows * 2);
  var state = (1000 + nonce * 7919) & 0xFFFFFFFF;
  double rnd() {
    state = _lcg(state);
    return state / 4294967296.0;
  }

  var k = 0;
  for (var gy = 0; gy < rows; gy++) {
    for (var gx = 0; gx < cols; gx++) {
      pts[k * 2] = (gx + 0.5 + (rnd() - 0.5) * irregularity) * s;
      pts[k * 2 + 1] = (gy + 0.5 + (rnd() - 0.5) * irregularity) * s;
      k++;
    }
  }
  return AncientSeeds(pts, cols, rows, s);
}

/// The Voronoi cell polygon for seed [index], clipped to `[0,0,w,h]`. Returns a
/// closed vertex ring (no repeated last point), or null if degenerate. [win] is
/// the neighbour search radius in grid steps (2 = 5×5, safe for jitter ≤ 1 cell).
List<Offset>? cellPolygon(AncientSeeds seeds, int index, double w, double h,
    {int win = 2}) {
  final cols = seeds.cols, rows = seeds.rows;
  final gx = index % cols, gy = index ~/ cols;
  final px = seeds.x(index), py = seeds.y(index);

  var poly = <Offset>[
    const Offset(0, 0),
    Offset(w, 0),
    Offset(w, h),
    Offset(0, h),
  ];

  for (var dy = -win; dy <= win; dy++) {
    for (var dx = -win; dx <= win; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = gx + dx, ny = gy + dy;
      if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
      final j = ny * cols + nx;
      final qx = seeds.x(j), qy = seeds.y(j);
      // Keep the half-plane of points closer to the seed than to the neighbour:
      // dot(p - midpoint, seed - neighbour) >= 0.
      poly = _clipHalfPlane(poly, (px + qx) / 2, (py + qy) / 2, px - qx, py - qy);
      if (poly.length < 3) return null;
    }
  }
  return poly.length >= 3 ? poly : null;
}

/// Sutherland-Hodgman clip of a convex polygon to the half-plane
/// `dot(p - m, a) >= 0`.
List<Offset> _clipHalfPlane(
    List<Offset> poly, double mx, double my, double ax, double ay) {
  final out = <Offset>[];
  final n = poly.length;
  for (var i = 0; i < n; i++) {
    final cur = poly[i];
    final nxt = poly[(i + 1) % n];
    final dCur = (cur.dx - mx) * ax + (cur.dy - my) * ay;
    final dNxt = (nxt.dx - mx) * ax + (nxt.dy - my) * ay;
    if (dCur >= 0) out.add(cur);
    if ((dCur >= 0) != (dNxt >= 0)) {
      final t = dCur / (dCur - dNxt);
      out.add(Offset(
          cur.dx + (nxt.dx - cur.dx) * t, cur.dy + (nxt.dy - cur.dy) * t));
    }
  }
  return out;
}
