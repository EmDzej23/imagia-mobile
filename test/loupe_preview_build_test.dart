import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/screens/create/loupe_preview.dart';

/// Regression: the widget used to ask its own element for `context.size` to decide
/// what to render, and it did so from `didUpdateWidget` — which runs during build.
/// Flutter throws "Cannot get size during build" there, and it fired on device the
/// moment a pinch coincided with a rebuild.
///
/// The size now comes from the LayoutBuilder, so there is no timing dependency left.
/// These tests fail loudly (an unhandled exception fails the test) if it comes back.
Future<ui.Image> _solid(int w, int h, Color c) async {
  final rec = ui.PictureRecorder();
  Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()))
      .drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = c);
  return rec.endRecording().toImage(w, h);
}

void main() {
  testWidgets('rebuilding with a new image does not read size during build',
      (tester) async {
    final a = await _solid(120, 80, const Color(0xFF203040));
    final b = await _solid(120, 80, const Color(0xFF405060));

    Widget host(ui.Image img) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: LoupePreviewImage(
                image: img,
                cropRenderer: (crop, outW, outH) =>
                    _solid(outW, outH, const Color(0xFF708090)),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(a));
    // The swap is what used to throw: a new image triggers didUpdateWidget, which
    // asked for the element's size mid-build.
    await tester.pumpWidget(host(b));
    await tester.pump(const Duration(milliseconds: 200)); // let the debounce fire
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing the box does not read size during build', (tester) async {
    final img = await _solid(120, 80, const Color(0xFF203040));

    Widget host(double h) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: h,
              child: LoupePreviewImage(image: img),
            ),
          ),
        );

    // The studio's preview pane resizes continuously as the settings scroll, so a
    // changing box is the normal case, not an edge one.
    await tester.pumpWidget(host(200));
    await tester.pumpWidget(host(120));
    await tester.pumpWidget(host(60));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
