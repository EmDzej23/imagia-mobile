/// Print-on-demand catalog (v1, app-side placeholders).
///
/// Real Prodigi SKUs, exact aspects and final EUR prices are filled in once the
/// Prodigi account exists; this static catalog drives the mockup + crop UX now.
/// All prices are **VAT-inclusive EUR**. One large size per product
/// (~100–120 cm on the long edge) so individual photo-tiles stay visible.
library;

import 'package:flutter/widgets.dart';

enum PrintType { framedPrint, canvas, poster, metal }

enum PrintOrientation { square, portrait, landscape }

/// A user-choosable Prodigi attribute value (e.g. a frame colour, canvas wrap,
/// metal finish). [value] is the exact Prodigi attribute value.
class PrintOptionChoice {
  const PrintOptionChoice(this.value, this.label, [this.swatch]);
  final String value;
  final String label;

  /// For colour choices — drawn in the mockup; null for non-colour options.
  final Color? swatch;
}

/// The one important choosable attribute for a product type (the Prodigi
/// attribute [attrKey] + its choices). Null for products without one.
class PrintOption {
  const PrintOption(this.attrKey, this.label, this.choices);
  final String attrKey;
  final String label;
  final List<PrintOptionChoice> choices;
  PrintOptionChoice get defaultChoice => choices.first;
}

const _framedColours = [
  PrintOptionChoice('black', 'Black', Color(0xFF1C1C1E)),
  PrintOptionChoice('white', 'White', Color(0xFFEDEDEA)),
  PrintOptionChoice('natural', 'Natural', Color(0xFFC8A877)),
  PrintOptionChoice('silver', 'Silver', Color(0xFFB9BCC1)),
  PrintOptionChoice('light grey', 'Light grey', Color(0xFFAFB1B5)),
  PrintOptionChoice('dark grey', 'Dark grey', Color(0xFF4A4A50)),
  PrintOptionChoice('gold', 'Gold', Color(0xFFC8A24A)),
  PrintOptionChoice('brown', 'Brown', Color(0xFF5C3D28)),
];

const _canvasWraps = [
  PrintOptionChoice('ImageWrap', 'Image wrap'),
  PrintOptionChoice('Black', 'Black edge'),
  PrintOptionChoice('White', 'White edge'),
];

const _metalFinishes = [
  PrintOptionChoice('lustre', 'Lustre'),
  PrintOptionChoice('gloss', 'Gloss'),
  PrintOptionChoice('matte', 'Matte'),
];

/// The choosable option for a product type (or null).
PrintOption? printOption(PrintType type) => switch (type) {
      PrintType.framedPrint => const PrintOption('color', 'Frame', _framedColours),
      PrintType.canvas => const PrintOption('wrap', 'Edge', _canvasWraps),
      PrintType.metal => const PrintOption('finish', 'Finish', _metalFinishes),
      PrintType.poster => null,
    };

/// Product types currently offered in the app. Framed / canvas / metal ship via
/// Prodigi; **poster ships via Gelato** (multiple sizes, live Creem pricing).
const List<PrintType> kAvailablePrintTypes = [
  PrintType.poster,
  PrintType.framedPrint,
  PrintType.canvas,
  PrintType.metal,
];

/// True for the print types fulfilled by Gelato (currently just poster). The rest
/// go through Prodigi. Drives which API/checkout the order screen uses.
bool isGelatoType(PrintType type) => type == PrintType.poster;

/// A Gelato poster size — mirrors the web `POSTER_SIZES` catalog. [aspectPortrait]
/// is width/height in portrait (< 1); landscape uses its reciprocal. [longEdgeCm]
/// drives the "actual size" loupe.
class PosterSizeDef {
  const PosterSizeDef(
      this.size, this.longEdgeCm, this.aspectPortrait, this.orientations);

  /// Size code shared with the server, e.g. `50x70`.
  final String size;
  final double longEdgeCm;
  final double aspectPortrait;
  final List<PrintOrientation> orientations;
}

/// The Gelato poster sizes (identical set + aspects to the web catalog).
const List<PosterSizeDef> kPosterSizes = [
  PosterSizeDef('40x50', 50, 4 / 5,
      [PrintOrientation.portrait, PrintOrientation.landscape]),
  PosterSizeDef('50x70', 70, 5 / 7,
      [PrintOrientation.portrait, PrintOrientation.landscape]),
  PosterSizeDef('70x70', 70, 1, [PrintOrientation.square]),
  PosterSizeDef('70x100', 100, 7 / 10,
      [PrintOrientation.portrait, PrintOrientation.landscape]),
];

/// Poster sizes valid for [orientation].
List<PosterSizeDef> posterSizesFor(PrintOrientation orientation) =>
    kPosterSizes.where((s) => s.orientations.contains(orientation)).toList();

PosterSizeDef? posterSizeByCode(String? code) {
  for (final s in kPosterSizes) {
    if (s.size == code) return s;
  }
  return null;
}

/// Crop aspect (w/h) for a poster size in a given orientation — matches the
/// server's `posterCropAspect` exactly (landscape = reciprocal).
double posterCropAspect(PosterSizeDef def, PrintOrientation orientation) =>
    switch (orientation) {
      PrintOrientation.landscape => 1 / def.aspectPortrait,
      _ => def.aspectPortrait,
    };

/// Server product key, e.g. `poster_50x70_portrait` (matches the Gelato catalogue).
String posterProductKey(String size, PrintOrientation orientation) =>
    'poster_${size}_${orientation.name}';

/// e.g. portrait "50 × 70 cm", landscape "70 × 50 cm".
String posterSizeLabelCm(PosterSizeDef def, PrintOrientation orientation) {
  final parts = def.size.split('x');
  if (parts.length != 2) return '${def.longEdgeCm.round()} cm';
  final a = parts[0], b = parts[1];
  return orientation == PrintOrientation.landscape
      ? '$b × $a cm'
      : '$a × $b cm';
}

/// Device screen density used to map print-cm → on-screen size. Flutter's
/// logical pixel baseline is ~160 px/inch, so ~63 px/cm. This makes the loupe
/// *approximately* life-size on most phones; a one-time per-device calibration
/// (e.g. matching a credit card) would make it exact.
const double kLogicalPxPerCm = 160 / 2.54; // ≈ 62.99

const double _inCm = 2.54;

/// Crop aspect + physical size for a (type, orientation), derived from the real
/// Prodigi SKU. Drives the crop window, the mockup, and the "actual size" loupe.
class PrintSpec {
  const PrintSpec({required this.aspect, required this.longEdgeCm});

  /// width / height.
  final double aspect;

  /// Physical long edge in cm.
  final double longEdgeCm;

  String get sizeLabel => '~${longEdgeCm.round()} cm';
}

/// SKUs in use (test): canvas SLIMCAN 40×40 / 32×40, framed CFP 40×40 / 32×40,
/// metal DI 36×36 / A0. Landscape reuses the portrait SKU rotated 90°.
PrintSpec printSpec(PrintType type, PrintOrientation orientation) {
  switch (type) {
    case PrintType.canvas:
    case PrintType.framedPrint:
      return switch (orientation) {
        PrintOrientation.square =>
          const PrintSpec(aspect: 1, longEdgeCm: 40 * _inCm),
        PrintOrientation.portrait =>
          const PrintSpec(aspect: 32 / 40, longEdgeCm: 40 * _inCm),
        PrintOrientation.landscape =>
          const PrintSpec(aspect: 40 / 32, longEdgeCm: 40 * _inCm),
      };
    case PrintType.metal:
      return switch (orientation) {
        PrintOrientation.square =>
          const PrintSpec(aspect: 1, longEdgeCm: 36 * _inCm), // 36×36"
        PrintOrientation.portrait =>
          const PrintSpec(aspect: 28 / 40, longEdgeCm: 40 * _inCm), // 28×40"
        PrintOrientation.landscape =>
          const PrintSpec(aspect: 40 / 28, longEdgeCm: 40 * _inCm),
      };
    case PrintType.poster:
      // Not configured with a real SKU yet — generic placeholder.
      return switch (orientation) {
        PrintOrientation.square => const PrintSpec(aspect: 1, longEdgeCm: 100),
        PrintOrientation.portrait =>
          const PrintSpec(aspect: 3 / 4, longEdgeCm: 100),
        PrintOrientation.landscape =>
          const PrintSpec(aspect: 4 / 3, longEdgeCm: 100),
      };
  }
}

extension PrintTypeInfo on PrintType {
  String get label => switch (this) {
        PrintType.framedPrint => 'Framed print',
        PrintType.canvas => 'Canvas',
        PrintType.poster => 'Fine-art poster',
        PrintType.metal => 'Metal print',
      };

  String get blurb => switch (this) {
        PrintType.framedPrint =>
          'Museum-grade print in a slim classic frame.',
        PrintType.canvas =>
          'Gallery-wrapped canvas (image wrap), ready to hang.',
        PrintType.poster => 'Heavyweight matte fine-art paper.',
        PrintType.metal => 'High-gloss aluminium with a luminous finish.',
      };
}

/// Countries where the print feature is offered: US, UK, the EU — plus RS
/// (Serbia) for testing.
const Set<String> kPrintAllowedCountries = {
  'US', 'GB', 'RS', // US, UK, + Serbia (test)
  // EU
  'AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR',
  'HU', 'IE', 'IT', 'LV', 'LT', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK',
  'SI', 'ES', 'SE',
};

/// Whether the print feature should be shown, based on the device's region.
/// (Soft gate — device locale country, not IP geolocation.)
bool isPrintRegionAllowed() {
  final cc = WidgetsBinding
      .instance.platformDispatcher.locale.countryCode
      ?.toUpperCase();
  return cc != null && kPrintAllowedCountries.contains(cc);
}

/// VAT-inclusive EUR retail price per (type, orientation).
double printPriceEur(PrintType type, PrintOrientation orientation) {
  switch (type) {
    case PrintType.canvas:
      return 275;
    case PrintType.framedPrint:
      return orientation == PrintOrientation.square ? 325 : 275;
    case PrintType.metal:
      return orientation == PrintOrientation.square ? 235 : 285;
    case PrintType.poster:
      return 0; // not offered
  }
}

/// The server catalogue key for a product, e.g. `framed_portrait` — matches the
/// `key` field returned by `GET /api/print/<provider>/products`, so the live
/// (Creem-backed) price can be looked up per product.
String printProductKey(PrintType type, PrintOrientation orientation) {
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

extension PrintOrientationInfo on PrintOrientation {
  String get label => switch (this) {
        PrintOrientation.square => 'Square',
        PrintOrientation.portrait => 'Portrait',
        PrintOrientation.landscape => 'Landscape',
      };

  /// Crop aspect ratio (width / height). Placeholder values — finalised per
  /// Prodigi SKU dimensions later.
  double get aspect => switch (this) {
        PrintOrientation.square => 1.0,
        PrintOrientation.portrait => 3 / 4,
        PrintOrientation.landscape => 4 / 3,
      };
}

/// Picks the orientation whose aspect best matches the mosaic's own, so the
/// initial selection needs the least cropping.
PrintOrientation orientationForAspect(double imageAspect) {
  PrintOrientation best = PrintOrientation.square;
  var bestDelta = double.infinity;
  for (final o in PrintOrientation.values) {
    final d = (o.aspect - imageAspect).abs();
    if (d < bestDelta) {
      bestDelta = d;
      best = o;
    }
  }
  return best;
}
