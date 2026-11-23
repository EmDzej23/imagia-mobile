// Studio preview timing, step by step, on a real device or emulator. No backend.
//
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/studio_perf_test.dart -d <device>
//
// Synthetic photos (a base and PERF_TILES tiles) so it runs anywhere; prints PERF lines.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:imagia_mobile/mosaic/local_recolor.dart';
import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/preview_painter.dart';
import 'package:imagia_mobile/mosaic/recolor_bake.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

const _tileCount = int.fromEnvironment('PERF_TILES', defaultValue: 150);

/// A photo-ish synthetic image: soft blobs + noise, encoded as PNG.
Future<Uint8List> _synth(int w, int h, int seed) async {
  final r = math.Random(seed);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = Color.fromARGB(255, r.nextInt(256), r.nextInt(256), r.nextInt(256)),
  );
  for (var i = 0; i < 14; i++) {
    c.drawCircle(
      Offset(r.nextDouble() * w, r.nextDouble() * h),
      (0.1 + r.nextDouble() * 0.4) * math.max(w, h),
      Paint()
        ..color = Color.fromARGB(200, r.nextInt(256), r.nextInt(256), r.nextInt(256))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );
  }
  for (var i = 0; i < 300; i++) {
    c.drawRect(
      Rect.fromLTWH(r.nextDouble() * w, r.nextDouble() * h, 4 + r.nextDouble() * 30, 2 + r.nextDouble() * 10),
      Paint()..color = Color.fromARGB(160, r.nextInt(256), r.nextInt(256), r.nextInt(256)),
    );
  }
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return png!.buffer.asUint8List();
}

/// Top-level, so the isolate closure carries only its arguments.
Future<Uint8List> _recolor(Uint8List data, int w, int h, List<RecolorCell> cells) =>
    Isolate.run(() {
      applyLocalRecolor(data, w, h, cells, 1, outputSaturation: 1);
      return data;
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('studio preview timing', (tester) async {
    await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      void lap(String what) {
        debugPrint('PERF $what ${sw.elapsedMilliseconds} ms');
        sw.reset();
      }

      final baseBytes = await _synth(2000, 1500, 1);
      final tileBytes = [for (var i = 0; i < _tileCount; i++) await _synth(800, 600, 100 + i)];
      lap('synth (setup, ignore)');

      final tiles = <TileDescriptor>[];
      final thumbs = <String, ui.Image>{};
      for (var i = 0; i < tileBytes.length; i++) {
        final r = await analyzeTileWithThumbnail('t$i', 't$i.png', tileBytes[i]);
        tiles.add(r.descriptor);
        thumbs['t$i'] = r.thumbnail;
      }
      lap('analyse $_tileCount tiles');

      final settings = defaultSettings();
      final plan = await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings);
      lap('plan (density ${settings.density.round()}, ${plan.placements.length} cells)');
      final again = await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings);
      lap('plan again');
      final tweaked = settings.copyWith(density: 150);
      await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: tweaked);
      lap('plan, density 150 (same photo analysis)');
      final direct = await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings, useIsolate: false);
      lap('plan on this isolate (check)');
      var same = direct.placements.length == again.placements.length;
      for (var i = 0; same && i < direct.placements.length; i++) {
        final x = direct.placements[i], y = again.placements[i];
        same = x.tileId == y.tileId && x.x == y.x && x.y == y.y && x.width == y.width;
      }
      debugPrint('PERF worker plan identical to direct plan: $same');
      expect(same, isTrue);

      // Draft first (forced on: threshold 0), then the finished plan — which must be
      // exactly the plan built without a draft.
      SlimMosaicPlan? draft;
      var draftMs = 0;
      final dsw = Stopwatch()..start();
      final withDraft = await buildMosaicPlan(
        baseBytes: baseBytes,
        tiles: tiles,
        rawSettings: settings,
        draftAfterMs: 0,
        onDraft: (d) {
          draft = d;
          draftMs = dsw.elapsedMilliseconds;
        },
      );
      lap('plan with draft (draft after $draftMs ms)');
      var sameFinal = withDraft.placements.length == again.placements.length;
      for (var i = 0; sameFinal && i < again.placements.length; i++) {
        final x = withDraft.placements[i], y = again.placements[i];
        sameFinal = x.tileId == y.tileId && x.x == y.x && x.y == y.y && x.width == y.width;
      }
      debugPrint('PERF draft cells ${draft?.placements.length}; final identical: $sameFinal');
      expect(draft, isNotNull);
      expect(draft!.placements.length, again.placements.length);
      expect(sameFinal, isTrue);

      // The recoloured whole-mosaic picture, step by step (bakeMosaicWindow).
      for (final side in [1024, 2048, 4096]) {
        final k = side / math.max(plan.baseWidth, plan.baseHeight);
        final w = (plan.baseWidth * k).round(), h = (plan.baseHeight * k).round();
        final size = Size(w.toDouble(), h.toDouble());
        final rec = ui.PictureRecorder();
        final cells = drawPlanWindow(Canvas(rec, Offset.zero & size), plan, plan.tileCrops, k, Offset.zero, size,
            imageFor: (p, _) => thumbs[p.tileId]);
        final pic = rec.endRecording();
        lap('bake $side: record');
        final raw = await pic.toImage(w, h);
        pic.dispose();
        lap('bake $side: toImage');
        final bd = await raw.toByteData(format: ui.ImageByteFormat.rawRgba);
        raw.dispose();
        lap('bake $side: toByteData');
        final input = bd!.buffer.asUint8List();
        final out = await _recolor(input, w, h, cells);
        lap('bake $side: recolour (isolate)');
        final buffer = await ui.ImmutableBuffer.fromUint8List(out);
        final desc = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
        final codec = await desc.instantiateCodec();
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        lap('bake $side: upload');
      }

      // Whole bake through the real entry point, for the total.
      for (final side in [1024, 4096]) {
        final k = side / math.max(plan.baseWidth, plan.baseHeight);
        final img = await bakeMosaicWindow(
          plan: plan,
          tileCrops: plan.tileCrops,
          imageFor: (p, _) => thumbs[p.tileId],
          win: Rect.fromLTWH(0, 0, plan.baseWidth, plan.baseHeight),
          outW: (plan.baseWidth * k).round(),
          outH: (plan.baseHeight * k).round(),
          tileRecolor: 1,
          outputSaturation: 1,
        );
        img?.dispose();
        lap('bakeMosaicWindow $side total');
      }

      // The live painter at a phone preview size (what sits under the picture).
      final rec = ui.PictureRecorder();
      const pv = Size(1200, 900);
      MosaicPreviewPainter(plan: plan, tileImages: thumbs).paint(Canvas(rec, Offset.zero & pv), pv);
      final img = await rec.endRecording().toImage(1200, 900);
      await img.toByteData();
      img.dispose();
      lap('live painter 1200x900 (record+raster)');
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
