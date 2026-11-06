import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/local_recolor.dart';

/// The app's in-cell tile recolour must give the SAME pixels as the web studio
/// (fixture from foto-mozaik/scripts/local-recolor-fidelity-gen.ts, which runs the
/// real web applyLocalRecolor): rect cells overlapping by a pixel, cells without a
/// photo grid, honeycomb + cube cells (masks, face shade), several strengths, with and
/// without the saturation grade.
void main() {
  test('applyLocalRecolor matches the web byte for byte', () {
    final fx = jsonDecode(File('test/fixtures/local_recolor.json').readAsStringSync())
        as Map<String, dynamic>;
    final w = fx['W'] as int, h = fx['H'] as int;
    final base = base64Decode(fx['base'] as String);
    final cells = [
      for (final c in (fx['cells'] as List).cast<Map<String, dynamic>>())
        RecolorCell(
          x: (c['x'] as num).toDouble(),
          y: (c['y'] as num).toDouble(),
          w: (c['w'] as num).toDouble(),
          h: (c['h'] as num).toDouble(),
          avg: [for (final v in c['avg'] as List) (v as num).toDouble()],
          grid: c['sub'] == null
              ? null
              : labGridToRgb([
                  for (final l in c['sub'] as List)
                    [for (final v in l as List) (v as num).toDouble()]
                ]),
          mask: c['mask'] == null
              ? null
              : (c['mask']['hex'] != null
                  ? HexMask(
                      (c['mask']['hex'][0] as num).toDouble(),
                      (c['mask']['hex'][1] as num).toDouble(),
                      (c['mask']['hex'][2] as num).toDouble(),
                      (c['mask']['hex'][3] as num).toDouble())
                  : QuadMask([for (final v in c['mask']['quad'] as List) (v as num).toDouble()])),
          shade: (c['shade'] as num?)?.toDouble() ?? 1,
        ),
    ];
    for (final cs in (fx['cases'] as List).cast<Map<String, dynamic>>()) {
      final data = Uint8List.fromList(base);
      applyLocalRecolor(data, w, h, cells, (cs['strength'] as num).toDouble(),
          outputSaturation: (cs['saturation'] as num).toDouble());
      final want = base64Decode(cs['out'] as String);
      var diff = 0, worst = 0;
      for (var i = 0; i < want.length; i++) {
        final d = (data[i] - want[i]).abs();
        if (d > 0) diff++;
        if (d > worst) worst = d;
      }
      expect(worst, 0,
          reason: 'strength ${cs['strength']} sat ${cs['saturation']}: '
              '$diff bytes differ, worst $worst');
    }
  });
}
