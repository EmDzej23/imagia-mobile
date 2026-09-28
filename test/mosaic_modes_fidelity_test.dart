import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Fidelity across EVERY photo layout, not just square.
///
/// `mosaic_grid_layout_test.dart` pins one mode end-to-end, which says a lot about the
/// scorer and very little about the layouts — those differ from each other far more
/// than the scorer does, and each one partitions the base image its own way. A mode
/// with no reference is free to drift from web with nothing to notice.
///
/// Same synthetic base bytes and same library for every mode, so the only variable is
/// the layout itself.
void main() {
  final fixture = jsonDecode(
          File('test/fixtures/fidelity_core.json').readAsStringSync())
      as Map<String, dynamic>;

  final tiles = (fixture['tiles'] as List)
      .map((e) => TileDescriptor.fromJson((e as Map).cast<String, dynamic>()))
      .toList();
  final gl = (fixture['gridLayout'] as Map).cast<String, dynamic>();
  final baseWidth = (gl['baseWidth'] as num).toDouble();
  final baseHeight = (gl['baseHeight'] as num).toDouble();
  final pixels = base64Decode(gl['basePixelsB64'] as String);

  for (final entry in (fixture['gridLayoutModes'] as List)) {
    final m = (entry as Map).cast<String, dynamic>();
    final mode = m['mode'] as String;

    test('$mode reproduces the web plan placement-for-placement', () {
      final settings = MosaicSettings.fromJson(
          (m['settings'] as Map).cast<String, dynamic>());
      final analyzer = ImageAnalyzer.fromPixels(
        Uint8List.fromList(pixels),
        baseWidth.toInt(),
        baseHeight.toInt(),
        baseWidth,
        baseHeight,
        colorBoost: settings.colorBoost,
        autoContrast: settings.autoContrast,
      );

      final got = buildGridLayout(
        baseWidth: baseWidth,
        baseHeight: baseHeight,
        analyzer: analyzer,
        tiles: tiles,
        settings: settings,
        isMobile: false,
      );
      final ref = (m['placements'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

      expect(got.length, ref.length, reason: '$mode placement count');

      var tileMismatches = 0;
      for (var i = 0; i < got.length; i++) {
        final p = got[i];
        final r = ref[i];
        expect(p.x, closeTo((r['x'] as num).toDouble(), 1e-9), reason: '$mode x @$i');
        expect(p.y, closeTo((r['y'] as num).toDouble(), 1e-9), reason: '$mode y @$i');
        expect(p.width, closeTo((r['width'] as num).toDouble(), 1e-9),
            reason: '$mode width @$i');
        expect(p.height, closeTo((r['height'] as num).toDouble(), 1e-9),
            reason: '$mode height @$i');
        // Cubes are parallelograms and hexagons are masked: the rect fields alone
        // would compare equal while the drawn shape was completely different.
        expect(p.face, r['face'], reason: '$mode face @$i');
        final refQuad = r['quad'] as List?;
        if (refQuad == null) {
          expect(p.quad, isNull, reason: '$mode quad @$i');
        } else {
          expect(p.quad, isNotNull, reason: '$mode quad missing @$i');
          for (var k = 0; k < refQuad.length; k++) {
            expect(p.quad![k], closeTo((refQuad[k] as num).toDouble(), 1e-9),
                reason: '$mode quad[$k] @$i');
          }
        }
        if (p.tileId != r['tileId']) tileMismatches++;
      }

      // Identity is reported; QUALITY is asserted.
      //
      // `original` contains many exact score ties — a colour-reject cap flattens whole
      // groups of tiles onto the same value — and whichever tied photo wins first then
      // shifts the usage counts, so one tie cascades into a different-but-equally-good
      // arrangement downstream. Demanding the same photo in every cell would therefore
      // fail on a difference that is not a difference in output quality.
      //
      // What must NOT drift is how WELL the cells are matched. A real regression —
      // a starved pool, a lost signal, a broken penalty — moves the mean, which this
      // catches. (When this was written `original` sat 0.8% BELOW web, i.e. slightly
      // better; the other five modes were bit-exact at 0.000%.)
      var dartMean = 0.0, webMean = 0.0;
      for (final p in got) {
        dartMean += p.score;
      }
      for (final r in ref) {
        webMean += (r['score'] as num).toDouble();
      }
      dartMean /= got.length;
      webMean /= ref.length;
      expect(dartMean, lessThanOrEqualTo(webMean * 1.01),
          reason: '$mode matches WORSE than web '
              '(dart ${dartMean.toStringAsFixed(6)} vs web ${webMean.toStringAsFixed(6)})');
      if (tileMismatches > 0) {
        // ignore: avoid_print
        print('  $mode: $tileMismatches/${got.length} cells differ by tie-break; '
            'mean score ${((dartMean / webMean - 1) * 100).toStringAsFixed(3)}% vs web');
      }
    });
  }
}
