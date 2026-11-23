// Scripted demo recording: upload → studio → export → save to Photos, on the iOS
// simulator, against the LIVE backend with an already signed-in demo account.
//
// Not part of the unit tests. Run (with the screen recorder going, see
// tool/record_demo.sh):
//   flutter test integration_test/demo_flow_test.dart -d <simulator id>
//
// The system photo picker can't be driven from a test, so image_picker is swapped for
// a fake that returns the demo photos from disk (DEMO_BASE / DEMO_TILES below). Taps
// are paced like a person's and shown with a dot, since the simulator records none.
//
// Writes to the live backend: uploads the photos, saves a project, spends 1 token on
// the render and adds a download.

import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';

import 'package:imagia_mobile/main.dart';
import 'package:imagia_mobile/router.dart';
import 'package:imagia_mobile/services/notifications.dart';

const _base = String.fromEnvironment(
  'DEMO_BASE',
  defaultValue: '/Users/marko/radni/pexels-image-downloader/face/024.jpeg',
);
const _tilesDir = String.fromEnvironment(
  'DEMO_TILES',
  defaultValue: '/Users/marko/radni/pexels-image-downloader/urban%art',
);
const _tileCount = int.fromEnvironment('DEMO_TILE_COUNT', defaultValue: 150);

/// image_picker stand-in: the demo photos, as if picked from the library.
class _DemoPicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async =>
      XFile(_base);

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    final files = Directory(_tilesDir)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files.take(_tileCount).map((f) => XFile(f.path)).toList();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('demo: upload to download', (tester) async {
    // Same start-up as main(), minus the push prompt and the install ping.
    await Firebase.initializeApp();
    await NotificationService.instance.init();
    ImagePickerPlatform.instance = _DemoPicker();

    await tester.pumpWidget(const ProviderScope(child: ImagiaApp()));
    // Markers for the editor (wall-clock ms): where the take starts and ends, and the
    // long waits that get cut or sped up.
    void mark(String what) => debugPrint('DEMO_MARK $what ${DateTime.now().millisecondsSinceEpoch}');
    mark('start');

    Future<void> wait(double seconds) async {
      final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    Future<void> waitFor(Finder f, {double timeout = 120, bool enabled = false}) async {
      final end = DateTime.now().add(Duration(milliseconds: (timeout * 1000).round()));
      while (true) {
        await wait(0.2);
        if (f.evaluate().isNotEmpty) {
          if (!enabled) return;
          final button = tester.widgetList(find.ancestor(of: f, matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton || w is InkWell || w is GestureDetector,
          )));
          final on = button.any((w) => w is ButtonStyleButton
              ? w.onPressed != null
              : w is InkWell
                  ? w.onTap != null
                  : (w as GestureDetector).onTap != null);
          if (on) return;
        }
        if (DateTime.now().isAfter(end)) {
          throw TimeoutException('Timed out waiting for $f');
        }
      }
    }

    /// Tap like a person: a dot appears, holds, the tap lands, the dot fades.
    Future<void> tap(Finder f, {double before = 0.6, double after = 1.2}) async {
      final target = f.first;
      await tester.ensureVisible(target);
      await wait(0.2);
      final at = tester.getCenter(target);
      final overlay = rootNavigatorKey.currentState!.overlay!;
      final dot = ValueNotifier<double>(0);
      final entry = OverlayEntry(
        builder: (_) => Positioned(
          left: at.dx - 22,
          top: at.dy - 22,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: dot,
              builder: (_, v, _) => Opacity(
                opacity: v,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.35),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      overlay.insert(entry);
      for (var i = 1; i <= 8; i++) {
        dot.value = i / 8;
        await wait(0.02);
      }
      await wait(before);
      await tester.tapAt(at);
      await wait(0.15);
      for (var i = 7; i >= 0; i--) {
        dot.value = i / 8;
        await wait(0.03);
      }
      entry.remove();
      await wait(after);
    }

    // Signed in → the projects list. (Sign in once by hand first; see the script.)
    final newMosaic = find.text('New Mosaic');
    await waitFor(newMosaic, timeout: 30);
    await wait(1.5);
    await tap(newMosaic);

    // Main photo.
    await waitFor(find.text('Choose from library'));
    await wait(1);
    await tap(find.text('Choose from library'));
    await waitFor(find.text('Crop your photo'));
    await wait(1.5);
    final confirmCrop = find.text('Apply').evaluate().isNotEmpty ? find.text('Apply') : find.text('Use original');
    await tap(confirmCrop);
    await waitFor(find.text('Continue'), enabled: true, timeout: 60);
    await wait(1.5);
    await tap(find.text('Continue'));

    // Tile photos (uploaded + analysed; the editor cuts most of this wait).
    await waitFor(find.text('Add photos'));
    await wait(1);
    await tap(find.text('Add photos'));
    await wait(2);
    mark('upload_wait_begin');
    await waitFor(find.text('Continue'), enabled: true, timeout: 600);
    final uploadDone = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(uploadDone)) {
      // Done when the Add photos button is enabled again (not uploading).
      final add = tester.widgetList(find.ancestor(of: find.text('Add photos'), matching: find.byType(InkWell)));
      if (add.any((w) => (w as InkWell).onTap != null)) break;
      await wait(0.5);
    }
    mark('upload_wait_end');
    await wait(2);
    await tap(find.text('Continue'));

    // Studio: let the mosaic build and sit on it.
    final export = find.textContaining('Export');
    mark('build_wait_begin');
    await waitFor(export, timeout: 300, enabled: true);
    mark('build_wait_end');
    await wait(6);

    // Export → render on the server → save.
    await tap(export.last);
    await wait(2);
    mark('render_wait_begin');
    await waitFor(find.text('Save to Photos'), timeout: 600, enabled: true);
    mark('render_wait_end');
    await wait(2.5);
    await tap(find.text('Save to Photos'));
    await waitFor(find.text('Saved to Photos'), timeout: 120);
    await wait(4);
    mark('end');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
