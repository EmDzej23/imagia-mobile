import 'dart:ui' show Size, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/preview_painter.dart';

/// The fitted preview and the zoomed preview are drawn by DIFFERENT painters
/// (`MosaicPreviewPainter` vs `MosaicZoomPainter`), and the studio swaps between them
/// the instant a pinch passes zoom 1. If their transforms disagree even slightly, the
/// picture visibly jumps at the moment the user starts pinching — which reads as a bug
/// rather than a zoom.
///
/// `MosaicZoomPainter` derives its transform as:
///     s  = size.width / windowSize
///     ox = size.width  / 2 - focusX * s
///     oy = size.height / 2 - focusY * s
/// The studio feeds it `windowSize = size.width / (fit.scale * zoom)` centred on the
/// base. At zoom 1 that must reproduce `computeMosaicFit` exactly.
void main() {
  // Portrait box with a landscape picture, and the reverse, so the check covers both
  // which-axis-binds cases in the fit.
  const cases = [
    (Size(390, 500), 1600.0, 1067.0),
    (Size(390, 500), 1067.0, 1600.0),
    (Size(800, 300), 1200.0, 1200.0),
  ];

  for (final (box, bw, bh) in cases) {
    test('zoom-1 transform matches the fitted preview for $bw x $bh in $box', () {
      final fit = computeMosaicFit(box, bw, bh);

      // Exactly what studio_screen passes at zoom 1.
      const zoom = 1.0;
      final zoomScale = fit.scale * zoom;
      final windowSize = box.width / zoomScale;
      final focus = Offset(bw / 2, bh / 2);

      final s = box.width / windowSize;
      final ox = box.width / 2 - focus.dx * s;
      final oy = box.height / 2 - focus.dy * s;

      expect(s, closeTo(fit.scale, 1e-9), reason: 'scale');
      expect(ox, closeTo(fit.ox, 1e-9), reason: 'x offset');
      expect(oy, closeTo(fit.oy, 1e-9), reason: 'y offset');
    });
  }

  test('doubling the zoom halves the visible window', () {
    const box = Size(390, 500);
    final fit = computeMosaicFit(box, 1600, 1067);
    final at1 = box.width / (fit.scale * 1);
    final at2 = box.width / (fit.scale * 2);
    expect(at2, closeTo(at1 / 2, 1e-9));
  });
}
