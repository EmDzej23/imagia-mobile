import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Color;

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
    this.option,
  });

  final PrintType type;
  final PrintOrientation orientation;

  /// Chosen product option (frame colour / canvas wrap / metal finish).
  final PrintOptionChoice? option;

  /// Preview-resolution mosaic raster (for the review mockup only).
  final ui.Image mosaic;

  /// Crop region in [mosaic] pixels.
  final ui.Rect cropSrc;
  final double priceEur;

  PrintSpec get spec => printSpec(type, orientation);
  double get aspect => spec.aspect;
  String get sizeLabel => spec.sizeLabel;

  /// Frame colour for the framed mockup (defaults to black).
  Color get frameColor => type == PrintType.framedPrint
      ? (option?.swatch ?? const Color(0xFF1C1C1E))
      : const Color(0xFF1C1C1E);

  /// The chosen attribute as {key: value} for the order (or null).
  Map<String, String>? get attributes {
    final opt = printOption(type);
    if (opt == null || option == null) return null;
    return {opt.attrKey: option!.value};
  }

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
