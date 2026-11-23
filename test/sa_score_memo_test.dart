import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/matching.dart' show debugSaMemoMaxEntries;
import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// SA remembers the swap scores it has computed (matching.dart, `scoreAt`). That must
/// be invisible: the same plan, tile for tile and score for score, as recomputing.
/// Mixed tile shapes on purpose — orientation-illegal pairings take a separate path.
Future<Uint8List> _synth(int w, int h, int seed) async {
  final r = math.Random(seed);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Color.fromARGB(255, r.nextInt(256), r.nextInt(256), r.nextInt(256)));
  for (var i = 0; i < 25; i++) {
    c.drawCircle(Offset(r.nextDouble() * w, r.nextDouble() * h),
        (0.05 + r.nextDouble() * 0.3) * math.max(w, h),
        Paint()..color = Color.fromARGB(200, r.nextInt(256), r.nextInt(256), r.nextInt(256)));
  }
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return png!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remembered SA scores build exactly the recomputed plan', () async {
    final base = await _synth(480, 360, 1);
    final tiles = <TileDescriptor>[];
    const shapes = [(300, 400), (400, 300), (350, 350)];
    for (var i = 0; i < 36; i++) {
      final (w, h) = shapes[i % 3];
      tiles.add(await analyzeTile('t$i', 't$i.jpg', await _synth(w, h, 100 + i)));
    }

    Future<List<String>> build(MosaicSettings s, int? memo) async {
      debugSaMemoMaxEntries = memo;
      try {
        final plan = await buildMosaicPlan(
            baseBytes: base, tiles: tiles, rawSettings: s, isMobile: true, useIsolate: false);
        return [for (final p in plan.placements) '${p.tileId}@${p.x},${p.y},${p.width},${p.height}'];
      } finally {
        debugSaMemoMaxEntries = null;
      }
    }

    final d = defaultSettings();
    final cases = <String, MosaicSettings>{
      'original': d.copyWith(mosaicMode: 'original', density: 40),
      'blocks': d.copyWith(mosaicMode: 'blocks', density: 40),
      'square': d.copyWith(mosaicMode: 'square', density: 40),
      'portrait': d.copyWith(mosaicMode: 'portrait', density: 40),
      'landscape': d.copyWith(mosaicMode: 'landscape', density: 40),
      'no reuse penalty': d.copyWith(mosaicMode: 'square', density: 40, reusePenalty: 0),
    };
    for (final e in cases.entries) {
      final sw0 = Stopwatch()..start();
      final plain = await build(e.value, 0);
      final tPlain = sw0.elapsedMilliseconds;
      final sw1 = Stopwatch()..start();
      final memo = await build(e.value, null);
      final tMemo = sw1.elapsedMilliseconds;
      // ignore: avoid_print
      print('${e.key}: ${plain.length} cells · recompute $tPlain ms · remembered $tMemo ms');
      expect(memo, plain, reason: e.key);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
