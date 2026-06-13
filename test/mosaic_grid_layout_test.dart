import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Fidelity harness (layer 1 — end-to-end pipeline).
///
/// Feeds the SAME synthetic base-image RGBA bytes through the WHOLE Dart
/// pipeline — integral image → square-grid layout → uniform selection →
/// Vogel assignment → 3-seed simulated annealing → palette balance — and
/// asserts the resulting plan matches the web `buildGridLayout` reference
/// placement-for-placement (tileId + geometry + score).
///
/// Because both sides build the integral image from identical bytes (no
/// platform decode/resize in between), the entire deterministic pipeline is
/// exercised bit-for-bit.
void main() {
  test('buildGridLayout (square) reproduces the web plan end-to-end', () {
    final fixture = jsonDecode(
            File('test/fixtures/fidelity_core.json').readAsStringSync())
        as Map<String, dynamic>;

    final tiles = (fixture['tiles'] as List)
        .map((e) => TileDescriptor.fromJson((e as Map).cast<String, dynamic>()))
        .toList();

    final gl = (fixture['gridLayout'] as Map).cast<String, dynamic>();
    final baseWidth = (gl['baseWidth'] as num).toDouble();
    final baseHeight = (gl['baseHeight'] as num).toDouble();
    final settings =
        MosaicSettings.fromJson((gl['settings'] as Map).cast<String, dynamic>());
    final pixels = base64Decode(gl['basePixelsB64'] as String);

    // Build the analyzer from the exact same bytes the web used (sampleW/H ==
    // base dims, so no downscale — matches the web's no-op resize at 120px).
    final analyzer = ImageAnalyzer.fromPixels(
      Uint8List.fromList(pixels),
      baseWidth.toInt(),
      baseHeight.toInt(),
      baseWidth,
      baseHeight,
      colorBoost: settings.colorBoost,
      autoContrast: settings.autoContrast,
    );

    final placements = buildGridLayout(
      baseWidth: baseWidth,
      baseHeight: baseHeight,
      analyzer: analyzer,
      tiles: tiles,
      settings: settings,
      isMobile: false,
    );

    final ref = (gl['placements'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    expect(placements.length, ref.length, reason: 'placement count');

    // tileId + geometry ARE the mosaic output — assert exact.
    // score is a derived accumulator that carries the cbrt/log ≤1-ULP noise
    // through ~20 summed terms, so it is asserted within a tight tolerance.
    // Collect tileId mismatches to report the overall agreement, not just the
    // first failure.
    final tileMismatches = <int>[];
    for (var i = 0; i < placements.length; i++) {
      final p = placements[i];
      final r = ref[i];
      expect(p.index, r['index'], reason: 'index @$i');
      expect(p.x, (r['x'] as num).toDouble(), reason: 'x @$i');
      expect(p.y, (r['y'] as num).toDouble(), reason: 'y @$i');
      expect(p.width, (r['width'] as num).toDouble(), reason: 'width @$i');
      expect(p.height, (r['height'] as num).toDouble(), reason: 'height @$i');
      expect(p.score, closeTo((r['score'] as num).toDouble(), 1e-6),
          reason: 'score @$i');
      if (p.tileId != r['tileId']) tileMismatches.add(i);
    }
    expect(tileMismatches, isEmpty,
        reason:
            '${tileMismatches.length}/${placements.length} tile assignments diverged');
  });
}
