import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/screens/create/studio_screen.dart';

/// The rule behind the collapsing preview (Instagram-composer behaviour): reading down
/// the settings shrinks the preview, heading back up reopens it.
void main() {
  test('reading down the settings collapses the preview', () {
    expect(previewActionFor(pixels: 200, direction: ScrollDirection.reverse),
        PreviewAction.collapse);
  });

  test('scrolling back up does NOT reopen it mid-list', () {
    // Deliberate. The idiom is to expand here, but it fires on every small upward
    // correction, and this list is long enough that people make those constantly
    // while comparing two controls — each one would fling the preview back over
    // what they were reading. Reopening is left to intentful acts: touching a
    // setting, reaching the top, tapping the preview, tapping the grabber.
    expect(previewActionFor(pixels: 200, direction: ScrollDirection.forward),
        PreviewAction.hold);
  });

  test('reaching the top of the list does reopen it', () {
    // Unlike a 10px correction, arriving back at the top is unambiguous: done with
    // the settings. This is the one automatic way back that cannot flap.
    expect(previewActionFor(pixels: 0, direction: ScrollDirection.forward),
        PreviewAction.expand);
  });

  test('a small drag does not collapse it', () {
    // Sliders live in this list; the overscroll leaking out of a slider drag must not
    // snap the preview shut exactly while the user is watching the value change.
    expect(previewActionFor(pixels: 8, direction: ScrollDirection.reverse),
        PreviewAction.hold);
  });

  test('at the very top it is always open, whichever way the gesture went', () {
    // A bounce at the top reports `reverse` while sitting at (or past) offset 0. Left
    // to the direction alone that would strand the preview collapsed — and now that
    // scrolling up no longer reopens it, that would be a genuine dead end.
    for (final d in ScrollDirection.values) {
      expect(previewActionFor(pixels: 0, direction: d), PreviewAction.expand,
          reason: 'offset 0 with $d');
      expect(previewActionFor(pixels: -30, direction: d), PreviewAction.expand,
          reason: 'overscroll with $d');
    }
  });

  test('an idle list is left alone', () {
    expect(previewActionFor(pixels: 200, direction: ScrollDirection.idle),
        PreviewAction.hold);
  });
}
