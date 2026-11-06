import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/tone_fit.dart';

/// Parity with the web's `lightFitCurve` (lib/mosaic/tone-fit.ts). Fixture written by
/// foto-mozaik `scripts/tone-fit-fidelity-gen.ts`.
void main() {
  final cases = (jsonDecode(File('test/fixtures/tone_fit.json').readAsStringSync())
          as List)
      .cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('light fit curve matches web: ${c['name']}', () {
      List<double> nums(String k) =>
          (c[k] as List).map((v) => (v as num).toDouble()).toList();
      final curve = lightFitCurve(nums('photo'), nums('library'));
      final values = c['values'] as List?;
      if (values == null) {
        expect(curve, isNull);
        return;
      }
      expect(curve, isNotNull);
      final samples = nums('samples');
      for (var i = 0; i < samples.length; i++) {
        expect(
          curve!(samples[i]),
          closeTo((values[i] as num).toDouble(), 1e-9),
          reason: 'L=${samples[i]}',
        );
      }
    });
  }
}
