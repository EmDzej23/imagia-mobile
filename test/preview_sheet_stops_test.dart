import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/screens/create/studio_screen.dart';

/// The rules behind the draggable preview sheet.
///
/// These are pure functions on purpose: the sheet's feel is decided here, and a bug in
/// either one shows up on a device as "it jumps" or "it won't stay where I put it" —
/// symptoms that are miserable to chase through a widget tree but trivial to pin as
/// arithmetic.
void main() {
  group('height mapping', () {
    test('the three stops land on their advertised heights', () {
      expect(previewFlexFor(stopFull), closeTo(flexFull, 0.001));
      expect(previewFlexFor(stopDefault), closeTo(flexDefault, 0.001));
      expect(previewFlexFor(stopSettings), closeTo(flexSettings, 0.001));
    });

    test('the preview only ever shrinks as the value grows', () {
      // Monotonicity is the whole contract with the finger. A mapping that doubles
      // back would make the preview grow mid-drag while the thumb is still moving
      // down, which reads as the sheet fighting you.
      var prev = double.infinity;
      for (var i = 0; i <= 100; i++) {
        final f = previewFlexFor(i / 100);
        expect(f, lessThanOrEqualTo(prev + 1e-9), reason: 'reversed at v=${i / 100}');
        prev = f;
      }
    });

    test('height tracks the value linearly inside each segment', () {
      // The drag maps finger pixels straight onto the value, so any curve HERE is a
      // curve between the thumb and the sheet — it races ahead, then crawls. Easing is
      // the animation's job; equal steps in value must be equal steps in height.
      for (final seg in [
        [stopFull, stopDefault],
        [stopDefault, stopSettings],
      ]) {
        final a = previewFlexFor(seg[0]);
        final b = previewFlexFor(seg[1]);
        for (var i = 1; i < 10; i++) {
          final f = i / 10;
          expect(previewFlexFor(seg[0] + (seg[1] - seg[0]) * f), closeTo(a + (b - a) * f, 0.001),
              reason: 'non-linear at $f of ${seg[0]}..${seg[1]}');
        }
      }
    });

    test('the preview always keeps the grabber strip', () {
      // Full-preview must not close the sheet completely: the grabber is the way back.
      expect(previewFlexFor(stopFull), lessThan(1000));
    });
  });

  group('snapping', () {
    test('a slow release goes to the nearest stop', () {
      expect(snapPreviewStop(0.05, 0), stopFull);
      expect(snapPreviewStop(0.45, 0), stopDefault);
      expect(snapPreviewStop(0.95, 0), stopSettings);
    });

    test('a flick carries past the nearest stop', () {
      // Downward drag grows the preview, so a downward fling must move toward full
      // even when the finger lifted closer to where it started.
      expect(snapPreviewStop(0.95, 1200), stopDefault);
      expect(snapPreviewStop(0.45, 1200), stopFull);
      expect(snapPreviewStop(0.05, -1200), stopDefault);
      expect(snapPreviewStop(0.55, -1200), stopSettings);
    });

    test('a flick at the end of the travel stays put', () {
      // Nothing further to reach — it must not fall through to a wrong stop.
      expect(snapPreviewStop(0.0, 1200), stopFull);
      expect(snapPreviewStop(1.0, -1200), stopSettings);
    });

    test('every result is one of the three stops', () {
      for (var i = 0; i <= 20; i++) {
        for (final v in [-2000.0, -500.0, 0.0, 500.0, 2000.0]) {
          expect([stopFull, stopDefault, stopSettings],
              contains(snapPreviewStop(i / 20, v)));
        }
      }
    });
  });
}
