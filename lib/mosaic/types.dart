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

  factory RgbColor.fromJson(Map<String, dynamic> j) =>
      RgbColor((j['r'] as num).toDouble(), (j['g'] as num).toDouble(),
          (j['b'] as num).toDouble());

  Map<String, dynamic> toJson() => {'r': r, 'g': g, 'b': b};
}

class LabColor {
  LabColor(this.L, this.a, this.b);
  double L;
  double a;
  double b;

  factory LabColor.fromJson(Map<String, dynamic> j) =>
      LabColor((j['L'] as num).toDouble(), (j['a'] as num).toDouble(),
          (j['b'] as num).toDouble());

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
      (j['vertical'] as num).toDouble(), (j['horizontal'] as num).toDouble());

  Map<String, dynamic> toJson() =>
      {'vertical': vertical, 'horizontal': horizontal};
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
    this.signalWeights,
  });

  MosaicMode mosaicMode;
  double density;
  double outputWidth;
  double reusePenalty;
  double aspectWeight;
  double detailWeight;
  double minBlockSize;
  double maxBlockSize;
  double tintStrength;
  double baseBlur;
  double colorBoost;
  double autoContrast;
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
    SignalWeights? signalWeights,
  }) =>
      MosaicSettings(
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
        signalWeights: j['signalWeights'] == null
            ? null
            : SignalWeights.fromJson(
                (j['signalWeights'] as Map).cast<String, dynamic>()),
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
        'signalWeights': signalWeights?.toJson(),
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

  factory TileDescriptor.fromJson(Map<String, dynamic> j) => TileDescriptor(
        id: j['id'] as String,
        name: j['name'] as String,
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        aspectRatio: (j['aspectRatio'] as num).toDouble(),
        orientation: j['orientation'] as String,
        averageColor:
            RgbColor.fromJson((j['averageColor'] as Map).cast<String, dynamic>()),
        averageLabColor: LabColor.fromJson(
            (j['averageLabColor'] as Map).cast<String, dynamic>()),
        detailScore: (j['detailScore'] as num).toDouble(),
        subregionColors: _labList(j['subregionColors']),
        subregionEdges: _doubleList(j['subregionEdges']),
        contrastMap: _doubleList(j['contrastMap']),
        luminanceBalance: j['luminanceBalance'] == null
            ? null
            : LuminanceBalance.fromJson(
                (j['luminanceBalance'] as Map).cast<String, dynamic>()),
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
        .toList();

List<double>? _doubleList(dynamic v) =>
    v == null ? null : (v as List).map((e) => (e as num).toDouble()).toList();

Float32List? _floatList(dynamic v) => v == null
    ? null
    : Float32List.fromList(
        (v as List).map((e) => (e as num).toDouble()).toList());

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
        averageColor:
            RgbColor.fromJson((j['averageColor'] as Map).cast<String, dynamic>()),
        averageLabColor: LabColor.fromJson(
            (j['averageLabColor'] as Map).cast<String, dynamic>()),
        detailScore: (j['detailScore'] as num).toDouble(),
        subregionColors: _labList(j['subregionColors'])!,
        subregionEdges: _doubleList(j['subregionEdges'])!,
        contrastMap: _doubleList(j['contrastMap'])!,
        luminanceBalance: LuminanceBalance.fromJson(
            (j['luminanceBalance'] as Map).cast<String, dynamic>()),
        colorVariance: (j['colorVariance'] as num).toDouble(),
        edgeOrientation: (j['edgeOrientation'] as num).toDouble(),
        tonalHistogram: _doubleList(j['tonalHistogram'])!,
        subregionEdgeOrientations: _floatList(j['subregionEdgeOrientations'])!,
      );

  /// Builds a placement from this region with an assigned tile.
  MosaicPlacement toPlacement(
          int index, String tileId, String tileName, double score) =>
      MosaicPlacement(
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
  });

  int index;
  String tileId;
  String tileName;
  double score;
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
  });

  int index;
  double x;
  double y;
  double width;
  double height;
  String tileId;

  /// [r, g, b] 0-255 average of the matched region (optional color nudge).
  List<double>? regionAvgColor;

  Map<String, dynamic> toJson() => {
        'index': index,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'tileId': tileId,
        if (regionAvgColor != null) 'regionAvgColor': regionAvgColor,
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
  });

  double baseWidth;
  double baseHeight;
  double outputWidth;
  double outputHeight;
  double tintStrength;
  double baseBlur;
  List<MosaicPlacement> placements;
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
  });

  double baseWidth;
  double baseHeight;
  double outputWidth;
  double outputHeight;
  double tintStrength;
  double baseBlur;
  List<SlimPlacement> placements;

  Map<String, dynamic> toJson() => {
        'baseWidth': baseWidth,
        'baseHeight': baseHeight,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'tintStrength': tintStrength,
        'baseBlur': baseBlur,
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
