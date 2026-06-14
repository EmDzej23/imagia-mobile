import 'dart:ui' as ui;

import '../api/print_api.dart';
import 'print_catalog.dart';

/// Everything chosen on the wall-art screen, carried through address → review →
/// checkout.
class PrintOrderDraft {
  PrintOrderDraft({
    required this.type,
    required this.orientation,
    required this.mosaic,
    required this.cropSrc,
    required this.priceEur,
    this.frameColour = FrameColour.black,
  });

  final PrintType type;
  final PrintOrientation orientation;

  /// Chosen frame colour (only meaningful for framed prints).
  final FrameColour frameColour;

  /// Preview-resolution mosaic raster (for the review mockup only).
  final ui.Image mosaic;

  /// Crop region in [mosaic] pixels.
  final ui.Rect cropSrc;
  final double priceEur;

  PrintSpec get spec => printSpec(type, orientation);
  double get aspect => spec.aspect;
  String get sizeLabel => spec.sizeLabel;

  /// Server catalogue key, e.g. `framed_portrait`.
  String get productKey {
    final t = switch (type) {
      PrintType.framedPrint => 'framed',
      PrintType.canvas => 'canvas',
      PrintType.poster => 'poster',
      PrintType.metal => 'metal',
    };
    final o = switch (orientation) {
      PrintOrientation.square => 'square',
      PrintOrientation.portrait => 'portrait',
      PrintOrientation.landscape => 'landscape',
    };
    return '${t}_$o';
  }

  /// Resolution-independent crop the server applies to the high-res render.
  PrintCrop get cropNormalized => PrintCrop(
        cropSrc.left / mosaic.width,
        cropSrc.top / mosaic.height,
        cropSrc.width / mosaic.width,
        cropSrc.height / mosaic.height,
      );
}
