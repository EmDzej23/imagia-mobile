import 'dart:typed_data';

/// Dart port of `foto-mozaik/lib/mosaic/types.ts`.
///
/// Fidelity notes:
/// - JS `number` is IEEE-754 float64 == Dart `double`. Every numeric field here
///   is `double` (never `int`) so arithmetic matches the web bit-for-bit.
/// - Where the web uses `Float32Array` (orientation histograms, integral image
///   buffers) we use `Float32List` so the float32 rounding is preserved — it is
///   part of the algorithm, not an implementation detail.
/// - `mosaicMode` is kept as a raw `String` to mirror the web's string
///   comparisons exactly.

class RgbColor {
  RgbColor(this.r, this.g, this.b);
  double r;
  double g;
  double b;

  factory RgbColor.fromJson(Map<String, dynamic> j) => RgbColor(
    (j['r'] as num).toDouble(),
    (j['g'] as num).toDouble(),
    (j['b'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'r': r, 'g': g, 'b': b};
}

class LabColor {
  LabColor(this.L, this.a, this.b);
  double L;
  double a;
  double b;

  factory LabColor.fromJson(Map<String, dynamic> j) => LabColor(
    (j['L'] as num).toDouble(),
    (j['a'] as num).toDouble(),
    (j['b'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'L': L, 'a': a, 'b': b};
}

/// "landscape" | "portrait" | "square"
typedef TileOrientation = String;

/// 5x5 grid of Lab colors, row-major (length 25).
typedef SubregionColors = List<LabColor>;

class LuminanceBalance {
  LuminanceBalance(this.vertical, this.horizontal);
  double vertical;
  double horizontal;

  factory LuminanceBalance.fromJson(Map<String, dynamic> j) => LuminanceBalance(
    (j['vertical'] as num).toDouble(),
    (j['horizontal'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'vertical': vertical,
    'horizontal': horizontal,
  };
}

/// 8-bin luminance histogram (length 8).
typedef LuminanceHistogram = List<double>;

/// 5x5 grid of edge density values, row-major (length 25).
typedef SubregionEdges = List<double>;

/// 5x5 grid of local contrast values (length 25).
typedef ContrastMap = List<double>;

/// Per-cell 4-bin gradient orientation histogram, 5x5 cells flat row-major
/// (length 100). Stored as float32 to match the web's `Float32Array`.
typedef SubregionEdgeOrientations = Float32List;

class SignalWeights {
  SignalWeights({
    required this.color,
    required this.luminancePattern,
    required this.chromaPattern,
    required this.edgePattern,
    required this.tonalHistogram,
    required this.brightnessEmphasis,
    required this.contrastPattern,
  });

  double color;
  double luminancePattern;
  double chromaPattern;
  double edgePattern;
  double tonalHistogram;
  double brightnessEmphasis;
  double contrastPattern;

  SignalWeights copy() => SignalWeights(
    color: color,
    luminancePattern: luminancePattern,
    chromaPattern: chromaPattern,
    edgePattern: edgePattern,
    tonalHistogram: tonalHistogram,
    brightnessEmphasis: brightnessEmphasis,
    contrastPattern: contrastPattern,
  );

  factory SignalWeights.fromJson(Map<String, dynamic> j) => SignalWeights(
    color: (j['color'] as num).toDouble(),
    luminancePattern: (j['luminancePattern'] as num).toDouble(),
    chromaPattern: (j['chromaPattern'] as num).toDouble(),
    edgePattern: (j['edgePattern'] as num).toDouble(),
    tonalHistogram: (j['tonalHistogram'] as num).toDouble(),
    brightnessEmphasis: (j['brightnessEmphasis'] as num).toDouble(),
    contrastPattern: (j['contrastPattern'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'color': color,
    'luminancePattern': luminancePattern,
    'chromaPattern': chromaPattern,
    'edgePattern': edgePattern,
    'tonalHistogram': tonalHistogram,
    'brightnessEmphasis': brightnessEmphasis,
    'contrastPattern': contrastPattern,
  };
}

/// "original" | "blocks" | "square" | "landscape" | "portrait"
typedef MosaicMode = String;

/// A finished collage cut-out (private Blob files from the render service). Same
/// shape as the web's `CollageCut`.
class CollageCut {
  CollageCut({
    required this.src,
    required this.cutUrl,
    required this.cutPreviewUrl,
    required this.width,
    required this.height,
  });

  /// The uploaded photo it was cut from — a cut only counts for that same photo.
  final String src;
  final String cutUrl;
  final String cutPreviewUrl;
  final int width;
  final int height;

  factory CollageCut.fromJson(Map<String, dynamic> j) => CollageCut(
    src: j['src'] as String? ?? '',
    cutUrl: j['cutUrl'] as String? ?? '',
    cutPreviewUrl: j['cutPreviewUrl'] as String? ?? '',
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'src': src,
    'cutUrl': cutUrl,
    'cutPreviewUrl': cutPreviewUrl,
    'width': width,
    'height': height,
  };
}

class MosaicSettings {
  MosaicSettings({
    required this.mosaicMode,
    required this.density,
    required this.outputWidth,
    required this.reusePenalty,
    required this.aspectWeight,
    required this.detailWeight,
    required this.minBlockSize,
    required this.maxBlockSize,
    required this.tintStrength,
    required this.baseBlur,
    required this.colorBoost,
    required this.autoContrast,
    this.maxTileUses = 0,
    this.tileCrops,
    this.ancientStoneSize = 14,
    this.ancientGrout = 1.4,
    this.ancientIrregularity = 0.85,
    this.ancientVariation = 0.12,
    this.ancientBevel = 0.35,
    this.ancientGroutColor = 'dark',
    this.ancientCurviness = 0.55,
    this.ancientShape = 'none',
    this.wordartDensity = 43,
    this.wordartRotation = 0,
    this.wordartContrast = 1,
    this.wordartPalette = 64,
    this.wordartGround = 0,
    this.wordartVivid = 1,
    this.wordartEmpty = 1,
    this.wordartCoverage = 1,
    this.wordartSaturate = 1.5,
    this.wordartBrightness = 1.5,
    this.wordartTrueColor = true,
    this.wordartCaption = '',
    this.wordartTitleColor = '',
    this.collageFormat = 'portrait',
    this.collageRotation = 12,
    this.collageOutline = 0.5,
    this.collageShadow = 0.5,
    this.collageBackground = '#18181b',
    this.collageKinds,
    this.collageHero,
    this.collageCuts,
    this.outputSaturation = 1.1,
    this.tileRecolor = 1,
    this.shapeMatch = 0.5,
    this.repeatSpacing = 2,
    this.optimalPlacement = true,
    this.fitLightToLibrary = false,
    this.look = 'none',
    this.saBudgetFactor,
    this.signalWeights,
  });

  MosaicMode mosaicMode;
  double density;
  double outputWidth;

  /// PINNED to fixedReusePenalty by sanitizeSettings — no longer user-facing.
  double reusePenalty;
  double aspectWeight;
  double detailWeight;
  double minBlockSize;
  double maxBlockSize;
  double tintStrength;
  double baseBlur;
  double colorBoost;
  double autoContrast;

  /// Hard ceiling on how many cells one photo may fill.
  ///
  /// 0 = unlimited. [evenTileUses] (-1) = as even as the library allows, resolved to
  /// cells / photos at build time. The sentinel exists because that floor moves: store
  /// the computed number instead and changing the density afterwards leaves a cap that
  /// no longer means "as even as possible", silently loosening a setting the user never
  /// touched.
  int maxTileUses;

  /// Manual per-tile crops, so the MATCHER judges the pixels that will be shown.
  ///
  /// These already reach the renderer through the plan. They are here as well because a
  /// crop changes which part of a photo appears, and a scorer that cannot see it picks
  /// tiles by a framing the viewer never gets — the same defect `cropPortraitTop` had.
  /// Keyed by crop slot (see [cropSlot]), not by bare tile id.
  Map<String, TileCrop>? tileCrops;

  // Ancient-mosaic (tile-less stone renderer). Look settings only.
  double ancientStoneSize;
  double ancientGrout;
  double ancientIrregularity;
  double ancientVariation;
  double ancientBevel;
  String ancientGroutColor; // "dark" | "stone" | "light"
  double ancientCurviness; // curved-ancient only
  String ancientShape; // "none" | "heart" | "basketball" | "flower"

  // Word-art (tile-less typographic renderer). Look settings only.
  double
  wordartDensity; // largest word size at the reference long side (18..100)
  double wordartRotation; // max tilt degrees (0..80)
  double wordartContrast; // signed: >=0 light-on-dark, <0 dark-on-white (-1..1)
  double
  wordartPalette; // quantise to N colours; 64 = full (photo) colours (2..64)
  double wordartGround; // 0..1 ground / dark-floor brightness
  double wordartVivid; // 0..1 letter vividness
  double wordartEmpty; // 0..1 empty space (1 = leave dark areas bare)
  double wordartCoverage; // 0..1 pack whole phrases into gaps (denser subject)
  double wordartSaturate; // word-colour saturation boost (1.25..1.75)
  double wordartBrightness; // word-colour brightness boost (1..1.75)
  // Words take the exact photo colour; saturate/brightness don't apply while on.
  bool wordartTrueColor;
  String wordartCaption; // in-artwork photo title (upper-cased); '' = off
  String
  wordartTitleColor; // CSS colour ('#rrggbb'/'rgb(..)') for the title; '' = auto

  // ── Collage (a cut-and-paste pile of the photos; no base photo, each photo once).
  // Same keys as the web (lib/collage/), so a project opens the same on both.
  /// 'portrait' (2:3) | 'square' | 'landscape' (3:2).
  String collageFormat;

  /// Max tilt in degrees for cut-outs (whole photos tilt less).
  double collageRotation;

  /// White sticker outline around cut-outs, 0..1.
  double collageOutline;

  /// Drop shadow, 0..1.
  double collageShadow;

  /// '#rrggbb' shown between photos.
  String collageBackground;

  /// Per tile id: 'cutout' (cut out of its background) or 'full'.
  Map<String, String>? collageKinds;

  /// The centre piece's tile id.
  String? collageHero;

  /// Finished cut-outs by tile id — a photo is never cut twice.
  Map<String, CollageCut>? collageCuts;

  /// Output saturation grade applied to the FINISHED composite (tiles + tint), not to
  /// any single layer. 1 = untouched; above 1 punches the colour up. Same matrix the
  /// server applies via Sharp `.recomb()`, so preview / video / export all match.
  double outputSaturation;

  /// Tile recolouring 0..1: each tile's colours are moved toward its cell's colour in
  /// the base photo, keeping the tile's own detail (see `tileRecolorLinear` in
  /// tile_recolor.dart). Render-only, like tint. Mirrors web `MosaicSettings.tileRecolor`.
  double tileRecolor;

  /// Engine tuning, mirrors web `MosaicSettings` (hidden there too, not persisted):
  /// weight of the shape signal (`shapeDistance`), the no-repeat radius in cells
  /// (repeat_spacing.dart), and the global placement pass (optimal_placement.dart).
  double shapeMatch;
  int repeatSpacing;
  bool optimalPlacement;

  /// "Fit light to your photos": the matcher sees the photo's brightness ends squeezed
  /// into the library's range (tone_fit.dart). Opt-in, default off; a user choice, so it
  /// is persisted. Mirrors web `MosaicSettings.fitLightToLibrary`.
  bool fitLightToLibrary;

  /// One colour "look" over photo and tiles (looks.dart): 'none' or 'cinematic' (the
  /// app's switch); the web's admin looks are accepted too. Mirrors web `settings.look`.
  String look;

  /// Admin override for the simulated-annealing iteration budget. Null = use the
  /// per-platform default in `buildGridLayout`.
  double? saBudgetFactor;

  SignalWeights? signalWeights;

  MosaicSettings copyWith({
    MosaicMode? mosaicMode,
    double? density,
    double? outputWidth,
    double? reusePenalty,
    double? aspectWeight,
    double? detailWeight,
    double? minBlockSize,
    double? maxBlockSize,
    double? tintStrength,
    double? baseBlur,
    double? colorBoost,
    double? autoContrast,
    int? maxTileUses,
    Map<String, TileCrop>? tileCrops,
    double? ancientStoneSize,
    double? ancientGrout,
    double? ancientIrregularity,
    double? ancientVariation,
    double? ancientBevel,
    String? ancientGroutColor,
    double? ancientCurviness,
    String? ancientShape,
    double? wordartDensity,
    double? wordartRotation,
    double? wordartContrast,
    double? wordartPalette,
    double? wordartGround,
    double? wordartVivid,
    double? wordartEmpty,
    double? wordartCoverage,
    double? wordartSaturate,
    double? wordartBrightness,
    bool? wordartTrueColor,
    String? wordartCaption,
    String? wordartTitleColor,
    String? collageFormat,
    double? collageRotation,
    double? collageOutline,
    double? collageShadow,
    String? collageBackground,
    Map<String, String>? collageKinds,
    String? collageHero,
    Map<String, CollageCut>? collageCuts,
    double? outputSaturation,
    double? tileRecolor,
    double? shapeMatch,
    int? repeatSpacing,
    bool? optimalPlacement,
    bool? fitLightToLibrary,
    String? look,
    double? saBudgetFactor,
    SignalWeights? signalWeights,
  }) => MosaicSettings(
    mosaicMode: mosaicMode ?? this.mosaicMode,
    density: density ?? this.density,
    outputWidth: outputWidth ?? this.outputWidth,
    reusePenalty: reusePenalty ?? this.reusePenalty,
    aspectWeight: aspectWeight ?? this.aspectWeight,
    detailWeight: detailWeight ?? this.detailWeight,
    minBlockSize: minBlockSize ?? this.minBlockSize,
    maxBlockSize: maxBlockSize ?? this.maxBlockSize,
    tintStrength: tintStrength ?? this.tintStrength,
    baseBlur: baseBlur ?? this.baseBlur,
    colorBoost: colorBoost ?? this.colorBoost,
    autoContrast: autoContrast ?? this.autoContrast,
    maxTileUses: maxTileUses ?? this.maxTileUses,
    tileCrops: tileCrops ?? this.tileCrops,
    ancientStoneSize: ancientStoneSize ?? this.ancientStoneSize,
    ancientGrout: ancientGrout ?? this.ancientGrout,
    ancientIrregularity: ancientIrregularity ?? this.ancientIrregularity,
    ancientVariation: ancientVariation ?? this.ancientVariation,
    ancientBevel: ancientBevel ?? this.ancientBevel,
    ancientGroutColor: ancientGroutColor ?? this.ancientGroutColor,
    ancientCurviness: ancientCurviness ?? this.ancientCurviness,
    ancientShape: ancientShape ?? this.ancientShape,
    wordartDensity: wordartDensity ?? this.wordartDensity,
    wordartRotation: wordartRotation ?? this.wordartRotation,
    wordartContrast: wordartContrast ?? this.wordartContrast,
    wordartPalette: wordartPalette ?? this.wordartPalette,
    wordartGround: wordartGround ?? this.wordartGround,
    wordartVivid: wordartVivid ?? this.wordartVivid,
    wordartEmpty: wordartEmpty ?? this.wordartEmpty,
    wordartCoverage: wordartCoverage ?? this.wordartCoverage,
    wordartSaturate: wordartSaturate ?? this.wordartSaturate,
    wordartBrightness: wordartBrightness ?? this.wordartBrightness,
    wordartTrueColor: wordartTrueColor ?? this.wordartTrueColor,
    wordartCaption: wordartCaption ?? this.wordartCaption,
    wordartTitleColor: wordartTitleColor ?? this.wordartTitleColor,
    collageFormat: collageFormat ?? this.collageFormat,
    collageRotation: collageRotation ?? this.collageRotation,
    collageOutline: collageOutline ?? this.collageOutline,
    collageShadow: collageShadow ?? this.collageShadow,
    collageBackground: collageBackground ?? this.collageBackground,
    collageKinds: collageKinds ?? this.collageKinds,
    // '' clears the centre piece.
    collageHero: collageHero == null
        ? this.collageHero
        : (collageHero.isEmpty ? null : collageHero),
    collageCuts: collageCuts ?? this.collageCuts,
    outputSaturation: outputSaturation ?? this.outputSaturation,
    tileRecolor: tileRecolor ?? this.tileRecolor,
    shapeMatch: shapeMatch ?? this.shapeMatch,
    repeatSpacing: repeatSpacing ?? this.repeatSpacing,
    optimalPlacement: optimalPlacement ?? this.optimalPlacement,
    fitLightToLibrary: fitLightToLibrary ?? this.fitLightToLibrary,
    look: look ?? this.look,
    saBudgetFactor: saBudgetFactor ?? this.saBudgetFactor,
    signalWeights: signalWeights ?? this.signalWeights,
  );

  factory MosaicSettings.fromJson(Map<String, dynamic> j) => MosaicSettings(
    mosaicMode: j['mosaicMode'] as String,
    density: (j['density'] as num).toDouble(),
    outputWidth: (j['outputWidth'] as num).toDouble(),
    reusePenalty: (j['reusePenalty'] as num).toDouble(),
    aspectWeight: (j['aspectWeight'] as num).toDouble(),
    detailWeight: (j['detailWeight'] as num).toDouble(),
    minBlockSize: (j['minBlockSize'] as num).toDouble(),
    maxBlockSize: (j['maxBlockSize'] as num).toDouble(),
    tintStrength: (j['tintStrength'] as num).toDouble(),
    baseBlur: (j['baseBlur'] as num).toDouble(),
    colorBoost: (j['colorBoost'] as num).toDouble(),
    autoContrast: (j['autoContrast'] as num).toDouble(),
    maxTileUses: (j['maxTileUses'] as num?)?.toInt() ?? 0,
    ancientStoneSize: (j['ancientStoneSize'] as num?)?.toDouble() ?? 14,
    ancientGrout: (j['ancientGrout'] as num?)?.toDouble() ?? 1.4,
    ancientIrregularity: (j['ancientIrregularity'] as num?)?.toDouble() ?? 0.85,
    ancientVariation: (j['ancientVariation'] as num?)?.toDouble() ?? 0.12,
    ancientBevel: (j['ancientBevel'] as num?)?.toDouble() ?? 0.35,
    ancientGroutColor: j['ancientGroutColor'] as String? ?? 'dark',
    ancientCurviness: (j['ancientCurviness'] as num?)?.toDouble() ?? 0.55,
    ancientShape: j['ancientShape'] as String? ?? 'none',
    wordartDensity: (j['wordartDensity'] as num?)?.toDouble() ?? 43,
    wordartRotation: (j['wordartRotation'] as num?)?.toDouble() ?? 0,
    wordartContrast: (j['wordartContrast'] as num?)?.toDouble() ?? 1,
    wordartPalette: (j['wordartPalette'] as num?)?.toDouble() ?? 64,
    wordartGround: (j['wordartGround'] as num?)?.toDouble() ?? 0,
    wordartVivid: (j['wordartVivid'] as num?)?.toDouble() ?? 1,
    wordartEmpty: (j['wordartEmpty'] as num?)?.toDouble() ?? 1,
    wordartCoverage: (j['wordartCoverage'] as num?)?.toDouble() ?? 1,
    wordartSaturate: (j['wordartSaturate'] as num?)?.toDouble() ?? 1.5,
    wordartBrightness: (j['wordartBrightness'] as num?)?.toDouble() ?? 1.5,
    wordartTrueColor: j['wordartTrueColor'] as bool? ?? true,
    // The web stores the title as `wordartTitle`; older app saves used `wordartCaption`.
    wordartCaption:
        j['wordartTitle'] as String? ?? j['wordartCaption'] as String? ?? '',
    wordartTitleColor: j['wordartTitleColor'] as String? ?? '',
    collageFormat: j['collageFormat'] as String? ?? 'portrait',
    collageRotation: (j['collageRotation'] as num?)?.toDouble() ?? 12,
    collageOutline: (j['collageOutline'] as num?)?.toDouble() ?? 0.5,
    collageShadow: (j['collageShadow'] as num?)?.toDouble() ?? 0.5,
    collageBackground: j['collageBackground'] as String? ?? '#18181b',
    collageKinds: (j['collageKinds'] as Map?)?.map(
      (k, v) => MapEntry(k as String, v as String),
    ),
    collageHero: j['collageHero'] as String?,
    collageCuts: (j['collageCuts'] as Map?)?.map(
      (k, v) => MapEntry(
        k as String,
        CollageCut.fromJson((v as Map).cast<String, dynamic>()),
      ),
    ),
    outputSaturation: (j['outputSaturation'] as num?)?.toDouble() ?? 1,
    tileRecolor: (j['tileRecolor'] as num?)?.toDouble() ?? 1,
    shapeMatch: (j['shapeMatch'] as num?)?.toDouble() ?? 0.5,
    repeatSpacing: (j['repeatSpacing'] as num?)?.round() ?? 2,
    optimalPlacement: j['optimalPlacement'] as bool? ?? true,
    fitLightToLibrary: j['fitLightToLibrary'] == true,
    look: j['look'] as String? ?? 'none',
    saBudgetFactor: (j['saBudgetFactor'] as num?)?.toDouble(),
    signalWeights: j['signalWeights'] == null
        ? null
        : SignalWeights.fromJson(
            (j['signalWeights'] as Map).cast<String, dynamic>(),
          ),
  );

  Map<String, dynamic> toJson() => {
    'mosaicMode': mosaicMode,
    'density': density,
    'outputWidth': outputWidth,
    'reusePenalty': reusePenalty,
    'aspectWeight': aspectWeight,
    'detailWeight': detailWeight,
    'minBlockSize': minBlockSize,
    'maxBlockSize': maxBlockSize,
    'tintStrength': tintStrength,
    'baseBlur': baseBlur,
    'colorBoost': colorBoost,
    'autoContrast': autoContrast,
    'maxTileUses': maxTileUses,
    'ancientStoneSize': ancientStoneSize,
    'ancientGrout': ancientGrout,
    'ancientIrregularity': ancientIrregularity,
    'ancientVariation': ancientVariation,
    'ancientBevel': ancientBevel,
    'ancientGroutColor': ancientGroutColor,
    'ancientCurviness': ancientCurviness,
    'ancientShape': ancientShape,
    'wordartDensity': wordartDensity,
    'wordartRotation': wordartRotation,
    'wordartContrast': wordartContrast,
    'wordartPalette': wordartPalette,
    'wordartGround': wordartGround,
    'wordartVivid': wordartVivid,
    'wordartEmpty': wordartEmpty,
    'wordartCoverage': wordartCoverage,
    'wordartSaturate': wordartSaturate,
    'wordartBrightness': wordartBrightness,
    'wordartTrueColor': wordartTrueColor,
    'wordartTitle': wordartCaption,
    'wordartCaption': wordartCaption,
    'wordartTitleColor': wordartTitleColor,
    'collageFormat': collageFormat,
    'collageRotation': collageRotation,
    'collageOutline': collageOutline,
    'collageShadow': collageShadow,
    'collageBackground': collageBackground,
    if (collageKinds != null) 'collageKinds': collageKinds,
    if (collageHero != null) 'collageHero': collageHero,
    if (collageCuts != null)
      'collageCuts': collageCuts!.map((k, v) => MapEntry(k, v.toJson())),
    'outputSaturation': outputSaturation,
    'tileRecolor': tileRecolor,
    'fitLightToLibrary': fitLightToLibrary,
    if (look != 'none') 'look': look,
    if (saBudgetFactor != null) 'saBudgetFactor': saBudgetFactor,
    // NOT persisted: engine tuning, not user content. See
    // ProjectsApi._parseSettings — writing these froze old tuning into saved
    // projects, which is the opposite of what a tuning change is for.
    if (signalWeights != null) 'signalWeights': signalWeights?.toJson(),
  };
}

class TileDescriptor {
  TileDescriptor({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.aspectRatio,
    required this.orientation,
    required this.averageColor,
    required this.averageLabColor,
    required this.detailScore,
    required this.subregionColors,
    required this.subregionEdges,
    required this.contrastMap,
    required this.luminanceBalance,
    required this.colorVariance,
    required this.edgeOrientation,
    required this.tonalHistogram,
    required this.subregionEdgeOrientations,
  });

  String id;
  String name;
  double width;
  double height;
  double aspectRatio;
  TileOrientation orientation;
  RgbColor averageColor;
  LabColor averageLabColor;
  double detailScore;
  SubregionColors? subregionColors;
  SubregionEdges? subregionEdges;
  ContrastMap? contrastMap;
  LuminanceBalance? luminanceBalance;
  double colorVariance;
  double edgeOrientation;
  LuminanceHistogram? tonalHistogram;
  SubregionEdgeOrientations? subregionEdgeOrientations;

  /// The inverse of [TileDescriptor.fromJson], for the on-device analysis cache.
  /// Doubles survive the round trip exactly (Dart prints the shortest exact form).
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'aspectRatio': aspectRatio,
    'orientation': orientation,
    'averageColor': averageColor.toJson(),
    'averageLabColor': averageLabColor.toJson(),
    'detailScore': detailScore,
    'subregionColors': subregionColors?.map((c) => c.toJson()).toList(),
    'subregionEdges': subregionEdges,
    'contrastMap': contrastMap,
    'luminanceBalance': luminanceBalance?.toJson(),
    'colorVariance': colorVariance,
    'edgeOrientation': edgeOrientation,
    'tonalHistogram': tonalHistogram,
    'subregionEdgeOrientations': subregionEdgeOrientations,
  };

  factory TileDescriptor.fromJson(Map<String, dynamic> j) => TileDescriptor(
    id: j['id'] as String,
    name: j['name'] as String,
    width: (j['width'] as num).toDouble(),
    height: (j['height'] as num).toDouble(),
    aspectRatio: (j['aspectRatio'] as num).toDouble(),
    orientation: j['orientation'] as String,
    averageColor: RgbColor.fromJson(
      (j['averageColor'] as Map).cast<String, dynamic>(),
    ),
    averageLabColor: LabColor.fromJson(
      (j['averageLabColor'] as Map).cast<String, dynamic>(),
    ),
    detailScore: (j['detailScore'] as num).toDouble(),
    subregionColors: _labList(j['subregionColors']),
    subregionEdges: _doubleList(j['subregionEdges']),
    contrastMap: _doubleList(j['contrastMap']),
    luminanceBalance: j['luminanceBalance'] == null
        ? null
        : LuminanceBalance.fromJson(
            (j['luminanceBalance'] as Map).cast<String, dynamic>(),
          ),
    colorVariance: (j['colorVariance'] as num).toDouble(),
    edgeOrientation: (j['edgeOrientation'] as num).toDouble(),
    tonalHistogram: _doubleList(j['tonalHistogram']),
    subregionEdgeOrientations: _floatList(j['subregionEdgeOrientations']),
  );
}

List<LabColor>? _labList(dynamic v) => v == null
    ? null
    : (v as List)
          .map((e) => LabColor.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false);

List<double>? _doubleList(dynamic v) => v == null
    ? null
    : Float64List.fromList([for (final e in v as List) (e as num).toDouble()]);

Float32List? _floatList(dynamic v) => v == null
    ? null
    : Float32List.fromList(
        (v as List).map((e) => (e as num).toDouble()).toList(),
      );

class RegionAnalysis {
  RegionAnalysis({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.averageColor,
    required this.averageLabColor,
    required this.detailScore,
    required this.subregionColors,
    required this.subregionEdges,
    required this.contrastMap,
    required this.luminanceBalance,
    required this.colorVariance,
    required this.edgeOrientation,
    required this.tonalHistogram,
    required this.subregionEdgeOrientations,
  });

  double x;
  double y;
  double width;
  double height;
  RgbColor averageColor;
  LabColor averageLabColor;
  double detailScore;
  SubregionColors subregionColors;
  SubregionEdges subregionEdges;
  ContrastMap contrastMap;
  LuminanceBalance luminanceBalance;
  double colorVariance;
  double edgeOrientation;
  LuminanceHistogram tonalHistogram;
  SubregionEdgeOrientations subregionEdgeOrientations;

  factory RegionAnalysis.fromJson(Map<String, dynamic> j) => RegionAnalysis(
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    width: (j['width'] as num).toDouble(),
    height: (j['height'] as num).toDouble(),
    averageColor: RgbColor.fromJson(
      (j['averageColor'] as Map).cast<String, dynamic>(),
    ),
    averageLabColor: LabColor.fromJson(
      (j['averageLabColor'] as Map).cast<String, dynamic>(),
    ),
    detailScore: (j['detailScore'] as num).toDouble(),
    subregionColors: _labList(j['subregionColors'])!,
    subregionEdges: _doubleList(j['subregionEdges'])!,
    contrastMap: _doubleList(j['contrastMap'])!,
    luminanceBalance: LuminanceBalance.fromJson(
      (j['luminanceBalance'] as Map).cast<String, dynamic>(),
    ),
    colorVariance: (j['colorVariance'] as num).toDouble(),
    edgeOrientation: (j['edgeOrientation'] as num).toDouble(),
    tonalHistogram: _doubleList(j['tonalHistogram'])!,
    subregionEdgeOrientations: _floatList(j['subregionEdgeOrientations'])!,
  );

  /// Builds a placement from this region with an assigned tile.
  MosaicPlacement toPlacement(
    int index,
    String tileId,
    String tileName,
    double score,
  ) => MosaicPlacement(
    x: x,
    y: y,
    width: width,
    height: height,
    averageColor: averageColor,
    averageLabColor: averageLabColor,
    detailScore: detailScore,
    subregionColors: subregionColors,
    subregionEdges: subregionEdges,
    contrastMap: contrastMap,
    luminanceBalance: luminanceBalance,
    colorVariance: colorVariance,
    edgeOrientation: edgeOrientation,
    tonalHistogram: tonalHistogram,
    subregionEdgeOrientations: subregionEdgeOrientations,
    index: index,
    tileId: tileId,
    tileName: tileName,
    score: score,
  );
}

/// RegionAnalysis & { index, tileId, tileName, score }
class MosaicPlacement extends RegionAnalysis {
  MosaicPlacement({
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required super.averageColor,
    required super.averageLabColor,
    required super.detailScore,
    required super.subregionColors,
    required super.subregionEdges,
    required super.contrastMap,
    required super.luminanceBalance,
    required super.colorVariance,
    required super.edgeOrientation,
    required super.tonalHistogram,
    required super.subregionEdgeOrientations,
    required this.index,
    required this.tileId,
    required this.tileName,
    required this.score,
    this.quad,
    this.face,
  });

  int index;
  String tileId;
  String tileName;
  double score;

  /// `rhombille` only: the cell is a PARALLELOGRAM, not the axis-aligned rect that
  /// x/y/width/height describe — those hold only the matcher's SAMPLE rect. Eight
  /// numbers, four corners clockwise from the transform origin.
  List<double>? quad;

  /// `rhombille` only: which cube face, for the lighting multiplier.
  String? face;
}

class SlimPlacement {
  SlimPlacement({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.tileId,
    this.regionAvgColor,
    this.quad,
    this.face,
    this.regionGrid,
  });

  int index;
  double x;
  double y;
  double width;
  double height;
  String tileId;

  /// The photo's 5×5 colours under the cell (RGB, 75 values, row-major) — what the
  /// in-cell tile recolour follows (local_recolor.dart). App-only: never sent to the
  /// server (the export samples the photo itself). Null = flat recolour to the average.
  Float64List? regionGrid;

  /// [r, g, b] 0-255 average of the matched region (optional color nudge).
  List<double>? regionAvgColor;

  /// `rhombille` only: the cell is a PARALLELOGRAM, not the axis-aligned rect that
  /// x/y/width/height describe — those hold only the matcher's SAMPLE rect. Eight
  /// numbers, four corners clockwise from the transform origin.
  List<double>? quad;

  /// `rhombille` only: which cube face, for the lighting multiplier.
  String? face;

  Map<String, dynamic> toJson() => {
    'index': index,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'tileId': tileId,
    if (regionAvgColor != null) 'regionAvgColor': regionAvgColor,
    // 3D cubes: the cell is a parallelogram, and x/y/width/height describe only the
    // matcher's sample rect. Without these the export falls back to rectangles and
    // silently loses the whole effect.
    if (quad != null) 'quad': quad,
    if (face != null) 'face': face,
  };
}

class MosaicPlan {
  MosaicPlan({
    required this.baseWidth,
    required this.baseHeight,
    required this.outputWidth,
    required this.outputHeight,
    required this.tintStrength,
    required this.baseBlur,
    required this.placements,
    this.outputSaturation = 1.0,
  });

  double baseWidth;
  double baseHeight;
  double outputWidth;
  double outputHeight;
  double tintStrength;
  double baseBlur;

  /// See [MosaicSettings.outputSaturation]. 1 = untouched.
  double outputSaturation;
  List<MosaicPlacement> placements;
}

/// A user-chosen crop for one tile, as a fraction of the tile's natural size
/// (`0..1`, x/y = top-left).
///
/// NON-DESTRUCTIVE: the uploaded file is never touched — this is metadata the
/// renderers read when drawing, so a crop can be changed or cleared at any time and
/// every output follows, preview and high-res export alike.
///
/// Absent = the automatic crop (square layout anchors portrait tiles to the top,
/// everything else centres). The JSON shape mirrors the web `TileCrop` exactly: the
/// same map travels inside the plan to the server compositor.
class TileCrop {
  const TileCrop(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;

  factory TileCrop.fromJson(Map<String, dynamic> j) => TileCrop(
    (j['x'] as num).toDouble(),
    (j['y'] as num).toDouble(),
    (j['w'] as num).toDouble(),
    (j['h'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  /// Value equality so a painter can tell "same crop" from "new crop" — the
  /// preview repaints off exactly this comparison.
  @override
  bool operator ==(Object other) =>
      other is TileCrop &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);
}

class SlimMosaicPlan {
  SlimMosaicPlan({
    required this.baseWidth,
    required this.baseHeight,
    required this.outputWidth,
    required this.outputHeight,
    required this.tintStrength,
    required this.baseBlur,
    required this.placements,
    this.cropPortraitTop = false,
    this.hexagon = false,
    this.outputSaturation = 1.0,
    this.tileRecolor = 0,
    this.tileCrops = const {},
    this.look = 'none',
  });

  double baseWidth;
  double baseHeight;
  double outputWidth;
  double outputHeight;
  double tintStrength;
  double baseBlur;
  List<SlimPlacement> placements;

  /// Square layout only: crop PORTRAIT tiles to the top (keeps faces/heads) instead of
  /// the centre; landscape tiles stay centre-cropped. Honoured by the on-device preview
  /// painters AND sent to the server compositor (which reads the same flag).
  bool cropPortraitTop;

  /// `hexagon` mode: every cell is a flat-top regular hexagon, and x/y/width/height is
  /// its SAMPLE rect — the hexagon itself is reconstructed from that rect (see
  /// `hexFromRect`). A plan-level flag rather than a per-placement one because a plan is
  /// never mixed, and a per-cell marker would add a field to thousands of placements in
  /// the render payload for no information.
  ///
  /// Without this the server draws each sample rect as a RECTANGLE and leaves the space
  /// between them black — a mosaic of floating tiles, not a honeycomb.
  bool hexagon;

  /// Output saturation grade over the FINISHED composite (see
  /// [MosaicSettings.outputSaturation]). Sent to the server compositor so the
  /// high-res export carries the same grade as the on-device preview.
  double outputSaturation;

  /// Tile recolouring strength (see [MosaicSettings.tileRecolor]). Sent to the server
  /// compositor, which applies the same transform, so the export matches the preview.
  double tileRecolor;

  /// Per-tile manual crops, keyed by BASE tile id (see [TileCrop]). Overrides
  /// [cropPortraitTop] for the tiles listed; absent tiles keep the automatic crop.
  /// Travels to the server inside the plan, so the export is framed exactly as the
  /// preview is.
  Map<String, TileCrop> tileCrops;

  /// The look (looks.dart) the finished picture is graded with — after the saturation
  /// grade, by the preview here and by the server for the export.
  String look;

  Map<String, dynamic> toJson() => {
    'baseWidth': baseWidth,
    'baseHeight': baseHeight,
    'outputWidth': outputWidth,
    'outputHeight': outputHeight,
    'tintStrength': tintStrength,
    'baseBlur': baseBlur,
    'cropPortraitTop': cropPortraitTop,
    if (hexagon) 'hexagon': true,
    'outputSaturation': outputSaturation,
    if (tileRecolor > 0) 'tileRecolor': tileRecolor,
    // Which recolour this build previews (3 = tile contrast kept, brightening uncapped,
    // half the colour shift). The server keeps each older recolour for older builds:
    // 2 = 1.10.9+57, nothing = ≤ 1.10.8+56.
    'recolorVersion': 3,
    if (look != 'none') 'look': look,
    // Omitted when empty — the server treats absent as "all automatic".
    if (tileCrops.isNotEmpty)
      'tileCrops': {for (final e in tileCrops.entries) e.key: e.value.toJson()},
    'placements': placements.map((p) => p.toJson()).toList(),
  };
}

class RenderPlacement {
  RenderPlacement({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  int index;
  double x;
  double y;
  double width;
  double height;
}

class FaceRect {
  FaceRect(this.x, this.y, this.width, this.height);
  double x;
  double y;
  double width;
  double height;
}
