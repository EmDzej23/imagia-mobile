import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// End-to-end smoke for the two non-rectangular modes.
///
/// These bypass the MxN grid machinery entirely, so the ordinary layout tests say
/// nothing about them. What matters here is that a plan comes out at all, that the
/// geometry each mode needs actually reaches the placements, and that the mode-specific
/// fields survive into the render payload — the field that goes missing silently is how
/// a honeycomb ships as rectangles.
void main() {
  const w = 640.0, h = 480.0;

  ImageAnalyzer makeAnalyzer() {
    final px = Uint8List(w.toInt() * h.toInt() * 4);
    for (var y = 0; y < h.toInt(); y++) {
      for (var x = 0; x < w.toInt(); x++) {
        final o = (y * w.toInt() + x) * 4;
        px[o] = (x * 255 ~/ w.toInt());
        px[o + 1] = (y * 255 ~/ h.toInt());
        px[o + 2] = 128;
        px[o + 3] = 255;
      }
    }
    return ImageAnalyzer.fromPixels(px, w.toInt(), h.toInt(), w, h);
  }

  List<TileDescriptor> makeTiles(int n) => List.generate(n, (i) {
        final t = i / n;
        return createTileDescriptor(
          't$i',
          't$i',
          100,
          i.isEven ? 75 : 133,
          RgbColor(255 * t, 255 * (1 - t), 128),
          0.5,
          List.filled(25, LabColor(60 * t, 10, -10)),
          List.filled(25, 0.2),
          List.filled(25, 0.3),
          LuminanceBalance(0, 0),
          0.2,
          0,
          List.filled(8, 0.125),
          Float32List(100),
        );
      });

  test('rhombille produces cube facets with quad and face', () {
    final placements = buildGridLayout(
      baseWidth: w,
      baseHeight: h,
      analyzer: makeAnalyzer(),
      tiles: makeTiles(24),
      settings: defaultSettings()
        ..mosaicMode = 'rhombille'
        ..density = 60,
    );
    expect(placements, isNotEmpty);
    expect(placements.every((p) => p.quad != null && p.quad!.length == 8), isTrue,
        reason: 'every cube facet needs its parallelogram');
    expect(placements.every((p) => ['top', 'left', 'right'].contains(p.face)), isTrue,
        reason: 'face drives the lighting multiplier');
    // Facets come in threes, so all three faces must be present in quantity.
    final faces = placements.map((p) => p.face).toSet();
    expect(faces, {'top', 'left', 'right'});
  });

  test('hexagon produces honeycomb cells at the right aspect', () {
    final placements = buildGridLayout(
      baseWidth: w,
      baseHeight: h,
      analyzer: makeAnalyzer(),
      tiles: makeTiles(24),
      settings: defaultSettings()
        ..mosaicMode = 'hexagon'
        ..density = 60,
    );
    expect(placements, isNotEmpty);
    expect(placements.every((p) => p.quad == null), isTrue,
        reason: 'a hexagon is rebuilt from its rect, not from a stored polygon');
    for (final p in placements) {
      expect(p.width / p.height, closeTo(1.1547005383792515, 1e-6),
          reason: 'sample rect must carry the flat-top hexagon aspect');
    }
  });

  test('both modes assign a real tile to every cell', () {
    for (final mode in ['rhombille', 'hexagon']) {
      final placements = buildGridLayout(
        baseWidth: w,
        baseHeight: h,
        analyzer: makeAnalyzer(),
        tiles: makeTiles(24),
        settings: defaultSettings()
          ..mosaicMode = mode
          ..density = 48,
      );
      expect(placements.every((p) => p.tileId.isNotEmpty), isTrue,
          reason: '$mode left a cell unmatched');
      expect(placements.map((p) => p.index).toSet().length, placements.length,
          reason: '$mode produced duplicate indices');
    }
  });
}
