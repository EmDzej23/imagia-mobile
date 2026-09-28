import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/rhombille.dart';

/// Geometry parity for the 3D cube lattice.
///
/// The reference is captured from the WEB module (`lib/mosaic/rhombille.ts`) and
/// replayed here, so the two lattices cannot drift. The face traversal matters as much
/// as the positions: the basis vectors decide how a photo sits on each facet, and
/// getting `left` wrong rotates every left face by 90 degrees — which is exactly the
/// bug that shipped once on the web.
void main() {
  final ref = jsonDecode(
      File('test/fixtures/rhombille_ref.json').readAsStringSync()) as Map<String, dynamic>;

  test('lattice matches the web reference cell-for-cell', () {
    final cells = buildRhombilleCells(1600, 1067, 12);
    expect(cells.length, ref['count'], reason: 'cell count');
    expect(rhombEdge(cells[0]), closeTo((ref['edge'] as num).toDouble(), 1e-9));

    final first = ref['first'] as List;
    for (var i = 0; i < first.length; i++) {
      final r = (first[i] as Map).cast<String, dynamic>();
      final c = cells[i];
      expect(c.face, r['face'], reason: 'face @$i');
      final q = (r['quad'] as List).cast<num>();
      for (var k = 0; k < 8; k++) {
        expect(c.quad[k], closeTo(q[k].toDouble(), 1e-4), reason: 'quad[$k] @$i');
      }
      expect(c.cx, closeTo((r['cx'] as num).toDouble(), 1e-4), reason: 'cx @$i');
      expect(c.cy, closeTo((r['cy'] as num).toDouble(), 1e-4), reason: 'cy @$i');
      expect(cubeKey(c.quad, c.face), r['key'], reason: 'cubeKey @$i');
    }
  });

  test('the three faces of a hexagon share one cube key', () {
    final cells = buildRhombilleCells(800, 600, 8);
    final byKey = <String, List<String>>{};
    for (final c in cells) {
      byKey.putIfAbsent(cubeKey(c.quad, c.face), () => <String>[]).add(c.face);
    }
    // Interior cubes contribute all three faces; edge ones may be clipped.
    final complete = byKey.values.where((f) => f.length == 3).toList();
    expect(complete, isNotEmpty);
    for (final faces in complete) {
      expect(faces.toSet(), {'top', 'left', 'right'},
          reason: 'a cube must be exactly one of each face');
    }
  });

  test('left face keeps the wall vertical, not rotated', () {
    // The bug this guards: traversing the left rhombus from the wrong corner makes `u`
    // point straight up, laying every photo on that facet on its side.
    final cells = buildRhombilleCells(800, 600, 8);
    final left = cells.firstWhere((c) => c.face == 'left');
    expect(left.vx, closeTo(0, 1e-9), reason: 'v must be the vertical wall edge');
    expect(left.vy, greaterThan(0));
    expect(left.ux, greaterThan(0), reason: 'u must run across, not up');
  });

  test('all rhombi share one edge length', () {
    final cells = buildRhombilleCells(1200, 900, 10);
    final e = rhombEdge(cells[0]);
    for (final c in cells) {
      expect(rhombEdge(c), closeTo(e, 1e-9));
      // Both edge vectors of a rhombus are equal length, by definition.
      final vLen = (c.vx * c.vx + c.vy * c.vy);
      expect(vLen, closeTo(e * e, 1e-6));
    }
  });
}
