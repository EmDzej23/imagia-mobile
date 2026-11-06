import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/cell_recolor_cache.dart';
import 'package:imagia_mobile/mosaic/recolor_bake.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// A cell's sharp zoom copy (CellRecolorCache) must have the same colours as the same
/// cell in the whole-mosaic picture (bakeMosaicWindow) — otherwise cells would visibly
/// change as they sharpen.
void main() {
  testWidgets('cell copies match the whole-mosaic render', (tester) async {
    await tester.runAsync(() async {
      Future<ui.Image> gradient(int seed) async {
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawRect(
          const Rect.fromLTWH(0, 0, 200, 160),
          Paint()
            ..shader = ui.Gradient.linear(Offset.zero, const Offset(200, 160), [
              Color.fromARGB(255, 40 + seed * 50, 120, 200 - seed * 40),
              Color.fromARGB(255, 230, 60 + seed * 40, 30),
            ]),
        );
        return rec.endRecording().toImage(200, 160);
      }

      final tiles = {for (var i = 0; i < 4; i++) 't$i': await gradient(i)};
      final grid = Float64List(75);
      for (var i = 0; i < 75; i++) {
        grid[i] = (i * 37 % 255).toDouble();
      }
      final placements = [
        for (var i = 0; i < 4; i++)
          SlimPlacement(
            index: i,
            x: (i % 2) * 100.0,
            y: (i ~/ 2) * 100.0,
            width: 100,
            height: 100,
            tileId: 't$i',
            regionAvgColor: [90.0 + i * 30, 140, 60],
            regionGrid: grid,
          ),
      ];
      final plan = SlimMosaicPlan(
        baseWidth: 200,
        baseHeight: 200,
        outputWidth: 200,
        outputHeight: 200,
        tintStrength: 0,
        baseBlur: 0,
        placements: placements,
        tileRecolor: 1,
        outputSaturation: 1.2,
      );
      // Whole mosaic at 1.28 px per base px → each cell is 128 px, the tier below.
      final whole = (await bakeMosaicWindow(
        plan: plan,
        tileCrops: const {},
        imageFor: (p, _) => tiles[p.tileId],
        win: const Rect.fromLTWH(0, 0, 200, 200),
        outW: 256,
        outH: 256,
        tileRecolor: 1,
        outputSaturation: 1.2,
      ))!;
      final wholePx = (await whole.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      final cache = CellRecolorCache();
      cache.configure(
          plan: plan, tileImages: tiles, hiRes: null, tileRecolor: 1, outputSaturation: 1.2);
      for (var i = 0; i < 4; i++) {
        cache.want(i, 128);
      }
      for (var tries = 0; tries < 200 && cache.get(3) == null; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      for (final i in [0, 3]) {
        final copy = cache.get(i);
        expect(copy, isNotNull, reason: 'cell $i baked');
        final atlasPx = (await copy!.$1.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final ox = (i % 2) * 128, oy = (i ~/ 2) * 128;
        // Slot origin in the atlas (the rect was inset by half a pixel).
        final sx = (copy.$2.left - 0.5).round(), sy = (copy.$2.top - 0.5).round();
        var worst = 0;
        // Interior pixels (the cell's outer pixel row touches its neighbour on the
        // whole-mosaic canvas, where neighbours share a snapped edge).
        for (var y = 2; y < 126; y += 3) {
          for (var x = 2; x < 126; x += 3) {
            final a = ((oy + y) * 256 + ox + x) * 4;
            final b = ((sy + y) * copy.$1.width + sx + x) * 4;
            for (var ch = 0; ch < 3; ch++) {
              final d = (wholePx.getUint8(a + ch) - atlasPx.getUint8(b + ch)).abs();
              if (d > worst) worst = d;
            }
          }
        }
        expect(worst, lessThanOrEqualTo(2), reason: 'cell $i worst channel difference $worst');
      }
      cache.dispose();
    });
  });
}
