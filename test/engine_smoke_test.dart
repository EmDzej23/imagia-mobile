import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/shared.dart';

/// Smoke test for the `dart:ui` pixel path: encodes images in-engine, analyzes
/// them into tile descriptors, and runs the whole `buildMosaicPlan` pipeline
/// synchronously (no isolate, which dart:ui doesn't support under flutter_test).
Future<Uint8List> _png(int w, int h, List<Color> bands) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bandH = h / bands.length;
  for (var i = 0; i < bands.length; i++) {
    canvas.drawRect(
        Rect.fromLTWH(0, i * bandH, w.toDouble(), bandH), Paint()..color = bands[i]);
  }
  final img = await recorder.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('buildMosaicPlan produces an in-bounds plan from real decoded images',
      () async {
    final base = await _png(96, 96, const [
      Color(0xFFE03030),
      Color(0xFF30A0E0),
      Color(0xFF30C060),
      Color(0xFFE0C040),
    ]);

    final tileColors = <List<Color>>[
      [const Color(0xFFE03030), const Color(0xFFA01010)],
      [const Color(0xFF30A0E0), const Color(0xFF1060A0)],
      [const Color(0xFF30C060), const Color(0xFF108040)],
      [const Color(0xFFE0C040), const Color(0xFFA08010)],
      [const Color(0xFF888888), const Color(0xFF444444)],
    ];
    final tiles = <dynamic>[];
    for (var i = 0; i < tileColors.length; i++) {
      final bytes = await _png(64, 64, tileColors[i]);
      tiles.add(await analyzeTile('tile-$i', 'tile-$i.jpg', bytes));
    }

    final plan = await buildMosaicPlan(
      baseBytes: base,
      tiles: tiles.cast(),
      rawSettings: defaultSettings().copyWith(mosaicMode: 'square', density: 60),
      isMobile: true,
      useIsolate: false,
    );

    expect(plan.placements, isNotEmpty);
    expect(plan.baseWidth, 96);
    expect(plan.baseHeight, 96);
    for (final p in plan.placements) {
      expect(p.x, greaterThanOrEqualTo(0));
      expect(p.y, greaterThanOrEqualTo(0));
      expect(p.x + p.width, lessThanOrEqualTo(96.0001));
      expect(p.y + p.height, lessThanOrEqualTo(96.0001));
      expect(tiles.any((t) => t.id == p.tileId), isTrue);
    }
  });
}
