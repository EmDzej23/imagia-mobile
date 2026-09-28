import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/hexagon.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/screens/create/studio_screen.dart';

/// Guards the two ways a mode can be offered but not work.
///
/// `sanitizeSettings` does not REJECT an unknown mode — it silently rewrites it to
/// 'original'. So a mode can sit in the picker looking fine while producing an
/// ordinary mosaic, with nothing anywhere to say why. That is exactly how "3D" and
/// "Hexagons" shipped as no-ops, and a list-vs-list check is the only thing that
/// catches it, because nothing throws.
void main() {
  group('every mode the picker offers survives sanitizeSettings', () {
    for (final opt in kPhotoModeOptions) {
      test('${opt.value} ("${opt.label}")', () {
        final out = sanitizeSettings(defaultSettings()..mosaicMode = opt.value);
        expect(out.mosaicMode, opt.value,
            reason: '"${opt.label}" would silently render as ${out.mosaicMode}');
      });
    }
  });

  test('tile crops are offered in every photo layout, not just square', () {
    // The crop map is keyed by tile id with nothing mode-specific in it, and every
    // tile-matching renderer applies it — so gating the editor to one mode hid a
    // setting that was still in force everywhere else.
    for (final opt in kPhotoModeOptions) {
      expect(modeSupportsTileCrops(opt.value), isTrue,
          reason: '${opt.value} uses tiles, so it must expose the crop editor');
    }
    // Tile-less modes have no tiles to crop.
    for (final m in ['ancient', 'ancient-curved', 'wordart']) {
      expect(modeSupportsTileCrops(m), isFalse, reason: '$m has no tile library');
    }
  });

  test('a stored crop keeps its own slot per cell aspect and shape', () {
    // Slots are what let a crop chosen for a square cell coexist with one chosen for
    // a hexagon: same tile, different framing, so they cannot share a key.
    final square = cropSlot('t1', 1.0, null);
    final landscape = cropSlot('t1', 3 / 2, null);
    final hex = cropSlot('t1', hexAspect, CropShape.hex);
    expect({square, landscape, hex}.length, 3,
        reason: 'each cell shape needs its own stored crop');
    expect(cropSlot('t1', 1.0, null), square, reason: 'slot must be stable');
  });
}
