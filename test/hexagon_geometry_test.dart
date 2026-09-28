import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/hexagon.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Geometry parity for the flat-top honeycomb.
///
/// The same checks the web side runs, asserted here so the two lattices cannot drift:
/// a hexagon tiling that leaves gaps, or whose sample rect escapes its cell, produces a
/// mosaic that looks broken rather than merely different.
void main() {
  /// FLAT-TOP containment: |dx| <= s, |dy| <= sqrt(3)s/2, and the four slanted edges.
  bool inHex(double px, double py, double cx, double cy, double s) {
    final dx = (px - cx).abs(), dy = (py - cy).abs();
    if (dx > s + 1e-9) return false;
    if (dy > (math.sqrt(3) / 2) * s + 1e-9) return false;
    return dy <= math.sqrt(3) * (s - dx) + 1e-9;
  }

  test('aspect matches the web constant', () {
    expect(hexAspect, closeTo(2 / math.sqrt(3), 1e-12));
    expect(hexAspect, closeTo(1.1547005383792515, 1e-12));
  });

  test('lattice tiles the canvas with no gaps and no overlaps', () {
    const w = 1600.0, h = 1067.0;
    for (final n in [10, 24, 40]) {
      final cells = buildHexCells(w, h, n);
      var gaps = 0, overlaps = 0, ok = 0;
      for (var y = 2.0; y < h; y += 7) {
        for (var x = 2.0; x < w; x += 7) {
          var hits = 0;
          for (final c in cells) {
            if ((c.cx - x).abs() > 2 * c.s || (c.cy - y).abs() > 2 * c.s) continue;
            if (inHex(x, y, c.cx, c.cy, c.s)) hits++;
          }
          if (hits == 0) {
            gaps++;
          } else if (hits > 1) {
            overlaps++;
          } else {
            ok++;
          }
        }
      }
      expect(gaps, 0, reason: 'gaps at cellsOnShort=$n');
      expect(overlaps, 0, reason: 'overlaps at cellsOnShort=$n');
      expect(ok, greaterThan(0));
    }
  });

  test('sample rect lies inside its hexagon and round-trips', () {
    final cells = buildHexCells(1600, 1067, 24);
    for (final c in cells) {
      final r = hexSampleRect(c);
      for (final p in [
        [r.x, r.y],
        [r.x + r.width, r.y],
        [r.x, r.y + r.height],
        [r.x + r.width, r.y + r.height],
      ]) {
        expect(inHex(p[0], p[1], c.cx, c.cy, c.s), isTrue,
            reason: 'sample corner escaped the hexagon');
      }
      expect(r.width / r.height, closeTo(hexAspect, 1e-9));
      final back = hexFromRect(r.x, r.y, r.width, r.height);
      expect(back.cx, closeTo(c.cx, 1e-9));
      expect(back.cy, closeTo(c.cy, 1e-9));
      expect(back.s, closeTo(c.s, 1e-9));
    }
  });

  test('adjacency finds six neighbours for interior cells', () {
    // The bug this guards: the generic rect-overlap adjacency returns ZERO neighbours
    // for a honeycomb, because a hexagon's stored rect is its sample window and two
    // neighbours' rects never touch. That silently disables SA's coherence term, the
    // neighbour-contrast part of saliency, and the no-touch gate — no error, just a
    // worse mosaic.
    final cells = buildHexCells(1600, 1067, 24);
    final placements = cells.map((c) {
      final r = hexSampleRect(c);
      return _stubPlacement(r.x, r.y, r.width, r.height);
    }).toList();
    final adj = buildHexAdjacency(placements);
    final degree6 = adj.where((a) => a.length == 6).length;
    expect(adj.every((a) => a.length <= 6), isTrue,
        reason: 'a hexagon cannot have more than six neighbours');
    expect(degree6 / adj.length, greaterThan(0.85),
        reason: 'most cells are interior and must have all six');
  });

  test('corners are flat-top, not inscribed in a circle', () {
    // The bug this guards: deriving corners from angles on a circle makes the hexagon
    // 15% too narrow on the flat axis, which opens gaps along every seam.
    final pts = hexCorners(0, 0, 200, 100);
    expect(pts[2][0], closeTo(100, 1e-9)); // right point reaches the full half-width
    expect(pts[0][1], closeTo(-50, 1e-9)); // flat top reaches the full half-height
    expect(pts[0][0], closeTo(-50, 1e-9)); // flat top spans the middle half
    expect(pts[1][0], closeTo(50, 1e-9));
  });
}

/// Minimal placement carrying only the geometry the adjacency rule reads.
MosaicPlacement _stubPlacement(double x, double y, double w, double h) =>
    MosaicPlacement(
      x: x,
      y: y,
      width: w,
      height: h,
      averageColor: RgbColor(0, 0, 0),
      averageLabColor: LabColor(0, 0, 0),
      detailScore: 0,
      subregionColors: List.filled(25, LabColor(0, 0, 0)),
      subregionEdges: List.filled(25, 0),
      contrastMap: List.filled(25, 0),
      luminanceBalance: LuminanceBalance(0, 0),
      colorVariance: 0,
      edgeOrientation: 0,
      tonalHistogram: List.filled(8, 0),
      subregionEdgeOrientations: Float32List(100),
      index: 0,
      tileId: 't',
      tileName: 't',
      score: 0,
    );
