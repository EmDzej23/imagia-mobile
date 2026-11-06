import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/recolor_bake.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// The whole-mosaic recolour runs in a background isolate for real mosaics (≥ 64
/// cells). Nothing unsendable (images, the tile lookup) may ride along into it.
void main() {
  testWidgets('bakeMosaicWindow works on the isolate path', (tester) async {
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = const Color(0xFF8040C0));
      final tile = await rec.endRecording().toImage(64, 64);
      final placements = [
        for (var i = 0; i < 100; i++)
          SlimPlacement(
            index: i,
            x: (i % 10) * 20.0,
            y: (i ~/ 10) * 20.0,
            width: 20,
            height: 20,
            tileId: 't',
            regionAvgColor: [200, 120, 40],
          ),
      ];
      final plan = SlimMosaicPlan(
        baseWidth: 200, baseHeight: 200, outputWidth: 200, outputHeight: 200,
        tintStrength: 0, baseBlur: 0, placements: placements, tileRecolor: 1,
      );
      final img = await bakeMosaicWindow(
        plan: plan,
        tileCrops: const {},
        imageFor: (p, _) => tile,
        win: const Rect.fromLTWH(0, 0, 200, 200),
        outW: 800,
        outH: 800,
        tileRecolor: 1,
        outputSaturation: 1,
      );
      expect(img, isNotNull);
      final px = (await img!.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Recoloured toward the warm region colour (the tile is purple).
      final i = (400 * 800 + 410) * 4;
      expect(px.getUint8(i), greaterThan(px.getUint8(i + 2)));
    });
  });
}
