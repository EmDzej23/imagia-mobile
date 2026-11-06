import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/preview_painter.dart';
import 'package:imagia_mobile/screens/create/studio_screen.dart';

/// The fitted preview is drawn once at the pane's largest height and scaled as the
/// settings sheet moves (_ScaledFit). The scaled picture must land on EXACTLY the rect
/// a contain-fit in the current box gives (computeMosaicFit) — taps map cells with it.
void main() {
  test('scaled preview lands where the contain-fit does', () {
    for (final (w, bw, bh) in [(390.0, 1600.0, 1067.0), (390.0, 1067.0, 1600.0), (412.0, 1200.0, 1200.0)]) {
      const h0 = 720.0;
      for (final h in [700.0, 520.0, 380.0, 240.0, 160.0]) {
        final k = scaledFitScale(w, h, h0, bw / bh);
        // Picture in the big box, centred, then scaled about the box centre and the big
        // box centred on the real box.
        final big = computeMosaicFit(Size(w, h0), bw, bh);
        final cx = w / 2, cyBig = h0 / 2, cy = h / 2;
        final left = cx + (big.ox - cx) * k;
        final top = cy + (big.oy - cyBig) * k;
        final want = computeMosaicFit(Size(w, h), bw, bh);
        expect(left, closeTo(want.ox, 1e-6), reason: 'left $bw×$bh h=$h');
        expect(top, closeTo(want.oy, 1e-6), reason: 'top $bw×$bh h=$h');
        expect(big.drawW * k, closeTo(want.drawW, 1e-6));
        expect(big.drawH * k, closeTo(want.drawH, 1e-6));
      }
    }
  });
}
