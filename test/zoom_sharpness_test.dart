import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/cell_recolor_cache.dart';
import 'package:imagia_mobile/mosaic/hires_tiles.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Deep zoom must end with EVERY cell on screen sharp — including cells first drawn
/// from a thumbnail while their photo was still downloading, and cells whose download
/// failed once. (Both used to stay blurry until the next pinch, or for good.)
void main() {
  Future<ui.Image> photo(int w, int h, int seed) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(w.toDouble(), h.toDouble()), [
          Color.fromARGB(255, 40 + seed * 50, 120, 200 - seed * 40),
          Color.fromARGB(255, 230, 60 + seed * 40, 30),
        ]),
    );
    return rec.endRecording().toImage(w, h);
  }

  Future<Uint8List> png(ui.Image img) async =>
      (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

  testWidgets('cells made from thumbnails are remade sharp when the photos land',
      (tester) async {
    await tester.runAsync(() async {
      // Thumbnails 100×80; stored photos 800×640.
      final thumbs = {for (var i = 0; i < 4; i++) 't$i': await photo(100, 80, i)};
      final stored = {for (var i = 0; i < 4; i++) 't$i': await png(await photo(800, 640, i))};
      var t1Fails = 1; // t1's first download fails (a network blip)
      final hiRes = HiResTiles(
        fetch: (id) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (id == 't1' && t1Fails-- > 0) throw Exception('network');
          return stored[id];
        },
      );
      final grid = Float64List(75)..fillRange(0, 75, 128);
      final plan = SlimMosaicPlan(
        baseWidth: 200,
        baseHeight: 200,
        outputWidth: 200,
        outputHeight: 200,
        tintStrength: 0,
        baseBlur: 0,
        tileRecolor: 1,
        placements: [
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
        ],
      );

      final cache = CellRecolorCache();
      cache.configure(
        plan: plan,
        tileImages: thumbs,
        hiRes: hiRes,
        tileRecolor: 1,
        outputSaturation: 1,
      );
      // The painter: every repaint asks for every cell on screen at 600 device px.
      void paint() {
        for (var i = 0; i < 4; i++) {
          cache.want(i, 600);
        }
      }

      cache.addListener(paint);
      paint();

      // Square cells from 800×640 photos: 640 px of detail, so the 1024 tier, made
      // from the full 640 — not the thumbnail's 80.
      bool allSharp() => [
        for (var i = 0; i < 4; i++) cache.qualityOf(i) ?? 0,
      ].every((q) => q >= 600);
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!allSharp() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(
        [for (var i = 0; i < 4; i++) cache.qualityOf(i)],
        everyElement(greaterThanOrEqualTo(600)),
        reason: 'every cell remade from its sharp photo (t1 after a retry)',
      );
      // Settled: further repaints ask for nothing more (no endless re-baking).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      var bakes = 0;
      void count() => bakes++;
      cache.addListener(count);
      for (var k = 0; k < 5; k++) {
        paint();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(bakes, 0, reason: 'no re-bakes once every cell is sharp');
      cache.removeListener(count);
      cache.removeListener(paint);
      cache.dispose();
      hiRes.dispose();
    });
  });

  testWidgets('a sharp copy is kept while a sharper one loads; full photo is final',
      (tester) async {
    await tester.runAsync(() async {
      final bytes = await png(await photo(700, 500, 1));
      var fetches = 0;
      final hiRes = HiResTiles(
        fetch: (id) async {
          fetches++;
          return bytes;
        },
      );
      Future<void> settle() async {
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      hiRes.want('a', 200); // decoded at the 256 tier
      await settle();
      expect(hiRes.best('a')!.width, 256);
      // Deeper zoom: needs more; the 256 copy is still handed out meanwhile.
      expect(hiRes.get('a', 900), isNull);
      hiRes.want('a', 900);
      expect(hiRes.best('a'), isNotNull);
      await settle();
      // The photo is only 700 px: that is all there is, and nothing is fetched again.
      expect(hiRes.best('a')!.width, 700);
      expect(hiRes.exhausted('a'), isTrue);
      expect(hiRes.get('a', 2000), isNotNull);
      final before = fetches;
      hiRes.want('a', 2000);
      await settle();
      expect(fetches, before);
      hiRes.dispose();
    });
  });
}
