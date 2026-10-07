import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ColorFilter;

import 'types.dart';

/// Dart port of `foto-mozaik/lib/mosaic/shared.ts` (pure math + helpers).
/// Browser-only helpers (isMobileDevice, yieldToMain, debug timing) are omitted.

const double minDensity = 12;
const double maxDensity = 1000;
const double minOutputWidth = 1200;
const double maxOutputWidth = 25000;

/// Same factor as canvas blur; used by the render overlay.
const double overlayBlurCellFactor = 0.7;

/// Average cells one photo occupies in `original` mode.
///
/// MEASURED on the web bench, not assumed: with the fill-first layout the mix is
/// dominated by 1x1 cells, so a photo covers ~1.3 cells, not the 3.0 the old
/// shapes-first layout produced. A wrong value here is invisible in the mosaic and
/// only shows up as the density slider disagreeing with the result.
///
/// Must match ORIGINAL_CELLS_PER_TILE in foto-mozaik/lib/mosaic/density.ts.
const double _originalCellsPerTile = 1.3;
const double _minTilesOriginalThreshold = 250;

/// Output-saturation slider bounds. 1 = untouched (the floor); above 1 punches up.
const double minOutputSaturation = 1.0;
const double maxOutputSaturation = 1.5;

// ── JS-faithful numeric helpers ─────────────────────────────────────────────

double clampD(double value, double min, double max) =>
    math.min(max, math.max(min, value));

/// Replicates JavaScript `Math.round`, which rounds half toward +Infinity
/// (`floor(x + 0.5)`). Dart's `double.round()` rounds half away from zero and
/// would diverge on negative .5 values.
double jsRound(double x) => (x + 0.5).floorToDouble();

double roundChannel(double value) => clampD(jsRound(value), 0, 255);

/// Cube root approximating `Math.cbrt`. Dart lacks a native cbrt; `pow(t,1/3)`
/// alone is ~2-4 ULP off, so we refine with one Newton step toward the true
/// root (x − (x³−a)/(3x²)), bringing it to ≤1 ULP — within libm noise of V8.
double _cbrt(double t) {
  if (t == 0) return 0.0;
  final neg = t < 0;
  final a = neg ? -t : t;
  var x = math.pow(a, 1.0 / 3.0).toDouble();
  x = x - (x * x * x - a) / (3 * x * x);
  return neg ? -x : x;
}

// ── Defaults ────────────────────────────────────────────────────────────────

// Structure-leaning (measured on web): raised luminance/edge/contrast, lowered
// colour — tiles "fit the shape" better (raw-composition SSIM 0.424 vs 0.410),
// and the colour gap is closed by tint + transfer downstream. Mirrors the web
// DEFAULT_SIGNAL_WEIGHTS.
SignalWeights defaultSignalWeights() => SignalWeights(
  color: 0.45, // was 0.55
  luminancePattern: 0.22, // was 0.15
  chromaPattern: 0.06,
  edgePattern: 0.18, // was 0.12
  tonalHistogram: 0.05,
  // Light/dark counts this much more than hue when scoring a tile.
  //
  // Raised from 3.5 to the ceiling. Recognising the subject in a mosaic is almost
  // entirely a light/dark judgement, and with a fixed library the tonal range is
  // the binding constraint — so it is worth spending hue accuracy to place tone
  // correctly. Measured on a coarse luminance comparison against the original:
  // 200 photos 5.60 → 4.04, 3000 photos 3.50 → 2.57, 32 photos 7.01 → 6.65.
  // Small libraries gain least: no weighting conjures a tone they do not contain.
  // Must match shared.ts.
  brightnessEmphasis: 5.0,
  contrastPattern: 0.12, // was 0.08
);

/// The one variety value. See sanitizeSettings for why this is no longer a choice.
const double fixedReusePenalty = 0.01;

/// The smallest cap on per-photo reuse that can actually be satisfied.
///
/// Every cell must hold something, so with [cells] cells and [tiles] photos at least one
/// photo has to appear ceil(cells / tiles) times. A lower cap is not a stricter setting,
/// it is an impossible one — it leaves the matcher with no legal photo for some cells.
int minFeasibleTileUses(int tiles, int cells) {
  if (tiles <= 0) return 1;
  return math.max(1, (cells / tiles).ceil());
}

/// `maxTileUses` sentinel — "Max 3": no photo more than [limitedRepeatsMax] times, or the
/// fewest the library allows when that is higher. Mirrors web `EVEN_TILE_USES`.
///
/// Resolved against the live cell count on every build, so it keeps its meaning when the
/// density changes underneath it. (The name predates the 3-use floor; the stored value
/// is unchanged, so saved projects keep working.)
const int evenTileUses = -1;

/// Most uses per photo under "Max 3". Not 1 even when the library is big enough:
/// measured on 2000 photos over ~1600 cells, a cap of 1 made the colour error 2.5×
/// worse (0.060 → 0.156); 3 measured 0.069 — indistinguishable from unlimited.
const int limitedRepeatsMax = 3;

/// `maxTileUses` sentinel — "Unique": every photo at most once when the library has at
/// least as many photos as cells; the floor (cells / photos) when it has fewer. Mirrors
/// web `UNIQUE_TILE_USES`.
const int uniqueTileUses = -2;

/// The cap actually applied. 0 means unlimited; [evenTileUses] means [limitedRepeatsMax]
/// or the feasible floor when higher; [uniqueTileUses] means the feasible floor.
///
/// Raising rather than rejecting an impossible value matters because this arrives from
/// saved projects and the API as well as from the UI: a project saved with 30 photos and
/// reopened after 20 were deleted would otherwise stop building at all.
int resolveMaxTileUses(int? maxTileUses, int tiles, int cells) {
  if (maxTileUses == uniqueTileUses) {
    if (tiles <= 0 || cells <= 0) return 0;
    return minFeasibleTileUses(tiles, cells);
  }
  if (maxTileUses == evenTileUses) {
    // The sentinel is a RATIO, so it cannot be resolved without both counts. Some scorer
    // call sites leave them out, and there minFeasibleTileUses(0, 0) answers 1 — a cap of
    // one cell per photo, which sends every placement through the at-capacity fallback
    // and wrecks the mosaic. Unknown counts mean unlimited: the same answer this gave
    // before the sentinel existed, and the safe direction to be wrong in.
    if (tiles <= 0 || cells <= 0) return 0;
    return math.max(limitedRepeatsMax, minFeasibleTileUses(tiles, cells));
  }
  if (maxTileUses == null || maxTileUses <= 0) return 0;
  return math.max(maxTileUses, minFeasibleTileUses(tiles, cells));
}

MosaicSettings defaultSettings() => MosaicSettings(
  mosaicMode: 'square',
  density: 180,
  outputWidth: 8000,
  reusePenalty: fixedReusePenalty,
  aspectWeight: 0.08,
  detailWeight: 0.05,
  minBlockSize: 4,
  maxBlockSize: 10,
  tintStrength: 0.4,
  baseBlur: 1,
  colorBoost: 1.0,
  autoContrast: 0,
  maxTileUses: 0, // unlimited
  outputSaturation: 1.2,
  signalWeights: defaultSignalWeights(),
);

/// Luminance-preserving saturation matrix (the SVG/CSS `saturate()` matrix, Rec.709
/// weights) as a Flutter 4x5 colour matrix. Shared so the preview painters, the loupe
/// and the video all run the SAME maths the server compositor runs via Sharp
/// `.recomb()` — see `foto-mozaik/lib/mosaic/shared.ts: saturationMatrix`.
///
/// Returns null at s == 1 so callers can skip the layer entirely (the default-off path
/// costs nothing).
ColorFilter? saturationColorFilter(double saturation) {
  final s = clampD(saturation, minOutputSaturation, maxOutputSaturation);
  if (s == 1) return null;
  const r = 0.213, g = 0.715, b = 0.072;
  return ColorFilter.matrix(<double>[
    r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
    r - r * s, g + (1 - g) * s, b - b * s, 0, 0, //
    r - r * s, g - g * s, b + (1 - b) * s, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);
}

/// Cells a density value produces. Mirrors `densityToCells` in
/// foto-mozaik/lib/mosaic/density.ts.
double densityToCells(double density) =>
    jsRound(math.pow(density / 4, 2).toDouble() * 1.4);

/// Bounds on the adaptive variety value — see [adaptiveReusePenalty].
const double varietyMin = 0.015;
const double varietyMax = 0.25;

/// How hard to push photos apart, chosen from the size of the library.
///
/// A fixed default cannot be right for every library, because the setting is really
/// answering "how many times will each photo have to be reused?" — and that is
/// cells / photos, which spans three orders of magnitude between a twelve-photo album
/// and a three-thousand-photo camera roll. Measured across libraries at ~1500 cells:
///
///     photos   cells/photo   good value   what the old fixed 0.01 gave
///     3000        0.5          0.015      fine (0% repeats)
///      200        7.4          0.015      fine (0.6% repeats)
///       32       46            0.05       12% repeats, one photo used 199x
///       12      121            0.25       58% repeats, 1906 touching twins
///
/// The curve is fitted through those last two anchors and is steeper than linear,
/// because the small-library end has a cliff: at twelve photos, 0.1 still leaves 1317
/// touching twins and 0.25 leaves none. A straight line would clear that cliff only by
/// overcharging the middle of the range.
///
/// Must match `adaptiveReusePenalty` in foto-mozaik/lib/mosaic/density.ts.
double adaptiveReusePenalty(int photoCount, double cellCount) {
  if (photoCount <= 0 || cellCount <= 0) return varietyMin;
  final cellsPerPhoto = cellCount / photoCount;
  final fitted = 0.05 * math.pow(cellsPerPhoto / 46, 1.66).toDouble();
  return math.min(varietyMax, math.max(varietyMin, fitted));
}

bool isMinimumDetailOriginalMode(MosaicSettings settings) {
  if (settings.mosaicMode != 'original') return false;
  final cells = jsRound(math.pow(settings.density / 4, 2).toDouble() * 1.4);
  final tiles = jsRound(cells / _originalCellsPerTile);
  return tiles <= _minTilesOriginalThreshold;
}

TileOrientation getOrientation(double width, double height) {
  final ratio = width / height;
  if (ratio > 1.1) return 'landscape';
  if (ratio < 0.9) return 'portrait';
  return 'square';
}

MosaicSettings sanitizeSettings(MosaicSettings input) {
  final minBlockSize = clampD(jsRound(input.minBlockSize), 2, 10);
  final maxBlockSize = clampD(jsRound(input.maxBlockSize), 6, 18);

  final sw = input.signalWeights;
  final signalWeights = sw != null
      ? SignalWeights(
          color: clampD(sw.color, 0, 1),
          luminancePattern: clampD(sw.luminancePattern, 0, 1),
          chromaPattern: clampD(sw.chromaPattern, 0, 1),
          edgePattern: clampD(sw.edgePattern, 0, 1),
          tonalHistogram: clampD(sw.tonalHistogram, 0, 1),
          brightnessEmphasis: clampD(sw.brightnessEmphasis, 0, 5),
          contrastPattern: clampD(sw.contrastPattern, 0, 1),
        )
      : defaultSignalWeights();

  // MUST list every mode the studio can actually select. An unlisted mode is not
  // rejected loudly — it silently becomes 'original', so picking "3D" or "Hexagons"
  // quietly produced an ordinary mosaic with no error anywhere to explain it.
  const validModes = [
    'original',
    'blocks',
    'square',
    'landscape',
    'portrait',
    'rhombille',
    'hexagon',
    'ancient',
    'ancient-curved',
    'wordart',
  ];
  const validGrout = ['dark', 'stone', 'light'];
  const validAncientShape = ['none', 'heart', 'basketball', 'flower'];

  return MosaicSettings(
    mosaicMode: validModes.contains(input.mosaicMode)
        ? input.mosaicMode
        : 'original',
    density: clampD(jsRound(input.density), minDensity, maxDensity),
    outputWidth: clampD(
      jsRound(input.outputWidth),
      minOutputWidth,
      maxOutputWidth,
    ),
    // PINNED. Measured across 12 / 67 / 200 / 3000-photo libraries, a flat 0.01 matches
    // or beats the adaptive value it replaces. The adaptive scheme existed to soften a
    // neighbour-duplicate penalty strong enough to ban local reuse; with that corrected
    // there is nothing left to soften. Input ignored, so saved projects land here too.
    reusePenalty: fixedReusePenalty,
    aspectWeight: clampD(input.aspectWeight, 0, 1),
    detailWeight: clampD(input.detailWeight, 0, 1),
    minBlockSize: math.min(minBlockSize, maxBlockSize - 2),
    maxBlockSize: math.max(maxBlockSize, minBlockSize + 2),
    tintStrength: clampD(input.tintStrength, 0, 0.5),
    baseBlur: clampD(input.baseBlur, 0, 5),
    colorBoost: clampD(input.colorBoost, 1.0, 2.0),
    autoContrast: clampD(input.autoContrast, 0, 1),
    // Clamped to 0 EXCEPT the sentinels, which are negative on purpose — rounding them
    // away here would turn "Max 3" / "Unique" back into "unlimited" on every reload.
    // Passed through, not validated: `resolveTileSourceRect` clamps every crop at the
    // point of use, so a stale one cannot produce an out-of-bounds read here either.
    tileCrops: input.tileCrops,
    maxTileUses:
        input.maxTileUses == evenTileUses || input.maxTileUses == uniqueTileUses
        ? input.maxTileUses
        : math.max(0, input.maxTileUses),
    outputSaturation: clampD(
      input.outputSaturation,
      minOutputSaturation,
      maxOutputSaturation,
    ),
    ancientStoneSize: clampD(input.ancientStoneSize, 7, 34),
    ancientGrout: clampD(input.ancientGrout, 0, 4),
    ancientIrregularity: clampD(input.ancientIrregularity, 0, 1),
    ancientVariation: clampD(input.ancientVariation, 0, 0.35),
    ancientBevel: clampD(input.ancientBevel, 0, 0.7),
    ancientGroutColor: validGrout.contains(input.ancientGroutColor)
        ? input.ancientGroutColor
        : 'dark',
    ancientCurviness: clampD(input.ancientCurviness, 0, 1),
    ancientShape: validAncientShape.contains(input.ancientShape)
        ? input.ancientShape
        : 'none',
    wordartDensity: clampD(input.wordartDensity, 18, 100),
    wordartRotation: clampD(input.wordartRotation, 0, 80),
    wordartContrast: clampD(input.wordartContrast, -1, 1),
    wordartPalette: clampD(jsRound(input.wordartPalette), 2, 64),
    wordartGround: clampD(input.wordartGround, 0, 1),
    wordartVivid: clampD(input.wordartVivid, 0, 1),
    wordartEmpty: clampD(input.wordartEmpty, 0, 1),
    signalWeights: signalWeights,
  );
}

double getOutputHeight(
  double baseWidth,
  double baseHeight,
  double outputWidth,
) => math.max(1, jsRound(outputWidth * baseHeight / baseWidth));

List<RenderPlacement> scalePlacements(
  MosaicPlan plan,
  double targetWidth,
  double targetHeight,
) {
  final scaleX = targetWidth / plan.baseWidth;
  final scaleY = targetHeight / plan.baseHeight;
  return plan.placements.map((p) {
    final x = jsRound(p.x * scaleX);
    final y = jsRound(p.y * scaleY);
    final right = jsRound((p.x + p.width) * scaleX);
    final bottom = jsRound((p.y + p.height) * scaleY);
    return RenderPlacement(
      index: p.index,
      x: x,
      y: y,
      width: math.max(1, right - x),
      height: math.max(1, bottom - y),
    );
  }).toList();
}

// ── Color math ──────────────────────────────────────────────────────────────

double colorDistance(RgbColor left, RgbColor right) {
  final dr = left.r - right.r;
  final dg = left.g - right.g;
  final db = left.b - right.b;
  return math.sqrt(dr * dr + dg * dg + db * db) / 441.6729559300637;
}

double _srgbToLinear(double c) {
  final v = c / 255;
  return v <= 0.04045
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

const double _labEpsilon = 0.008856;
const double _labKappa = 903.3;

double _labF(double t) =>
    t > _labEpsilon ? _cbrt(t) : (_labKappa * t + 16) / 116;

LabColor rgbToLab(RgbColor rgb) {
  final r = _srgbToLinear(rgb.r);
  final g = _srgbToLinear(rgb.g);
  final b = _srgbToLinear(rgb.b);

  final x = _labF((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047);
  final y = _labF(0.2126729 * r + 0.7151522 * g + 0.072175 * b);
  final z = _labF((0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883);

  return LabColor(116 * y - 16, 500 * (x - y), 200 * (y - z));
}

const double maxLabDistance = 375;

double labDistance(LabColor left, LabColor right) {
  final dL = (left.L - right.L) * 1.5;
  final da = left.a - right.a;
  final db = left.b - right.b;
  return math.sqrt(dL * dL + da * da + db * db) / maxLabDistance;
}

double aspectPenalty(double tileAspectRatio, double regionAspectRatio) {
  final tileIsLandscape = tileAspectRatio > 1.1;
  final tileIsPortrait = tileAspectRatio < 0.9;
  final regionIsLandscape = regionAspectRatio > 1.1;
  final regionIsPortrait = regionAspectRatio < 0.9;

  if ((tileIsPortrait && regionIsLandscape) ||
      (tileIsLandscape && regionIsPortrait)) {
    return 10;
  }

  final raw = (math.log(tileAspectRatio / regionAspectRatio)).abs();
  return raw <= 0.18 ? raw : raw * 4;
}

TileDescriptor createTileDescriptor(
  String id,
  String name,
  double width,
  double height,
  RgbColor averageColor,
  double detailScore,
  SubregionColors? subregionColors,
  SubregionEdges? subregionEdges,
  ContrastMap? contrastMap,
  LuminanceBalance? luminanceBalance,
  double colorVariance,
  double edgeOrientation,
  LuminanceHistogram? tonalHistogram,
  SubregionEdgeOrientations? subregionEdgeOrientations,
) {
  return TileDescriptor(
    id: id,
    name: name,
    width: width,
    height: height,
    aspectRatio: width / height,
    orientation: getOrientation(width, height),
    averageColor: averageColor,
    averageLabColor: rgbToLab(averageColor),
    detailScore: detailScore,
    subregionColors: subregionColors,
    subregionEdges: subregionEdges,
    contrastMap: contrastMap,
    luminanceBalance: luminanceBalance,
    colorVariance: colorVariance,
    edgeOrientation: edgeOrientation,
    tonalHistogram: tonalHistogram,
    subregionEdgeOrientations: subregionEdgeOrientations,
  );
}

/// 5x5 center-weighted Gaussian subregion weights.
const List<double> subregionWeights = [
  0.5, 0.8, 1.0, 0.8, 0.5, //
  0.8, 1.2, 1.5, 1.2, 0.8,
  1.0, 1.5, 2.0, 1.5, 1.0,
  0.8, 1.2, 1.5, 1.2, 0.8,
  0.5, 0.8, 1.0, 0.8, 0.5,
];
final double subregionWeightSum = subregionWeights.fold(0.0, (s, w) => s + w);

/// Which of a tile's 25 subregions will actually be SEEN in a cell of [cellAR].
///
/// These weights must model the same crop `resolveTileSourceRect` draws. That function
/// anchors a portrait tile to the TOP in square layout (it keeps faces); this one used
/// to assume a centre crop unconditionally, so square mode matched a tall photo on its
/// middle band and then displayed its top band — scored on pixels the viewer never sees,
/// and blind to the ones they do. For a 9:16 photo in a square cell the two disagreed
/// completely: the visible top row was weighted 0.21 while the half-cut middle row was
/// weighted 1.0.
///
/// [anchorTop] must match `cropPortraitTop` on the plan.
/// Source rectangle, in TILE PIXELS, to draw into a cell of [cellAR].
///
/// ONE place decides which part of a tile ends up in a cell, because the scorer and
/// every renderer have to agree. They did not: the scorer modelled a centre crop while
/// square layout drew the TOP, so tall photos were matched on a band that was then
/// thrown away. Pure geometry so the engine can call it too — `centerCropSrc` in
/// preview_painter applies the same rule to a `ui.Image`.
///
/// Must match `resolveTileSourceRect` in foto-mozaik/lib/mosaic/shared.ts.
class TileSourceRect {
  const TileSourceRect(this.sx, this.sy, this.sw, this.sh);
  final double sx, sy, sw, sh;
}

TileSourceRect resolveTileSourceRect(
  double tileW,
  double tileH,
  double cellAR,
  bool cropPortraitTop, [
  TileCrop? crop,
]) {
  if (crop != null) {
    // Clamp into the image: a stale crop must never produce an out-of-bounds rect.
    final cw = clampD(crop.w, 0.01, 1);
    final ch = clampD(crop.h, 0.01, 1);
    final cx = clampD(crop.x, 0, 1 - cw);
    final cy = clampD(crop.y, 0, 1 - ch);

    final rw = cw * tileW;
    final rh = ch * tileH;
    final rx = cx * tileW;
    final ry = cy * tileH;

    final rectAR = rw / rh;
    if (rectAR > cellAR) {
      final sw = rh * cellAR;
      return TileSourceRect(rx + (rw - sw) / 2, ry, sw, rh);
    }
    final sh = rw / cellAR;
    return TileSourceRect(rx, ry + (rh - sh) / 2, rw, sh);
  }

  final tileAR = tileW / tileH;
  if (tileAR > cellAR) {
    final sw = tileH * cellAR;
    return TileSourceRect((tileW - sw) / 2, 0, sw, tileH);
  }
  final sh = tileW / cellAR;
  return TileSourceRect(0, cropPortraitTop ? 0 : (tileH - sh) / 2, tileW, sh);
}

List<double>? computeCropWeights(
  double tileAR,
  double cellAR, [
  List<double>? out,
  bool anchorTop = false,
  TileCrop? crop,
]) {
  // Ask the SAME function the renderer asks, so there is no second model of the crop to
  // drift out of step with the first. Unit tile, so the rect comes back normalised.
  final r = resolveTileSourceRect(tileAR, 1, cellAR, anchorTop, crop);
  final x0 = r.sx / tileAR;
  final x1 = (r.sx + r.sw) / tileAR;
  final y0 = r.sy;
  final y1 = r.sy + r.sh;

  // Nothing cropped away — the caller can skip the weighting entirely.
  if (x0 <= 1e-6 && y0 <= 1e-6 && x1 >= 1 - 1e-6 && y1 >= 1 - 1e-6) return null;

  List<double> weights;
  if (out != null) {
    for (var i = 0; i < 25; i++) {
      out[i] = subregionWeights[i];
    }
    weights = out;
  } else {
    weights = List<double>.from(subregionWeights);
  }

  // Overlap of each 1/5 x 1/5 subregion with the visible rectangle, as a fraction of its
  // own area. A fully cropped row goes to zero and stops influencing the match; a
  // half-cut row counts half. This replaces a pair of hand-tuned falloffs that
  // approximated a CENTRE crop and could express nothing else.
  for (var i = 0; i < 25; i++) {
    final c = i % 5;
    final rw =
        math.max(0.0, math.min(x1, (c + 1) / 5) - math.max(x0, c / 5)) * 5;
    final rr = i ~/ 5;
    final rh =
        math.max(0.0, math.min(y1, (rr + 1) / 5) - math.max(y0, rr / 5)) * 5;
    weights[i] *= rw * rh;
  }

  return weights;
}

double subregionDistance(SubregionColors a, SubregionColors b) {
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += labDistance(a[i], b[i]) * subregionWeights[i];
  }
  return total / subregionWeightSum;
}

double luminancePatternDistance(
  SubregionColors a,
  SubregionColors b, [
  List<double>? cropWeights,
]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final dL = (a[i].L - b[i].L) * 2.0;
    total += (dL.abs() / (maxLabDistance * 0.5)) * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double chromaPatternDistance(
  SubregionColors a,
  SubregionColors b, [
  List<double>? cropWeights,
]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final da = a[i].a - b[i].a;
    final db = a[i].b - b[i].b;
    total += (math.sqrt(da * da + db * db) / maxLabDistance) * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double edgePatternDistance(
  SubregionEdges a,
  SubregionEdges b, [
  List<double>? cropWeights,
]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += (a[i] - b[i]).abs() * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double contrastPatternDistance(
  ContrastMap a,
  ContrastMap b, [
  List<double>? cropWeights,
]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    total += (a[i] - b[i]).abs() * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double edgeOrientationPatternDistance(
  SubregionEdgeOrientations a,
  SubregionEdgeOrientations b, [
  List<double>? cropWeights,
]) {
  final w = cropWeights ?? subregionWeights;
  var wSum = 0.0;
  var total = 0.0;
  for (var i = 0; i < 25; i++) {
    final off = i * 4;
    final cellDist =
        ((a[off] - b[off]).abs() +
            (a[off + 1] - b[off + 1]).abs() +
            (a[off + 2] - b[off + 2]).abs() +
            (a[off + 3] - b[off + 3]).abs()) *
        0.5;
    total += cellDist * w[i];
    wSum += w[i];
  }
  return total / (wSum == 0 ? 1 : wSum);
}

double luminanceBalanceDiff(LuminanceBalance a, LuminanceBalance b) {
  final dv = a.vertical - b.vertical;
  final dh = a.horizontal - b.horizontal;
  return math.sqrt(dv * dv + dh * dh) / math.sqrt2;
}

double histogramDistance(LuminanceHistogram a, LuminanceHistogram b) {
  var sum = 0.0;
  for (var i = 0; i < 8; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / 2;
}

const String flipSuffix = ':flip';

String getBaseTileId(String tileId) => tileId.endsWith(flipSuffix)
    ? tileId.substring(0, tileId.length - flipSuffix.length)
    : tileId;

bool isTileFlipped(String tileId) => tileId.endsWith(flipSuffix);

/// A stable tile id derived from a tile's blob URL.
///
/// Ids used to be minted from a timestamp (`tile-<ms>-<i>`), which is fine within a
/// session but different on every load — so anything keyed by tile id, manual crops
/// most visibly, was orphaned the moment a project was reopened. Hashing the URL gives
/// an id that is identical on every load AND identical to the one the web client
/// computes for the same tile, so a crop set here shows up there and vice versa.
///
/// Bit-exact port of the web's `stableTileIdFromUrl` (FNV-1a) — the two must agree
/// character for character or the crop maps do not line up across clients.
String stableTileIdFromUrl(String blobUrl) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < blobUrl.length; i++) {
    hash ^= blobUrl.codeUnitAt(i);
    // Dart ints are 64-bit; mask to 32 to match JS `Math.imul(...) >>> 0`.
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 'u${hash.toRadixString(36)}${blobUrl.length.toRadixString(36)}';
}

/// The crop for a placement's tile, if the user set one. Keyed by BASE id, so a
/// mirrored placement shares its source photo's crop.
/// Cell shapes that need their own crop, independent of aspect ratio.
enum CropShape { hex }

/// Which stored crop a tile uses for a cell of this shape.
///
/// A crop is a decision about how to frame a photo for a PARTICULAR cell shape — the
/// square chosen for a square cell is a different decision from the rectangle chosen
/// for a 3:2 one — so they are stored in separate slots and never overwrite each other.
///
/// Square keeps the bare tile id so every crop saved before orientation slots existed
/// still reads, and 3D cubes shares that slot deliberately: its shear maps a SQUARE
/// source onto the cube face, so it is the same decision.
///
/// Thresholds match `_orientationCompatible`, so a cell and its crop slot can never
/// disagree about which orientation a shape is. Must match `cropSlot` in
/// foto-mozaik/lib/mosaic/shared.ts.
String cropSlot(String tileId, double cellAR, [CropShape? shape]) {
  final base = getBaseTileId(tileId);
  // Shape wins over aspect. A hexagon's aspect is 2/sqrt(3) ~ 1.15, which falls inside
  // the "square" band — so without this it would silently share the square mode's crop,
  // and `original` can produce genuine 1.15 cells too, so the two would collide.
  if (shape == CropShape.hex) return '$base|H';
  if (cellAR > 1.18) return '$base|L';
  if (cellAR < 0.85) return '$base|P';
  return base;
}

/// The crop for a placement's tile, if the user set one for cells of this shape.
/// Keyed by BASE id, so a mirrored placement shares its source photo's crop.
TileCrop? cropForTile(
  Map<String, TileCrop>? tileCrops,
  String tileId, [
  double cellAR = 1,
  CropShape? shape,
]) {
  if (tileCrops == null || tileCrops.isEmpty) return null;
  return tileCrops[cropSlot(tileId, cellAR, shape)];
}

double difference(double left, double right) => (left - right).abs();

/// Helper to allocate a zeroed Float32List orientation buffer (length 100).
Float32List zeroOrientations() => Float32List(100);
