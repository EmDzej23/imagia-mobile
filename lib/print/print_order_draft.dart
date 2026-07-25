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
    this.posterSize,
  });

  final PrintType type;
  final PrintOrientation orientation;

  /// For posters only: the chosen Gelato size code (e.g. `50x70`). Null otherwise.
  final String? posterSize;

  /// Posters are fulfilled by Gelato; everything else by Prodigi.
  bool get isPoster => type == PrintType.poster;

  /// Chosen product option (frame colour / canvas wrap / metal finish).
  final PrintOptionChoice? option;

  /// Preview-resolution mosaic raster (for the review mockup only).
  final ui.Image mosaic;

  /// Crop region in [mosaic] pixels.
  final ui.Rect cropSrc;
  final double priceEur;

  PrintSpec get spec => printSpec(type, orientation);

  PosterSizeDef? get _posterDef => posterSizeByCode(posterSize);

  double get aspect => isPoster && _posterDef != null
      ? posterCropAspect(_posterDef!, orientation)
      : spec.aspect;

  String get sizeLabel => isPoster && _posterDef != null
      ? posterSizeLabelCm(_posterDef!, orientation)
      : spec.sizeLabel;

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

  /// Server catalogue key — `poster_50x70_portrait` for posters (Gelato), else
  /// `framed_portrait` etc. (Prodigi).
  String get productKey => isPoster && posterSize != null
      ? posterProductKey(posterSize!, orientation)
      : printProductKey(type, orientation);

  /// Resolution-independent crop the server applies to the high-res render.
  PrintCrop get cropNormalized => PrintCrop(
        cropSrc.left / mosaic.width,
        cropSrc.top / mosaic.height,
        cropSrc.width / mosaic.width,
        cropSrc.height / mosaic.height,
      );
}
