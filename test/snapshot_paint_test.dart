import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/snapshot_paint.dart';

/// The settled preview is drawn once into an image (snapshot_paint.dart) instead of
/// tile by tile every frame. It must look the same as drawing it live, and its reveal
/// must end on exactly that picture.
class _Checker extends CustomPainter {
  _Checker(this.seed);
  final int seed;
  @override
  void paint(Canvas canvas, Size size) {
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x * size.width / 8, y * size.height / 8, size.width / 8, size.height / 8),
          Paint()..color = Color.fromARGB(255, (x * 31 + seed) % 256, (y * 29) % 256, ((x + y) * 17) % 256),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Checker old) => old.seed != seed;
}

List<Rect> _cells(Size s) => [
  for (var y = 0; y < 8; y++)
    for (var x = 0; x < 8; x++)
      Rect.fromLTWH(x * s.width / 8, y * s.height / 8, s.width / 8, s.height / 8),
];

void main() {
  Future<List<int>> grab(WidgetTester tester, Widget child) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(width: 80, height: 80, child: child),
          ),
        ),
      ),
    );
    late List<int> px;
    await tester.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      px = data!.buffer.asUint8List().toList();
    });
    return px;
  }

  int maxDiff(List<int> a, List<int> b) {
    var m = 0;
    for (var i = 0; i < a.length; i++) {
      final d = (a[i] - b[i]).abs();
      if (d > m) m = d;
    }
    return m;
  }

  testWidgets('snapshot matches the live painter; a finished reveal is the picture', (tester) async {
    final live = await grab(tester, CustomPaint(painter: _Checker(1)));
    final snap = await grab(tester, SnapshotPaint(painter: _Checker(1)));
    expect(snap.length, live.length);
    expect(maxDiff(live, snap), lessThanOrEqualTo(2));

    // Halfway through a reveal something is drawn, and not the whole picture yet.
    final half = await grab(
      tester,
      SnapshotPaint(
        painter: _Checker(1),
        appear: 0.5,
        pieces: _cells,
        place: (i, c, a) => i.isEven ? (rect: c, opacity: 1.0) : null,
      ),
    );
    expect(maxDiff(half, snap), greaterThan(10));
    // At 1 the reveal is over: exactly the snapshot.
    final done = await grab(
      tester,
      SnapshotPaint(painter: _Checker(1), appear: 1, pieces: _cells, place: (i, c, a) => null),
    );
    expect(maxDiff(done, snap), 0);

    // A changed painter is re-drawn, not served from the old image.
    final other = await grab(tester, SnapshotPaint(painter: _Checker(90)));
    expect(maxDiff(other, snap), greaterThan(10));
  });
}
