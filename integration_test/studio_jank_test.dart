// Frame smoothness while a preview builds, on a real device. No backend.
//
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/studio_jank_test.dart -d <device>
//
// Prints JANK lines: UI (build) and raster times per frame for each scene.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/preview_painter.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/snapshot_paint.dart';
import 'package:imagia_mobile/mosaic/types.dart';

const _tileCount = int.fromEnvironment('PERF_TILES', defaultValue: 150);

Future<Uint8List> _synth(int w, int h, int seed) async {
  final r = math.Random(seed);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = Color.fromARGB(255, r.nextInt(256), r.nextInt(256), r.nextInt(256)),
  );
  for (var i = 0; i < 40; i++) {
    c.drawCircle(
      Offset(r.nextDouble() * w, r.nextDouble() * h),
      (0.05 + r.nextDouble() * 0.3) * math.max(w, h),
      Paint()..color = Color.fromARGB(200, r.nextInt(256), r.nextInt(256), r.nextInt(256)),
    );
  }
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return png!.buffer.asUint8List();
}

class _Scene extends StatelessWidget {
  const _Scene({
    required this.plan,
    required this.thumbs,
    required this.spinner,
    this.snapshot = false,
    this.appear = 1,
    this.recolor,
  });
  final SlimMosaicPlan? plan;
  final Map<String, ui.Image> thumbs;
  final bool spinner;
  final bool snapshot;
  final double appear;
  final double? recolor;

  Widget _mosaic() {
    final p = MosaicPreviewPainter(
      plan: plan!,
      tileImages: thumbs,
      tintStrength: 0,
      appear: appear,
      tileRecolor: recolor,
    );
    if (!snapshot) return CustomPaint(painter: p);
    return SnapshotPaint(
      painter: MosaicPreviewPainter(plan: plan!, tileImages: thumbs, tintStrength: 0, tileRecolor: recolor),
      appear: appear,
      pieces: (size) => previewCellRects(plan!, size),
      place: revealCell,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (plan != null)
            Positioned.fill(
              child: RepaintBoundary(child: _mosaic()),
            ),
          if (spinner)
            const Positioned(
              top: 20,
              right: 20,
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    ),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('frames while building', (tester) async {
    final timings = <FrameTiming>[];
    void onTimings(List<FrameTiming> t) => timings.addAll(t);

    Future<void> measure(String what, Future<void> Function() during) async {
      timings.clear();
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      await during();
      await tester.pump(const Duration(milliseconds: 100));
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      if (timings.isEmpty) {
        debugPrint('JANK $what: no frames');
        return;
      }
      List<int> ms(Duration Function(FrameTiming) f) =>
          (timings.map((t) => f(t).inMicroseconds ~/ 1000).toList()..sort());
      final b = ms((t) => t.buildDuration), r = ms((t) => t.rasterDuration);
      final total = ms((t) => t.totalSpan);
      int p(List<int> v, double q) => v[math.min(v.length - 1, (v.length * q).floor())];
      debugPrint(
        'JANK $what: ${timings.length} frames · build p50 ${p(b, .5)} p90 ${p(b, .9)} max ${b.last} ms'
        ' · raster p50 ${p(r, .5)} p90 ${p(r, .9)} max ${r.last} ms'
        ' · total max ${total.last} ms · >100ms: ${total.where((v) => v > 100).length}',
      );
    }

    // Run frames for [d] while [work] proceeds (real time, real vsync).
    Future<void> frames(Duration d, [Future<void>? work]) async {
      final end = DateTime.now().add(d);
      var done = work == null;
      work?.whenComplete(() => done = true);
      while (DateTime.now().isBefore(end) || !done) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      }
    }

    late Uint8List baseBytes;
    final tiles = <TileDescriptor>[];
    final thumbs = <String, ui.Image>{};
    await tester.runAsync(() async {
      baseBytes = await _synth(2000, 1500, 1);
      for (var i = 0; i < _tileCount; i++) {
        final r = await analyzeTileWithThumbnail('t$i', 't$i.png', await _synth(600, 450, 100 + i));
        tiles.add(r.descriptor);
        thumbs['t$i'] = r.thumbnail;
      }
    });
    final settings = defaultSettings();
    late SlimMosaicPlan plan;
    await tester.runAsync(() async {
      plan = await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings);
    });
    debugPrint('JANK setup done, ${plan.placements.length} cells');

    await tester.pumpWidget(const _Scene(plan: null, thumbs: {}, spinner: true));
    await measure('spinner only, idle', () => frames(const Duration(seconds: 3)));

    await measure('spinner only, plan building', () async {
      Future<void>? work;
      await tester.runAsync(() async {
        work = buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings.copyWith(density: 150));
      });
      await frames(const Duration(seconds: 1), work);
    });

    await tester.pumpWidget(_Scene(plan: plan, thumbs: thumbs, spinner: false));
    await measure('mosaic, static', () => frames(const Duration(seconds: 3)));

    await tester.pumpWidget(_Scene(plan: plan, thumbs: thumbs, spinner: true));
    await measure('mosaic + spinner, idle', () => frames(const Duration(seconds: 3)));

    await measure('mosaic + spinner, plan building', () async {
      Future<void>? work;
      await tester.runAsync(() async {
        work = buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings.copyWith(density: 170));
      });
      await frames(const Duration(seconds: 1), work);
    });

    await tester.pumpWidget(_Scene(plan: plan, thumbs: thumbs, spinner: true, recolor: 0));
    await measure('mosaic (no recolour) + spinner', () => frames(const Duration(seconds: 3)));

    await tester.pumpWidget(_Scene(plan: plan, thumbs: thumbs, spinner: true, snapshot: true));
    await measure('SNAPSHOT mosaic + spinner, idle', () => frames(const Duration(seconds: 3)));

    await measure('SNAPSHOT mosaic + spinner, plan building', () async {
      Future<void>? work;
      await tester.runAsync(() async {
        work = buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings.copyWith(density: 160));
      });
      await frames(const Duration(seconds: 1), work);
    });

    for (final snap in [false, true]) {
      await measure('drift reveal (${snap ? 'SNAPSHOT atlas' : 'live painter'})', () async {
        for (var t = 0.0; t < 1; t += 1 / 66) {
          await tester.pumpWidget(_Scene(plan: plan, thumbs: thumbs, spinner: false, appear: t, snapshot: snap));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
        }
      });
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
