import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/types.dart';
import 'package:imagia_mobile/services/tile_analysis_cache.dart';

/// Reopening a project reads each tile's analysis from disk instead of analysing it
/// again. A plan built from the cached analysis must be the plan built from a fresh
/// one, so the descriptor has to come back EXACTLY — every double, bit for bit.
Future<Uint8List> _synth(int w, int h, int seed) async {
  final r = math.Random(seed);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Color.fromARGB(255, r.nextInt(256), r.nextInt(256), r.nextInt(256)));
  for (var i = 0; i < 20; i++) {
    c.drawCircle(Offset(r.nextDouble() * w, r.nextDouble() * h), 10 + r.nextDouble() * 80,
        Paint()..color = Color.fromARGB(200, r.nextInt(256), r.nextInt(256), r.nextInt(256)));
  }
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return png!.buffer.asUint8List();
}

void main() {
  test('fixture descriptors survive the JSON round trip exactly', () {
    final fx = jsonDecode(File('test/fixtures/fidelity_core.json').readAsStringSync()) as Map;
    final tiles = (fx['tiles'] as List)
        .map((e) => TileDescriptor.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    expect(tiles, isNotEmpty);
    for (final t in tiles) {
      final once = jsonEncode(t.toJson());
      final back = TileDescriptor.fromJson((jsonDecode(once) as Map).cast<String, dynamic>());
      expect(jsonEncode(back.toJson()), once);
    }
  });

  testWidgets('an analysed tile reads back from the cache bit for bit', (tester) async {
    final dir = Directory.systemTemp.createTempSync('tile-analysis-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TileAnalysisCache.debugUseDirectory(dir);

    await tester.runAsync(() async {
      final bytes = await _synth(256, 192, 7);
      final fresh = await analyzeTileWithThumbnail('t1', 'a.jpg', bytes);
      final grid = Uint8List.fromList(List.generate(16 * 16 * 4, (i) => i % 251));
      await TileAnalysisCache.write('https://x/a.jpg', 256, fresh.descriptor, grid, bytes);

      final got = await TileAnalysisCache.read('https://x/a.jpg', 256, 't1', 'a.jpg');
      expect(got, isNotNull);
      expect(jsonEncode(got!.descriptor.toJson()), jsonEncode(fresh.descriptor.toJson()));
      expect(got.descriptor.subregionEdgeOrientations, isA<Float32List>());
      expect(got.descriptor.subregionEdgeOrientations, fresh.descriptor.subregionEdgeOrientations);
      expect(got.grid, grid);
      expect(got.thumbBytes, bytes);

      // Same thumbnail size as a fresh analysis makes.
      final thumb = await decodeTileThumbnail(got.thumbBytes);
      expect((thumb.width, thumb.height), (fresh.thumbnail.width, fresh.thumbnail.height));

      // Anything else in the key misses: another size, id, name or photo.
      expect(await TileAnalysisCache.read('https://x/a.jpg', 300, 't1', 'a.jpg'), isNull);
      expect(await TileAnalysisCache.read('https://x/a.jpg', 256, 't2', 'a.jpg'), isNull);
      expect(await TileAnalysisCache.read('https://x/a.jpg', 256, 't1', 'b.jpg'), isNull);
      expect(await TileAnalysisCache.read('https://x/b.jpg', 256, 't1', 'a.jpg'), isNull);
    });
  });
}
