import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/tile_recolor.dart';

// Parity with the web/server `tileRecolorLinear` (foto-mozaik/lib/mosaic/shared.ts,
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
      [0.82, 0.82, 0.7914537697070608],
      [136.29095999999998, 79.55096000000002, 0],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(0.82, 1e-12));
  });
  test('dark cell, bright tile → darken, toned', () {
    expectLin(
      tileRecolorLinear([20.0, 30.0, 40.0], [180.0, 160.0, 140.0], 0.5),
      [0.15974539069359098, 0.22687801002929353, 0.3048146558661016],
      [0, 0, 0],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(0.82, 1e-12));
  });
  test('close fit → softer contrast + shift', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [190.0, 140.0, 110.0], 0.5),
      [0.82, 0.82, 0.82],
      [44.51328000000001, 29.113280000000003, 19.87328000000001],
    );
    final tn = tileToning(0.5);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(0.82, 1e-12));
  });
  test('full strength', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [60.0, 80.0, 200.0], 1),
      [0.82, 0.82, 0.7804776523232219],
      [142.80336, 82.96336000000001, 0],
    );
    final tn = tileToning(1);
    expect(tn.saturation, closeTo(0.6, 1e-12));
    expect(tn.contrast, closeTo(0.82, 1e-12));
  });
  test('half toning and half misfit boost below 0.5', () {
    expectLin(
      tileRecolorLinear([200.0, 150.0, 120.0], [60.0, 80.0, 200.0], 0.25),
      [0.9099999999999999, 0.9099999999999999, 0.8070648363825506],
      [86.91324000000002, 48.753240000000005, 0],
    );
    final tn = tileToning(0.25);
    expect(tn.saturation, closeTo(0.8, 1e-12));
    expect(tn.contrast, closeTo(0.9099999999999999, 1e-12));
  });

  test('already matching → only the contrast softening', () {
    final lin = tileRecolorLinear([128, 128, 128], [128, 128, 128], 0.5)!;
    for (var c = 0; c < 3; c++) {
      expect(lin.mul[c], closeTo(0.82, 1e-9));
      expect(lin.add[c], closeTo(128 * 0.18, 1e-6));
    }
  });

  test('off at strength 0, even for a misfit', () {
    expect(tileRecolorLinear([255, 0, 0], [0, 0, 255], 0), isNull);
  });
}
