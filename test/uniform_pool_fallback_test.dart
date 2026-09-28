import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// A library with no photo of the requested orientation must still build.
///
/// `_buildTilePools` returns an EMPTY list when nothing matches the orientation, and an
/// empty list is not null — so `tilePools[cellAR] ?? tiles` handed the uniform selector
/// a pool of zero tiles and the whole build threw. Someone whose camera roll is all
/// landscape picking Portrait is an ordinary thing to do, not an error, so the mode
/// falls back to the full library and centre-crops, exactly as `square` always has.
void main() {
  const w = 640.0, h = 480.0;

  ImageAnalyzer makeAnalyzer() {
    final px = Uint8List(w.toInt() * h.toInt() * 4);
    for (var y = 0; y < h.toInt(); y++) {
      for (var x = 0; x < w.toInt(); x++) {
        final o = (y * w.toInt() + x) * 4;
        px[o] = x * 255 ~/ w.toInt();
        px[o + 1] = y * 255 ~/ h.toInt();
        px[o + 2] = 128;
        px[o + 3] = 255;
      }
    }
    return ImageAnalyzer.fromPixels(px, w.toInt(), h.toInt(), w, h);
  }

  /// Every photo the same orientation, so the opposite mode has nothing to draw on.
  List<TileDescriptor> makeTiles(int n, {required bool landscape}) =>
      List.generate(n, (i) {
        final t = i / n;
        return createTileDescriptor(
          't$i',
          't$i',
          landscape ? 150 : 100,
          landscape ? 100 : 150,
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

  for (final c in [
    ('portrait', true), // portrait mode, landscape-only library
    ('landscape', false), // landscape mode, portrait-only library
  ]) {
    test('${c.$1} builds against a library with no matching orientation', () {
      final placements = buildGridLayout(
        baseWidth: w,
        baseHeight: h,
        analyzer: makeAnalyzer(),
        tiles: makeTiles(24, landscape: c.$2),
        settings: defaultSettings()
          ..mosaicMode = c.$1
          ..density = 40,
        faceRegions: const [],
      );

      expect(placements, isNotEmpty);
      for (final p in placements) {
        expect(p.tileId, isNotEmpty);
      }
    });
  }
}
