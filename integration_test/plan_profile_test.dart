// CPU profile of the plan build on a real device. No backend.
//
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/plan_profile_test.dart -d <device>
//
// Builds the plan on this isolate (so one isolate holds every sample) and prints the
// hottest functions: PROF self% / total% name.

// ignore_for_file: depend_on_referenced_packages
import 'dart:developer' as dev;
import 'dart:isolate' show Isolate;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vm_service/vm_service.dart' hide Isolate;
import 'package:vm_service/vm_service_io.dart';

import 'package:imagia_mobile/mosaic/mosaic_engine.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plan profile', (tester) async {
    await tester.runAsync(() async {
      final baseBytes = await _synth(2000, 1500, 1);
      final tiles = <TileDescriptor>[];
      for (var i = 0; i < _tileCount; i++) {
        tiles.add(await analyzeTile('t$i', 't$i.png', await _synth(600, 450, 100 + i)));
      }
      final settings = defaultSettings();
      // Warm up (analyzer caches, code paths).
      await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings, useIsolate: false);

      final info = await dev.Service.getInfo();
      final http = info.serverUri!;
      final ws = http.replace(scheme: 'ws', path: '${http.path}ws');
      final vm = await vmServiceConnectUri(ws.toString());
      final iso = dev.Service.getIsolateId(Isolate.current)!;
      await vm.clearCpuSamples(iso);
      final t0 = (await vm.getVMTimelineMicros()).timestamp!;

      final sw = Stopwatch()..start();
      await buildMosaicPlan(baseBytes: baseBytes, tiles: tiles, rawSettings: settings, useIsolate: false);
      debugPrint('PROF plan ${sw.elapsedMilliseconds} ms');

      final t1 = (await vm.getVMTimelineMicros()).timestamp!;
      final cs = await vm.getCpuSamples(iso, t0, t1 - t0);
      final fns = cs.functions!;
      String name(int i) {
        final f = fns[i].function;
        if (f is FuncRef) {
          final owner = f.owner;
          final o = owner is ClassRef ? '${owner.name}.' : '';
          return '$o${f.name}';
        }
        if (f is NativeFunction) return 'native ${f.name}';
        return '$f';
      }

      final self = <int, int>{}, total = <int, int>{};
      final samples = cs.samples!;
      for (final s in samples) {
        final st = s.stack!;
        if (st.isEmpty) continue;
        self[st.first] = (self[st.first] ?? 0) + 1;
        for (final f in st.toSet()) {
          total[f] = (total[f] ?? 0) + 1;
        }
      }
      final n = samples.length;
      debugPrint('PROF samples $n');
      String pct(int v) => (100 * v / n).toStringAsFixed(1).padLeft(5);
      final bySelf = self.keys.toList()..sort((a, b) => self[b]!.compareTo(self[a]!));
      for (final f in bySelf.take(45)) {
        debugPrint('PROF self ${pct(self[f]!)} total ${pct(total[f] ?? 0)}  ${name(f)}');
      }
      final byTotal = total.keys.toList()..sort((a, b) => total[b]!.compareTo(total[a]!));
      for (final f in byTotal.take(45)) {
        debugPrint('PROF TOTAL ${pct(total[f]!)} self ${pct(self[f] ?? 0)}  ${name(f)}');
      }
      await vm.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
