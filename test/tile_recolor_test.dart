import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/tile_recolor.dart';

// Parity with the web/server `tileRecolorLinear` (tile contrast kept since 2026-11-10; half the colour shift since 2026-11-11, recolour v3) (foto-mozaik/lib/mosaic/shared.ts,
// render-service/src/lib/recolor.ts), including the misfit boost
// (`effectiveRecolorStrength`). Expected values were computed by the TypeScript version —
// if this fails, the on-device preview no longer matches the export.
void main() {
  void expectLin(TileRecolor? lin, List<double> mul, List<double> add) {
    expect(lin, isNotNull);
    for (var c = 0; c < 3; c++) {
      expect(lin!.mul[c], closeTo(mul[c], 1e-9), reason: 'mul[$c]');
      expect(lin.add[c], closeTo(add[c], 1e-9), reason: 'add[$c]');
    }
  }

  test('clear misfit at 0.5 → boosted, toned', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [60.0, 80.0, 200.0], 0.5),
      [1, 1, 1],
      [97.56784999999999, 68.11784999999999, 19.667850000000016],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(1, 1e-12));
  });
  test('dark cell, bright tile → darken, toned', () {
    expectLin(
      tileRecolorLinear([20.0, 30.0, 40.0], [180.0, 160.0, 140.0], 0.5),
      [0.20893876207199308, 0.21487978501563978, 0.22177692988573575],
      [0, 0, 0],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(1, 1e-12));
  });
  test('close fit → shift (tile contrast kept)', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [190.0, 140.0, 110.0], 0.5),
      [1, 1, 1],
      [9.454999999999984, 4.454999999999984, 1.4549999999999983],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(1, 1e-12));
  });
  test('full strength', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [60.0, 80.0, 200.0], 1),
      [1, 1, 1],
      [102.703, 71.70299999999999, 20.703000000000003],
    );
    final tn = tileToning(1);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(1, 1e-12));
  });
  test('half toning and half misfit boost below 0.5', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [60.0, 80.0, 200.0], 0.25),
      [1, 1, 1],
      [62.885400000000004, 43.08540000000001, 5.28540000000001],
    );
    final tn = tileToning(0.25);
    expect(tn.saturation, closeTo(0.8, 1e-12));
    expect(tn.contrast, closeTo(1, 1e-12));
  });

  test('already matching → nothing to do (tile contrast kept)', () {
    expect(tileRecolorLinear([128, 128, 128], [128, 128, 128], 0.5), isNull);
  });

  test('off at strength 0, even for a misfit', () {
    expect(tileRecolorLinear([255, 0, 0], [0, 0, 255], 0), isNull);
  });
}
