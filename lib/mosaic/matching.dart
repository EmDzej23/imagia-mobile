import 'dart:math' as math;
import 'dart:typed_data';

import 'shared.dart';
import 'types.dart';

/// Dart port of `foto-mozaik/lib/mosaic/matching.ts` — the 13-signal tile
/// scorer + simulated-annealing optimizer.
///
/// Determinism notes (see SIGNALS.md):
/// - The Xorshift32 RNG and all bit ops replicate JavaScript's integer
///   semantics exactly: `^ << >>>` operate on 32-bit values; `>>` is a *signed*
///   (arithmetic) shift on int32. [_u32]/[_i32] reproduce these.
/// - The async `yieldToMain()` calls in the web version are purely cooperative
///   (UI responsiveness) and do not affect output, so the Dart ports run
///   synchronously — they are meant to run inside an Isolate.

// ── JS 32-bit integer semantics ─────────────────────────────────────────────

int _u32(int x) => x & 0xFFFFFFFF;

int _i32(int x) {
  final v = x & 0xFFFFFFFF;
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

/// Replicates `Number(x.toFixed(4))`.
double _toFixed4(double x) => double.parse(x.toStringAsFixed(4));

// ── Quickselect: find top-k smallest elements in O(n) ───────────────────────

class _ScoredItem {
  _ScoredItem(this.idx, this.score);
  int idx;
  double score;
}

int _quickSelectPartition(List<_ScoredItem> arr, int left, int right) {
  final pivotScore = arr[right].score;
  var i = left;
  for (var j = left; j < right; j++) {
    if (arr[j].score < pivotScore) {
      final tmp = arr[i];
      arr[i] = arr[j];
      arr[j] = tmp;
      i++;
    }
  }
  final tmp = arr[i];
  arr[i] = arr[right];
  arr[right] = tmp;
  return i;
}

List<_ScoredItem> _quickSelectTopK(List<_ScoredItem> arr, int k) {
  if (k >= arr.length) return arr;
  var left = 0;
  var right = arr.length - 1;
  while (left < right) {
    final pivotIndex = _quickSelectPartition(arr, left, right);
    if (pivotIndex == k) {
      break;
    } else if (pivotIndex < k) {
      left = pivotIndex + 1;
    } else {
      right = pivotIndex - 1;
    }
  }
  return arr;
}

class TileMatch {
  TileMatch(this.tile, this.score);
  TileDescriptor tile;
  double score;
}

class MatchInput {
  MatchInput({
    required this.region,
    required this.tiles,
    required this.settings,
    required this.usageCounts,
    this.nearbyTiles,
    this.saliency,
    this.neighborAvgColor,
    this.tilePoolSize,
    this.placementCount,
    this.colorBias,
  });

  RegionAnalysis region;
  List<TileDescriptor> tiles;
  MosaicSettings settings;
  Map<String, int> usageCounts;
  Map<String, double>? nearbyTiles;
  double? saliency;
  LabColor? neighborAvgColor;
  int? tilePoolSize;
  int? placementCount;
  LabColor? colorBias;
}

// ── Scoring constants ───────────────────────────────────────────────────────

const double _neighborDuplicatePenaltyBase = 25.0;
const double _neighborDuplicatePenaltyScale = 75.0;
const double _maxLabDist = 150;

const double _colorRejectThreshold = 0.25;
const double _colorRejectMultiplier = 25;
const double _saliencyRejectScale = 0.4;
const double _colorRejectCap = 0.5;

const double _textureThreshBase = 0.04;
const double _textureThreshScale = 0.35;
const double _textureThreshMin = 0.03;
const double _textureThreshMax = 0.2;
const double _textureExcessBase = 0.6;

const double _chromaMinRegion = 12;
const double _chromaPreserveWeight = 0.1;
const double _chromaExcessScale = 1.3;
const double _chromaExcessWeight = 0.06;

const double _darkRegionL = 40;
const double _darkContrastMin = 0.04;
const double _darkFlatWeight = 0.6;

const double _neighborSmoothWeight = 0.05;
const double _edgeOrientWeight = 0.12;
const double _edgeOrientPatternWeight = 0.12;
const double _lumaBalanceWeight = 0.12;

const double _salientContrastMin = 0.09;
const double _salientFlatWeight = 1.1;

const double _structureBoostBase = 0.25;
const double _structureBoostSaliency = 0.75;

const double _vividBonusScale = 0.065;
const double _vividBonusMax = 0.025;
const double _vividBonusMaxMinDetail = 0.1;

const double _saTransitionWeight = 0.90;

// ── Helpers ─────────────────────────────────────────────────────────────────

double _weightedEdgeMean(List<double> edges, List<double>? cw) {
  final w = cw ?? subregionWeights;
  var sum = 0.0, wSum = 0.0;
  for (var i = 0; i < 25; i++) {
    sum += edges[i] * w[i];
    wSum += w[i];
  }
  return sum / (wSum == 0 ? 1 : wSum);
}

double _adaptiveTextureThreshold(double regionEdgeMean) => clampD(
    _textureThreshBase + regionEdgeMean * _textureThreshScale,
    _textureThreshMin,
    _textureThreshMax);

// ── Resolved tile descriptor (mutable scratch) ──────────────────────────────

class ResolvedTile {
  SubregionColors colors = _zeroColors;
  SubregionEdges edges = _zero25;
  ContrastMap contrast = _zero25;
  double avgL = 0;
  double avgA = 0;
  double avgB = 0;
  LuminanceHistogram histogram = _zeroHist;
  SubregionEdgeOrientations? orientations;
  List<double>? cropWeights;
}

final LabColor _emptyLab = LabColor(0, 0, 0);
final SubregionEdges _zero25 = List<double>.filled(25, 0);
final LuminanceHistogram _zeroHist = List<double>.filled(8, 0.125);
final SubregionColors _zeroColors = List<LabColor>.filled(25, _emptyLab);

/// Pre-allocated crop-weights buffer (avoids per-call allocation in the SA hot
/// path), mirroring the web's `_cropWeightsBuf`.
final List<double> _cropWeightsBuf = List<double>.filled(25, 0);

final ResolvedTile _scratch = ResolvedTile();

void _resolveTileInto(ResolvedTile out, TileDescriptor tile, double cellAR) {
  final cw = computeCropWeights(tile.aspectRatio, cellAR, _cropWeightsBuf);

  final hasFullAnalysis =
      tile.subregionColors != null && tile.subregionEdges != null;
  out.colors = tile.subregionColors ?? _zeroColors;
  out.edges = tile.subregionEdges ?? _zero25;
  out.contrast = tile.contrastMap ?? _zero25;
  out.histogram = tile.tonalHistogram ?? _zeroHist;
  out.orientations = tile.subregionEdgeOrientations;
  out.cropWeights = cw;

  if (!hasFullAnalysis || cw == null) {
    out.avgL = tile.averageLabColor.L;
    out.avgA = tile.averageLabColor.a;
    out.avgB = tile.averageLabColor.b;
  } else {
    var sL = 0.0, sA = 0.0, sB = 0.0, swt = 0.0;
    final sc = tile.subregionColors!;
    for (var i = 0; i < 25; i++) {
      final wi = cw[i];
      sL += sc[i].L * wi;
      sA += sc[i].a * wi;
      sB += sc[i].b * wi;
      swt += wi;
    }
    out.avgL = sL / swt;
    out.avgA = sA / swt;
    out.avgB = sB / swt;
  }
}

// ── Initial tile selection ──────────────────────────────────────────────────

TileMatch selectBestTileMatch(MatchInput input) {
  final region = input.region;
  final tiles = input.tiles;
  final settings = input.settings;
  final usageCounts = input.usageCounts;
  final nearbyTiles = input.nearbyTiles;
  final neighborAvgColor = input.neighborAvgColor;
  final tilePoolSize = input.tilePoolSize;
  final placementCount = input.placementCount;
  final colorBias = input.colorBias;

  if (tiles.isEmpty) {
    throw StateError('At least one tile image is required.');
  }

  final w = settings.signalWeights ?? defaultSignalWeights();
  final sal = clampD(input.saliency ?? 0, 0, 1);
  final colorRejectThreshold =
      _colorRejectThreshold * (1 - sal * _saliencyRejectScale);

  final regionAR = region.width / region.height;
  final rL = region.averageLabColor.L + (colorBias?.L ?? 0);
  final rA = region.averageLabColor.a + (colorBias?.a ?? 0);
  final rB = region.averageLabColor.b + (colorBias?.b ?? 0);
  var bestTile = tiles[0];
  var bestScore = double.infinity;

  final cellIsPortrait = regionAR < 0.85;
  final cellIsLandscape = regionAR > 1.18;
  final regionEdgeMean = _weightedEdgeMean(region.subregionEdges, null);
  final texThreshold = _adaptiveTextureThreshold(regionEdgeMean);
  final regionChroma = math.sqrt(rA * rA + rB * rB);
  final structureBoost = 1 + _structureBoostBase + sal * _structureBoostSaliency;

  final isMinDetail = isMinimumDetailOriginalMode(settings);
  final skipNeighborPenalties = settings.reusePenalty == 0 || isMinDetail;
  final skipVariety = isMinDetail;
  final vividCap = isMinDetail ? _vividBonusMaxMinDetail : _vividBonusMax;

  final td = _scratch;

  const maxCandidates = 80;
  List<TileDescriptor> tilesToEvaluate;

  if (tiles.length > maxCandidates * 1.5 && !isMinDetail) {
    final quickScores = <_ScoredItem>[];
    for (var ti = 0; ti < tiles.length; ti++) {
      final tile = tiles[ti];
      final tileIsPortrait = tile.aspectRatio < 0.85;
      final tileIsLandscape = tile.aspectRatio > 1.18;
      final tileIsSquare = !tileIsPortrait && !tileIsLandscape;
      if ((tileIsPortrait && cellIsLandscape) ||
          (tileIsLandscape && cellIsPortrait) ||
          (tileIsSquare && cellIsLandscape) ||
          (tileIsSquare && cellIsPortrait)) {
        continue;
      }
      final dL = (rL - tile.averageLabColor.L) * w.brightnessEmphasis;
      final da = rA - tile.averageLabColor.a;
      final db = rB - tile.averageLabColor.b;
      quickScores.add(_ScoredItem(ti, dL * dL + da * da + db * db));
    }
    _quickSelectTopK(quickScores, maxCandidates);
    tilesToEvaluate = [];
    final limit = math.min(maxCandidates, quickScores.length);
    for (var i = 0; i < limit; i++) {
      tilesToEvaluate.add(tiles[quickScores[i].idx]);
    }
  } else {
    tilesToEvaluate = tiles;
  }

  for (var ti = 0; ti < tilesToEvaluate.length; ti++) {
    final tile = tilesToEvaluate[ti];

    final tileIsPortrait = tile.aspectRatio < 0.85;
    final tileIsLandscape = tile.aspectRatio > 1.18;
    final tileIsSquare = !tileIsPortrait && !tileIsLandscape;
    if (tileIsPortrait && cellIsLandscape) continue;
    if (tileIsLandscape && cellIsPortrait) continue;
    if (tileIsSquare && cellIsLandscape) continue;
    if (tileIsSquare && cellIsPortrait) continue;

    final salVarietyScale = 0.7 + sal * 0.6;
    final baseId = getBaseTileId(tile.id);
    final usageCount = usageCounts[baseId] ?? 0;
    var varietyAdj = 0.0;
    if (settings.reusePenalty > 0 &&
        tilePoolSize != null &&
        tilePoolSize != 0 &&
        placementCount != null &&
        placementCount != 0 &&
        !skipVariety) {
      final uniqueUsed = usageCounts.length;
      final unusedCount = math.max(0, tilePoolSize - uniqueUsed);
      final expectedUsage = placementCount / tilePoolSize;
      final varietyStrength = (settings.reusePenalty * settings.reusePenalty * 2 +
              settings.reusePenalty) *
          salVarietyScale;
      if (unusedCount > 0 && usageCount > 0) {
        varietyAdj += (unusedCount / tilePoolSize) * varietyStrength * 15;
      }
      if (usageCount > 0) {
        final overuseFactor = math.max(0, usageCount / expectedUsage - 0.8);
        varietyAdj += overuseFactor * overuseFactor * varietyStrength * 8;
      }
      if (usageCount == 0) {
        varietyAdj -= varietyStrength * 5;
      }
      varietyAdj += _log1p(usageCount) * varietyStrength * 1.5;
    }
    final proximity = nearbyTiles?[baseId] ?? 0;
    if (!skipNeighborPenalties && proximity > 0) {
      varietyAdj += (_neighborDuplicatePenaltyBase +
              settings.reusePenalty * _neighborDuplicatePenaltyScale) *
          proximity *
          salVarietyScale;
    }

    final asp = aspectPenalty(tile.aspectRatio, regionAR) * settings.aspectWeight;
    if (asp + varietyAdj >= bestScore) continue;

    _resolveTileInto(td, tile, regionAR);
    final cw = td.cropWeights;

    final dL = (rL - td.avgL) * w.brightnessEmphasis;
    final da = rA - td.avgA;
    final db = rB - td.avgB;
    final colorD = math.sqrt(dL * dL + da * da + db * db) / _maxLabDist;
    var score =
        asp + varietyAdj + colorD * colorD * 2.5 * w.color * structureBoost;
    if (colorD > colorRejectThreshold) {
      final excess = colorD - colorRejectThreshold;
      score += math.min(excess * excess * _colorRejectMultiplier, _colorRejectCap);
    }
    if (score >= bestScore) continue;

    score += luminancePatternDistance(region.subregionColors, td.colors, cw) *
        w.luminancePattern *
        structureBoost;
    score += chromaPatternDistance(region.subregionColors, td.colors, cw) *
        w.chromaPattern;
    if (score >= bestScore) continue;

    score += edgePatternDistance(region.subregionEdges, td.edges, cw) *
        w.edgePattern *
        structureBoost;

    score += ((region.edgeOrientation - tile.edgeOrientation).abs() / 2) *
        _edgeOrientWeight *
        structureBoost;

    final tlb = tile.luminanceBalance;
    if (tlb != null) {
      final lbV = (region.luminanceBalance.vertical - tlb.vertical).abs() / 2;
      final lbH = (region.luminanceBalance.horizontal - tlb.horizontal).abs() / 2;
      score += ((lbV + lbH) / 2) * _lumaBalanceWeight * structureBoost;
    }

    final orientations = td.orientations;
    if (orientations != null) {
      score += edgeOrientationPatternDistance(
              region.subregionEdgeOrientations, orientations, cw) *
          _edgeOrientPatternWeight *
          structureBoost;
    }

    score += contrastPatternDistance(region.contrastMap, td.contrast, cw) *
        w.contrastPattern *
        structureBoost;

    final tileEdgeMean = _weightedEdgeMean(td.edges, cw);
    final textureExcess = tileEdgeMean - regionEdgeMean - texThreshold;
    if (textureExcess > 0) {
      final texMult = _textureExcessBase * (1.5 - sal * 0.7);
      score += textureExcess * textureExcess * texMult;
    }

    score += histogramDistance(region.tonalHistogram, td.histogram) *
        w.tonalHistogram;

    score += difference(region.detailScore, tile.detailScore) *
        settings.detailWeight *
        (0.5 + sal);

    score += difference(region.colorVariance, tile.colorVariance) *
        0.08 *
        (0.5 + sal);

    if (regionChroma > _chromaMinRegion) {
      final tileChroma = math.sqrt(td.avgA * td.avgA + td.avgB * td.avgB);
      final deficit = math.max(0, 1 - tileChroma / regionChroma);
      score += deficit * deficit * _chromaPreserveWeight;
      final excess = math.max(0, tileChroma / regionChroma - _chromaExcessScale);
      score += excess * excess * _chromaExcessWeight;
    }

    final tileContrastMean = _weightedEdgeMean(td.contrast, cw);

    if (rL < _darkRegionL) {
      final darkness = 1 - rL / _darkRegionL;
      final flatness = math.max(0, _darkContrastMin - tileContrastMean);
      score += flatness * darkness * _darkFlatWeight;
    }

    if (sal > 0.3) {
      final salFactor = (sal - 0.3) / 0.7;
      final flatness = math.max(0, _salientContrastMin - tileContrastMean);
      score += flatness * salFactor * _salientFlatWeight;
    }

    if (sal > 0.2) {
      score -= math.min(vividCap, tileContrastMean * _vividBonusScale * sal);
    }

    if (!skipNeighborPenalties && neighborAvgColor != null) {
      final nDL = (td.avgL - neighborAvgColor.L) * 0.7;
      final nDA = td.avgA - neighborAvgColor.a;
      final nDB = td.avgB - neighborAvgColor.b;
      score += (math.sqrt(nDL * nDL + nDA * nDA + nDB * nDB) / _maxLabDist) *
          _neighborSmoothWeight *
          (1.5 - sal * 0.9);
    }

    if (score < bestScore) {
      bestTile = tile;
      bestScore = score;
    }
  }

  return TileMatch(bestTile, _toFixed4(bestScore));
}

double _log1p(num x) => math.log(1 + x);

// ── Top-K candidates for assignment solver ──────────────────────────────────

class RegionCandidate {
  RegionCandidate(this.tile, this.baseCost);
  TileDescriptor tile;
  double baseCost;
}

List<RegionCandidate> getTopKCandidates(
  RegionAnalysis region,
  List<TileDescriptor> tiles,
  MosaicSettings settings, [
  double saliency = 0,
  int k = 80,
]) {
  if (tiles.isEmpty) return [];

  final w = settings.signalWeights ?? defaultSignalWeights();
  final sal = clampD(saliency, 0, 1);
  final colorRejectThreshold =
      _colorRejectThreshold * (1 - sal * _saliencyRejectScale);
  final regionAR = region.width / region.height;
  final rL = region.averageLabColor.L;
  final rA = region.averageLabColor.a;
  final rB = region.averageLabColor.b;
  final cellIsPortrait = regionAR < 0.85;
  final cellIsLandscape = regionAR > 1.18;
  final regionEdgeMean = _weightedEdgeMean(region.subregionEdges, null);
  final texThreshold = _adaptiveTextureThreshold(regionEdgeMean);
  final regionChroma = math.sqrt(rA * rA + rB * rB);
  final structureBoost = 1 + _structureBoostBase + sal * _structureBoostSaliency;
  final td = _scratch;

  List<TileDescriptor> tilesToEval;
  if (tiles.length > k * 1.5) {
    final quickScores = <_ScoredItem>[];
    for (var ti = 0; ti < tiles.length; ti++) {
      final tile = tiles[ti];
      final tp = tile.aspectRatio < 0.85,
          tl = tile.aspectRatio > 1.18,
          ts = !(tile.aspectRatio < 0.85) && !(tile.aspectRatio > 1.18);
      if ((tp && cellIsLandscape) ||
          (tl && cellIsPortrait) ||
          (ts && cellIsLandscape) ||
          (ts && cellIsPortrait)) {
        continue;
      }
      final dL = (rL - tile.averageLabColor.L) * w.brightnessEmphasis;
      final da = rA - tile.averageLabColor.a;
      final db = rB - tile.averageLabColor.b;
      quickScores.add(_ScoredItem(ti, dL * dL + da * da + db * db));
    }
    _quickSelectTopK(quickScores, k);
    tilesToEval = [];
    for (var i = 0; i < math.min(k, quickScores.length); i++) {
      tilesToEval.add(tiles[quickScores[i].idx]);
    }
  } else {
    tilesToEval = tiles.where((t) {
      final tp = t.aspectRatio < 0.85,
          tl = t.aspectRatio > 1.18,
          ts = !(t.aspectRatio < 0.85) && !(t.aspectRatio > 1.18);
      return !((tp && cellIsLandscape) ||
          (tl && cellIsPortrait) ||
          (ts && cellIsLandscape) ||
          (ts && cellIsPortrait));
    }).toList();
  }

  final results = <RegionCandidate>[];
  for (final tile in tilesToEval) {
    _resolveTileInto(td, tile, regionAR);
    final cw = td.cropWeights;

    final asp = aspectPenalty(tile.aspectRatio, regionAR) * settings.aspectWeight;
    final dL = (rL - td.avgL) * w.brightnessEmphasis;
    final da = rA - td.avgA;
    final db = rB - td.avgB;
    final colorD = math.sqrt(dL * dL + da * da + db * db) / _maxLabDist;
    var score = asp + colorD * colorD * 2.5 * w.color * structureBoost;
    if (colorD > colorRejectThreshold) {
      final excess = colorD - colorRejectThreshold;
      score += math.min(excess * excess * _colorRejectMultiplier, _colorRejectCap);
    }

    score += luminancePatternDistance(region.subregionColors, td.colors, cw) *
        w.luminancePattern *
        structureBoost;
    score += chromaPatternDistance(region.subregionColors, td.colors, cw) *
        w.chromaPattern;
    score += edgePatternDistance(region.subregionEdges, td.edges, cw) *
        w.edgePattern *
        structureBoost;
    score += ((region.edgeOrientation - tile.edgeOrientation).abs() / 2) *
        _edgeOrientWeight *
        structureBoost;
    final tlb = tile.luminanceBalance;
    if (tlb != null) {
      final lbV = (region.luminanceBalance.vertical - tlb.vertical).abs() / 2;
      final lbH = (region.luminanceBalance.horizontal - tlb.horizontal).abs() / 2;
      score += ((lbV + lbH) / 2) * _lumaBalanceWeight * structureBoost;
    }
    final orientations = td.orientations;
    if (orientations != null) {
      score += edgeOrientationPatternDistance(
              region.subregionEdgeOrientations, orientations, cw) *
          _edgeOrientPatternWeight *
          structureBoost;
    }
    score += contrastPatternDistance(region.contrastMap, td.contrast, cw) *
        w.contrastPattern *
        structureBoost;

    final tileEdgeMean = _weightedEdgeMean(td.edges, cw);
    final textureExcess = tileEdgeMean - regionEdgeMean - texThreshold;
    if (textureExcess > 0) {
      score += textureExcess *
          textureExcess *
          _textureExcessBase *
          (1.5 - sal * 0.7);
    }

    score += histogramDistance(region.tonalHistogram, td.histogram) *
        w.tonalHistogram;
    score += difference(region.detailScore, tile.detailScore) *
        settings.detailWeight *
        (0.5 + sal);
    score += difference(region.colorVariance, tile.colorVariance) *
        0.08 *
        (0.5 + sal);

    if (regionChroma > _chromaMinRegion) {
      final tileChroma = math.sqrt(td.avgA * td.avgA + td.avgB * td.avgB);
      final deficit = math.max(0, 1 - tileChroma / regionChroma);
      score += deficit * deficit * _chromaPreserveWeight;
      final excess = math.max(0, tileChroma / regionChroma - _chromaExcessScale);
      score += excess * excess * _chromaExcessWeight;
    }

    final tileContrastMean = _weightedEdgeMean(td.contrast, cw);
    if (rL < _darkRegionL) {
      final darkness = 1 - rL / _darkRegionL;
      final flatness = math.max(0, _darkContrastMin - tileContrastMean);
      score += flatness * darkness * _darkFlatWeight;
    }
    if (sal > 0.3) {
      score += math.max(0, _salientContrastMin - tileContrastMean) *
          ((sal - 0.3) / 0.7) *
          _salientFlatWeight;
    }
    if (sal > 0.2) {
      score -= math.min(_vividBonusMax, tileContrastMean * _vividBonusScale * sal);
    }

    results.add(RegionCandidate(tile, _toFixed4(score)));
  }

  // Stable sort by baseCost (JS Array.sort is stable; Dart's is not — add an
  // index tiebreaker to preserve insertion order on equal costs).
  final indexed = <MapEntry<int, RegionCandidate>>[];
  for (var i = 0; i < results.length; i++) {
    indexed.add(MapEntry(i, results[i]));
  }
  indexed.sort((a, b) {
    final c = a.value.baseCost.compareTo(b.value.baseCost);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  final sorted = indexed.map((e) => e.value).toList();
  return sorted.length <= k ? sorted : sorted.sublist(0, k);
}

// ── Pre-resolved tile entries for uniform grids ─────────────────────────────

class ResolvedTileEntry {
  ResolvedTileEntry({
    required this.tile,
    required this.avgL,
    required this.avgA,
    required this.avgB,
    required this.colors,
    required this.edges,
    required this.contrast,
    required this.histogram,
    required this.orientations,
    required this.edgeMean,
    required this.contrastMean,
    required this.chroma,
    required this.baseId,
    required this.edgeOrientation,
    required this.luminanceBalanceV,
    required this.luminanceBalanceH,
  });

  TileDescriptor tile;
  double avgL;
  double avgA;
  double avgB;
  SubregionColors colors;
  SubregionEdges edges;
  ContrastMap contrast;
  LuminanceHistogram histogram;
  SubregionEdgeOrientations? orientations;
  double edgeMean;
  double contrastMean;
  double chroma;
  String baseId;
  double edgeOrientation;
  double luminanceBalanceV;
  double luminanceBalanceH;
}

/// Cache keyed on (pool identity, cellAR). Mirrors the web `preResolveCache`.
final Expando<Map<double, List<ResolvedTileEntry>>> _preResolveCache =
    Expando();

List<ResolvedTileEntry> preResolveTiles(
    List<TileDescriptor> tiles, double cellAR) {
  var arMap = _preResolveCache[tiles];
  if (arMap == null) {
    arMap = {};
    _preResolveCache[tiles] = arMap;
  }
  final cached = arMap[cellAR];
  if (cached != null) return cached;

  final tmp = ResolvedTile();
  final result = <ResolvedTileEntry>[];

  for (final tile in tiles) {
    _resolveTileInto(tmp, tile, cellAR);
    result.add(ResolvedTileEntry(
      tile: tile,
      avgL: tmp.avgL,
      avgA: tmp.avgA,
      avgB: tmp.avgB,
      colors: tmp.colors,
      edges: tmp.edges,
      contrast: tmp.contrast,
      histogram: tmp.histogram,
      orientations: tmp.orientations,
      edgeMean: _weightedEdgeMean(tmp.edges, tmp.cropWeights),
      contrastMean: _weightedEdgeMean(tmp.contrast, tmp.cropWeights),
      chroma: math.sqrt(tmp.avgA * tmp.avgA + tmp.avgB * tmp.avgB),
      baseId: getBaseTileId(tile.id),
      edgeOrientation: tile.edgeOrientation,
      luminanceBalanceV: tile.luminanceBalance?.vertical ?? 0,
      luminanceBalanceH: tile.luminanceBalance?.horizontal ?? 0,
    ));
  }

  arMap[cellAR] = result;
  return result;
}

// ── Uniform-grid tile selection ─────────────────────────────────────────────

class UniformMatchInput {
  UniformMatchInput({
    required this.region,
    required this.resolved,
    required this.settings,
    required this.usageCounts,
    this.nearbyTiles,
    this.saliency,
    this.neighborAvgColor,
    this.tilePoolSize,
    this.placementCount,
    this.colorBias,
  });

  RegionAnalysis region;
  List<ResolvedTileEntry> resolved;
  MosaicSettings settings;
  Map<String, int> usageCounts;
  Map<String, double>? nearbyTiles;
  double? saliency;
  LabColor? neighborAvgColor;
  int? tilePoolSize;
  int? placementCount;
  LabColor? colorBias;
}

const int _uniformMaxCandidates = 60;

TileMatch selectBestTileUniform(UniformMatchInput input) {
  final region = input.region;
  final resolved = input.resolved;
  final settings = input.settings;
  final usageCounts = input.usageCounts;
  final nearbyTiles = input.nearbyTiles;
  final neighborAvgColor = input.neighborAvgColor;
  final tilePoolSize = input.tilePoolSize;
  final placementCount = input.placementCount;
  final colorBias = input.colorBias;

  if (resolved.isEmpty) {
    throw StateError('At least one tile image is required.');
  }

  final w = settings.signalWeights ?? defaultSignalWeights();
  final sal = clampD(input.saliency ?? 0, 0, 1);
  final colorRejectThreshold =
      _colorRejectThreshold * (1 - sal * _saliencyRejectScale);

  final rL = region.averageLabColor.L + (colorBias?.L ?? 0);
  final rA = region.averageLabColor.a + (colorBias?.a ?? 0);
  final rB = region.averageLabColor.b + (colorBias?.b ?? 0);
  final regionEdgeMean = _weightedEdgeMean(region.subregionEdges, null);
  final texThreshold = _adaptiveTextureThreshold(regionEdgeMean);
  final regionChroma = math.sqrt(rA * rA + rB * rB);
  final structureBoost = 1 + _structureBoostBase + sal * _structureBoostSaliency;
  final cellAR = region.width / region.height;

  final skipNeighborPenalties = settings.reusePenalty == 0;

  final salVarietyScale = 0.7 + sal * 0.6;
  final hasVariety = settings.reusePenalty > 0 &&
      tilePoolSize != null &&
      tilePoolSize != 0 &&
      placementCount != null &&
      placementCount != 0;
  var expectedUsage = 0.0;
  var varietyStrength = 0.0;
  var unusedCount = 0;
  if (hasVariety) {
    expectedUsage = placementCount / tilePoolSize;
    varietyStrength = (settings.reusePenalty * settings.reusePenalty * 2 +
            settings.reusePenalty) *
        salVarietyScale;
    final uniqueUsed = usageCounts.length;
    unusedCount = math.max(0, tilePoolSize - uniqueUsed);
  }

  List<int> candidates;
  if (resolved.length > _uniformMaxCandidates * 1.5) {
    final quickScores = <_ScoredItem>[];
    for (var ti = 0; ti < resolved.length; ti++) {
      final e = resolved[ti];
      final dL = (rL - e.avgL) * w.brightnessEmphasis;
      final da = rA - e.avgA;
      final db = rB - e.avgB;
      final colorD = math.sqrt(dL * dL + da * da + db * db) / _maxLabDist;
      var qs = colorD * colorD * 2.5;
      if (hasVariety) {
        final usageCount = usageCounts[e.baseId] ?? 0;
        if (usageCount == 0) {
          qs -= varietyStrength * 3;
        } else if (unusedCount > 0) {
          qs += (unusedCount / tilePoolSize) * varietyStrength * 5;
        }
      }
      quickScores.add(_ScoredItem(ti, qs));
    }
    _quickSelectTopK(quickScores, _uniformMaxCandidates);
    candidates = [];
    final limit = math.min(_uniformMaxCandidates, quickScores.length);
    for (var i = 0; i < limit; i++) {
      candidates.add(quickScores[i].idx);
    }
  } else {
    candidates = List<int>.generate(resolved.length, (i) => i);
  }

  var bestEntry = resolved[candidates[0]];
  var bestScore = double.infinity;

  for (final ti in candidates) {
    final e = resolved[ti];

    final usageCount = usageCounts[e.baseId] ?? 0;
    var varietyAdj = 0.0;
    if (hasVariety) {
      if (unusedCount > 0 && usageCount > 0) {
        varietyAdj += (unusedCount / tilePoolSize) * varietyStrength * 15;
      }
      if (usageCount > 0) {
        final overuseFactor = math.max(0, usageCount / expectedUsage - 0.8);
        varietyAdj += overuseFactor * overuseFactor * varietyStrength * 8;
      }
      if (usageCount == 0) {
        varietyAdj -= varietyStrength * 5;
      }
      varietyAdj += _log1p(usageCount) * varietyStrength * 1.5;
    }
    final proximity = nearbyTiles?[e.baseId] ?? 0;
    if (!skipNeighborPenalties && proximity > 0) {
      varietyAdj += (_neighborDuplicatePenaltyBase +
              settings.reusePenalty * _neighborDuplicatePenaltyScale) *
          proximity *
          salVarietyScale;
    }

    final tileAR = e.tile.aspectRatio;
    final cropFrac =
        1 - math.min(tileAR, cellAR) / math.max(tileAR, cellAR);
    var score = cropFrac * cropFrac * 3 + varietyAdj;

    final dL = (rL - e.avgL) * w.brightnessEmphasis;
    final da = rA - e.avgA;
    final db = rB - e.avgB;
    final colorD = math.sqrt(dL * dL + da * da + db * db) / _maxLabDist;
    score += colorD * colorD * 2.5 * w.color * structureBoost;
    if (colorD > colorRejectThreshold) {
      final excess = colorD - colorRejectThreshold;
      score += math.min(excess * excess * _colorRejectMultiplier, _colorRejectCap);
    }
    if (score >= bestScore) continue;

    score += luminancePatternDistance(region.subregionColors, e.colors, null) *
        w.luminancePattern *
        structureBoost;
    score += chromaPatternDistance(region.subregionColors, e.colors, null) *
        w.chromaPattern;
    if (score >= bestScore) continue;

    score += edgePatternDistance(region.subregionEdges, e.edges, null) *
        w.edgePattern *
        structureBoost;

    score += ((region.edgeOrientation - e.edgeOrientation).abs() / 2) *
        _edgeOrientWeight *
        structureBoost;

    final lbV = (region.luminanceBalance.vertical - e.luminanceBalanceV).abs() / 2;
    final lbH =
        (region.luminanceBalance.horizontal - e.luminanceBalanceH).abs() / 2;
    score += ((lbV + lbH) / 2) * _lumaBalanceWeight * structureBoost;

    final orientations = e.orientations;
    if (orientations != null) {
      score += edgeOrientationPatternDistance(
              region.subregionEdgeOrientations, orientations, null) *
          _edgeOrientPatternWeight *
          structureBoost;
    }

    score += contrastPatternDistance(region.contrastMap, e.contrast, null) *
        w.contrastPattern *
        structureBoost;

    final textureExcess = e.edgeMean - regionEdgeMean - texThreshold;
    if (textureExcess > 0) {
      final texMult = _textureExcessBase * (1.5 - sal * 0.7);
      score += textureExcess * textureExcess * texMult;
    }

    score += histogramDistance(region.tonalHistogram, e.histogram) *
        w.tonalHistogram;

    score += difference(region.detailScore, e.tile.detailScore) *
        settings.detailWeight *
        (0.5 + sal);

    score += difference(region.colorVariance, e.tile.colorVariance) *
        0.08 *
        (0.5 + sal);

    if (regionChroma > _chromaMinRegion) {
      final deficit = math.max(0, 1 - e.chroma / regionChroma);
      score += deficit * deficit * _chromaPreserveWeight;
      final excess = math.max(0, e.chroma / regionChroma - _chromaExcessScale);
      score += excess * excess * _chromaExcessWeight;
    }

    if (rL < _darkRegionL) {
      final darkness = 1 - rL / _darkRegionL;
      final flatness = math.max(0, _darkContrastMin - e.contrastMean);
      score += flatness * darkness * _darkFlatWeight;
    }

    if (sal > 0.3) {
      final salFactor = (sal - 0.3) / 0.7;
      final flatness = math.max(0, _salientContrastMin - e.contrastMean);
      score += flatness * salFactor * _salientFlatWeight;
    }

    if (sal > 0.2) {
      score -= math.min(_vividBonusMax, e.contrastMean * _vividBonusScale * sal);
    }

    if (!skipNeighborPenalties && neighborAvgColor != null) {
      final nDL = (e.avgL - neighborAvgColor.L) * 0.7;
      final nDA = e.avgA - neighborAvgColor.a;
      final nDB = e.avgB - neighborAvgColor.b;
      score += (math.sqrt(nDL * nDL + nDA * nDA + nDB * nDB) / _maxLabDist) *
          _neighborSmoothWeight *
          (1.5 - sal * 0.9);
    }

    if (score < bestScore) {
      bestEntry = e;
      bestScore = score;
    }
  }

  return TileMatch(bestEntry.tile, _toFixed4(bestScore));
}

// ── SA visual score ─────────────────────────────────────────────────────────

class RegionConstants {
  RegionConstants({
    required this.regionAR,
    required this.cellIsPortrait,
    required this.cellIsLandscape,
    required this.regionEdgeMean,
    required this.texThreshold,
    required this.regionChroma,
    required this.regionL,
    required this.saliency,
  });

  double regionAR;
  bool cellIsPortrait;
  bool cellIsLandscape;
  double regionEdgeMean;
  double texThreshold;
  double regionChroma;
  double regionL;
  double saliency;
}

double _visualScoreFast(RegionAnalysis region, TileDescriptor tile,
    MosaicSettings settings, RegionConstants rc, ResolvedTile td) {
  final tileIsPortrait = tile.aspectRatio < 0.85;
  final tileIsLandscape = tile.aspectRatio > 1.18;
  final tileIsSquare = !tileIsPortrait && !tileIsLandscape;
  if ((tileIsPortrait && rc.cellIsLandscape) ||
      (tileIsLandscape && rc.cellIsPortrait) ||
      (tileIsSquare && rc.cellIsLandscape) ||
      (tileIsSquare && rc.cellIsPortrait)) {
    return 100;
  }

  final sw = settings.signalWeights ?? defaultSignalWeights();
  final structureBoost =
      1 + _structureBoostBase + rc.saliency * _structureBoostSaliency;
  _resolveTileInto(td, tile, rc.regionAR);
  final cw = td.cropWeights;

  final dL = (region.averageLabColor.L - td.avgL) * sw.brightnessEmphasis;
  final da = region.averageLabColor.a - td.avgA;
  final db = region.averageLabColor.b - td.avgB;
  final colorD = math.sqrt(dL * dL + da * da + db * db) / _maxLabDist;
  var colorReject = 0.0;
  if (colorD > _colorRejectThreshold) {
    final excess = colorD - _colorRejectThreshold;
    colorReject =
        math.min(excess * excess * _colorRejectMultiplier, _colorRejectCap);
  }

  final tonalDist = histogramDistance(region.tonalHistogram, td.histogram);

  final tileEdgeMean = _weightedEdgeMean(td.edges, cw);
  final textureExcess = tileEdgeMean - rc.regionEdgeMean - rc.texThreshold;
  final texturePenalty = textureExcess > 0
      ? textureExcess * textureExcess * _textureExcessBase * (1.5 - rc.saliency * 0.7)
      : 0.0;

  var satPenalty = 0.0;
  if (rc.regionChroma > _chromaMinRegion) {
    final tileChroma = math.sqrt(td.avgA * td.avgA + td.avgB * td.avgB);
    final deficit = math.max(0, 1 - tileChroma / rc.regionChroma);
    satPenalty = deficit * deficit * _chromaPreserveWeight;
    final excess = math.max(0, tileChroma / rc.regionChroma - _chromaExcessScale);
    satPenalty += excess * excess * _chromaExcessWeight;
  }

  final tileContrastMean = _weightedEdgeMean(td.contrast, cw);

  var darkPenalty = 0.0;
  if (rc.regionL < _darkRegionL) {
    final darkness = 1 - rc.regionL / _darkRegionL;
    final flatness = math.max(0, _darkContrastMin - tileContrastMean);
    darkPenalty = flatness * darkness * _darkFlatWeight;
  }

  var salientPenalty = 0.0;
  if (rc.saliency > 0.3) {
    final salFactor = (rc.saliency - 0.3) / 0.7;
    final flatness = math.max(0, _salientContrastMin - tileContrastMean);
    salientPenalty = flatness * salFactor * _salientFlatWeight;
  }

  final vividBonus = rc.saliency > 0.2
      ? math.min(_vividBonusMax, tileContrastMean * _vividBonusScale * rc.saliency)
      : 0.0;

  final orientations = td.orientations;
  final orientPatternDist = orientations != null
      ? edgeOrientationPatternDistance(
              region.subregionEdgeOrientations, orientations, cw) *
          _edgeOrientPatternWeight *
          structureBoost
      : 0.0;

  return colorD * colorD * 2.5 * sw.color * structureBoost +
      colorReject +
      luminancePatternDistance(region.subregionColors, td.colors, cw) *
          sw.luminancePattern *
          structureBoost +
      chromaPatternDistance(region.subregionColors, td.colors, cw) *
          sw.chromaPattern +
      edgePatternDistance(region.subregionEdges, td.edges, cw) *
          sw.edgePattern *
          structureBoost +
      contrastPatternDistance(region.contrastMap, td.contrast, cw) *
          sw.contrastPattern *
          structureBoost +
      orientPatternDist +
      texturePenalty +
      satPenalty +
      darkPenalty +
      salientPenalty -
      vividBonus +
      tonalDist * sw.tonalHistogram +
      difference(region.detailScore, tile.detailScore) *
          settings.detailWeight *
          (0.5 + rc.saliency) +
      difference(region.colorVariance, tile.colorVariance) *
          0.08 *
          (0.5 + rc.saliency) +
      aspectPenalty(tile.aspectRatio, rc.regionAR) * settings.aspectWeight;
}

// ── Simulated annealing ─────────────────────────────────────────────────────

const double _saInitialTemp = 0.08;
const double _saInitialTempMinDetail = 0.20;
const double _saCoolingRate = 0.97;
const double _saMinTemp = 0.001;
const int _saIterationsPerTempFactor = 4;
const int _saMaxTotalIterations = 400000;
const int _saMaxTotalIterationsMobile = 120000;

/// Mutates [placements] in place. [isMobile] selects the lower iteration cap
/// (web reads `isMobileDevice()`); defaults to false (full desktop budget) to
/// match the web's primary path — callers on phones can opt into the mobile cap.
void optimizePlacementSwaps(
  List<MosaicPlacement> placements,
  Map<String, TileDescriptor> tileMap,
  MosaicSettings settings, {
  List<Set<int>>? adjacency,
  Float64List? saliency,
  double budgetFactor = 1.0,
  int seedOffset = 0,
  bool isMobile = false,
}) {
  final n = placements.length;
  if (n < 2) return;

  final isMinDetail = isMinimumDetailOriginalMode(settings);
  final skipProximityPenalty = settings.reusePenalty == 0 || isMinDetail;
  final skipTransitionCost = settings.reusePenalty == 0;

  final regionConsts = List<RegionConstants>.filled(
      n,
      RegionConstants(
          regionAR: 0,
          cellIsPortrait: false,
          cellIsLandscape: false,
          regionEdgeMean: 0,
          texThreshold: 0,
          regionChroma: 0,
          regionL: 0,
          saliency: 0));
  for (var i = 0; i < n; i++) {
    final p = placements[i];
    final regionAR = p.width / p.height;
    final regionEdgeMean = _weightedEdgeMean(p.subregionEdges, null);
    final rA = p.averageLabColor.a;
    final rB = p.averageLabColor.b;
    regionConsts[i] = RegionConstants(
      regionAR: regionAR,
      cellIsPortrait: regionAR < 0.85,
      cellIsLandscape: regionAR > 1.18,
      regionEdgeMean: regionEdgeMean,
      texThreshold: _adaptiveTextureThreshold(regionEdgeMean),
      regionChroma: math.sqrt(rA * rA + rB * rB),
      regionL: p.averageLabColor.L,
      saliency: saliency != null ? saliency[i] : clampD(p.detailScore, 0, 1),
    );
  }

  final baseTileIds = List<String>.filled(n, '');
  for (var i = 0; i < n; i++) {
    baseTileIds[i] = getBaseTileId(placements[i].tileId);
  }

  final td = ResolvedTile();

  final baseLum = Float64List(n);
  final baseChA = Float64List(n);
  final baseChB = Float64List(n);
  final tileLum = Float64List(n);
  final tileChA = Float64List(n);
  final tileChB = Float64List(n);
  for (var i = 0; i < n; i++) {
    baseLum[i] = placements[i].averageLabColor.L / 100;
    baseChA[i] = placements[i].averageLabColor.a / 128;
    baseChB[i] = placements[i].averageLabColor.b / 128;
  }

  final scores = Float64List(n);
  for (var i = 0; i < n; i++) {
    final tile = tileMap[placements[i].tileId];
    if (tile != null) {
      scores[i] =
          _visualScoreFast(placements[i], tile, settings, regionConsts[i], td);
      tileLum[i] = td.avgL / 100;
      tileChA[i] = td.avgA / 128;
      tileChB[i] = td.avgB / 128;
    }
  }

  var medianW = 0.0;
  if (n > 0) {
    final widths = placements.map((p) => p.width).toList()..sort();
    medianW = widths[(widths.length / 2).floor()];
  }
  final reach = math.max(medianW, n > 0 ? placements[0].height : 0) *
      (3 + settings.reusePenalty * 4);
  final pCx = Float64List(n);
  final pCy = Float64List(n);
  for (var i = 0; i < n; i++) {
    pCx[i] = placements[i].x + placements[i].width / 2;
    pCy[i] = placements[i].y + placements[i].height / 2;
  }

  final cellSize = math.max(1, reach);
  final maxRight =
      placements.fold<double>(0, (m, p) => math.max(m, p.x + p.width));
  final gridCols = (maxRight / cellSize).ceil() + 1;
  final spatialGrid = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final gc = (pCx[i] / cellSize).floor();
    final gr = (pCy[i] / cellSize).floor();
    final key = gr * gridCols + gc;
    (spatialGrid[key] ??= []).add(i);
  }

  final nearbyIndices = List<List<int>>.filled(n, const []);
  final nearbyProximities = List<List<double>>.filled(n, const []);
  for (var i = 0; i < n; i++) {
    final idxs = <int>[];
    final proxs = <double>[];
    final gc = (pCx[i] / cellSize).floor();
    final gr = (pCy[i] / cellSize).floor();
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final bucket = spatialGrid[(gr + dr) * gridCols + (gc + dc)];
        if (bucket == null) continue;
        for (final j in bucket) {
          if (j == i) continue;
          final dx = pCx[i] - pCx[j];
          final dy = pCy[i] - pCy[j];
          final dist = math.sqrt(dx * dx + dy * dy);
          final prox = 1 - dist / reach;
          if (prox > 0) {
            idxs.add(j);
            proxs.add(prox);
          }
        }
      }
    }
    nearbyIndices[i] = idxs;
    nearbyProximities[i] = proxs;
  }

  final scaledPenalty = skipProximityPenalty
      ? 0.0
      : _neighborDuplicatePenaltyBase +
          settings.reusePenalty * _neighborDuplicatePenaltyScale;
  final proxPenaltyPerCell = Float64List(n);
  for (var i = 0; i < n; i++) {
    proxPenaltyPerCell[i] = scaledPenalty * (0.7 + regionConsts[i].saliency * 0.6);
  }

  double proximityPenalty(int idx, String baseId) {
    final idxs = nearbyIndices[idx];
    final proxs = nearbyProximities[idx];
    var maxProx = 0.0;
    for (var k = 0; k < idxs.length; k++) {
      if (baseTileIds[idxs[k]] == baseId) {
        if (proxs[k] > maxProx) maxProx = proxs[k];
      }
    }
    return maxProx * proxPenaltyPerCell[idx];
  }

  final adjArrays = adjacency?.map((s) => s.toList()).toList();

  double transitionCost(int idx) {
    if (skipTransitionCost || adjArrays == null) return 0;
    final adj = adjArrays[idx];
    var err = 0.0;
    for (var k = 0; k < adj.length; k++) {
      final nIdx = adj[k];
      final eL = (tileLum[idx] - tileLum[nIdx] - (baseLum[idx] - baseLum[nIdx])) * 2;
      final eA = tileChA[idx] - tileChA[nIdx] - (baseChA[idx] - baseChA[nIdx]);
      final eB = tileChB[idx] - tileChB[nIdx] - (baseChB[idx] - baseChB[nIdx]);
      err += eL * eL + eA * eA + eB * eB;
    }
    return err;
  }

  final initialTemp = isMinDetail ? _saInitialTempMinDetail : _saInitialTemp;
  final tempSteps =
      (math.log(_saMinTemp / initialTemp) / math.log(_saCoolingRate)).ceil();
  final iterFactor =
      isMinDetail ? _saIterationsPerTempFactor * 12 : _saIterationsPerTempFactor;
  final iterCap = jsRound((isMinDetail
              ? _saMaxTotalIterations * 2
              : isMobile
                  ? _saMaxTotalIterationsMobile
                  : _saMaxTotalIterations) *
          budgetFactor)
      .toInt();
  final iterationsPerTemp = math.max(
      50,
      math.min(
          jsRound(n * iterFactor.toDouble()).toInt(), (iterCap / tempSteps).floor()));

  final saPortraitIndices = <int>[];
  final saLandscapeIndices = <int>[];
  final saSquareIndices = <int>[];
  for (var i = 0; i < n; i++) {
    if (regionConsts[i].cellIsPortrait) {
      saPortraitIndices.add(i);
    } else if (regionConsts[i].cellIsLandscape) {
      saLandscapeIndices.add(i);
    } else {
      saSquareIndices.add(i);
    }
  }

  var temp = isMinDetail ? _saInitialTempMinDetail : _saInitialTemp;
  var rngState = _u32((n * 2654435761) ^ (seedOffset * 1664525));
  if (rngState == 0) rngState = 1;

  while (temp > _saMinTemp) {
    for (var iter = 0; iter < iterationsPerTemp; iter++) {
      rngState = _u32(rngState ^ _u32(rngState << 13));
      rngState = _u32(rngState ^ (_i32(rngState) >> 17));
      rngState = _u32(rngState ^ _u32(rngState << 5));
      final i = rngState % n;

      int j;
      final useLocal =
          adjArrays != null && adjArrays[i].isNotEmpty && (iter & 1) == 0;
      if (useLocal) {
        j = adjArrays[i][rngState % adjArrays[i].length];
      } else {
        rngState = _u32(rngState ^ _u32(rngState << 13));
        rngState = _u32(rngState ^ (_i32(rngState) >> 17));
        rngState = _u32(rngState ^ _u32(rngState << 5));
        final saOrientGroup = regionConsts[i].cellIsPortrait
            ? saPortraitIndices
            : regionConsts[i].cellIsLandscape
                ? saLandscapeIndices
                : saSquareIndices;
        if (saOrientGroup.length > 1 && (rngState & 3) != 0) {
          j = saOrientGroup[(rngState >> 2) % saOrientGroup.length];
          if (j == i) {
            j = saOrientGroup[((rngState >> 2) + 1) % saOrientGroup.length];
          }
        } else {
          j = rngState % (n - 1);
          if (j >= i) j++;
        }
      }

      if (baseTileIds[i] == baseTileIds[j]) continue;

      final tileA = tileMap[placements[i].tileId];
      final tileB = tileMap[placements[j].tileId];
      if (tileA == null || tileB == null) continue;

      final baseIdA = baseTileIds[i];
      final baseIdB = baseTileIds[j];

      final si = saliency != null ? saliency[i] : placements[i].detailScore;
      final sj = saliency != null ? saliency[j] : placements[j].detailScore;
      final importance = 1 + (si + sj) * 2;

      final currentProxPenalty =
          proximityPenalty(i, baseIdA) + proximityPenalty(j, baseIdB);
      final currentCost =
          (scores[i] + scores[j]) * importance + currentProxPenalty;

      final swapScoreI =
          _visualScoreFast(placements[i], tileB, settings, regionConsts[i], td);
      final swapLumI = td.avgL / 100, swapChAI = td.avgA / 128, swapChBI = td.avgB / 128;
      final swapScoreJ =
          _visualScoreFast(placements[j], tileA, settings, regionConsts[j], td);
      final swapLumJ = td.avgL / 100, swapChAJ = td.avgA / 128, swapChBJ = td.avgB / 128;

      final swapProxPenalty =
          proximityPenalty(i, baseIdB) + proximityPenalty(j, baseIdA);
      final swapCost = (swapScoreI + swapScoreJ) * importance + swapProxPenalty;

      final oldTrans = transitionCost(i) + transitionCost(j);
      final sLI = tileLum[i], sLJ = tileLum[j];
      final sAI = tileChA[i], sAJ = tileChA[j];
      final sBI = tileChB[i], sBJ = tileChB[j];
      tileLum[i] = swapLumI;
      tileLum[j] = swapLumJ;
      tileChA[i] = swapChAI;
      tileChA[j] = swapChAJ;
      tileChB[i] = swapChBI;
      tileChB[j] = swapChBJ;
      final newTrans = transitionCost(i) + transitionCost(j);
      tileLum[i] = sLI;
      tileLum[j] = sLJ;
      tileChA[i] = sAI;
      tileChA[j] = sAJ;
      tileChB[i] = sBI;
      tileChB[j] = sBJ;
      final salAvg = (regionConsts[i].saliency + regionConsts[j].saliency) * 0.5;
      final transDelta = (newTrans - oldTrans) * _saTransitionWeight * (1 + salAvg);

      final delta = swapCost - currentCost + transDelta;
      if (delta < 0 ||
          math.exp(-delta / temp) > (rngState & 0x7fffffff) / 0x7fffffff) {
        final tmpId = placements[i].tileId;
        final tmpName = placements[i].tileName;
        placements[i].tileId = placements[j].tileId;
        placements[i].tileName = placements[j].tileName;
        placements[j].tileId = tmpId;
        placements[j].tileName = tmpName;
        baseTileIds[i] = baseIdB;
        baseTileIds[j] = baseIdA;
        scores[i] = swapScoreI;
        scores[j] = swapScoreJ;
        tileLum[i] = swapLumI;
        tileLum[j] = swapLumJ;
        tileChA[i] = swapChAI;
        tileChA[j] = swapChAJ;
        tileChB[i] = swapChBI;
        tileChB[j] = swapChBJ;
      }
    }
    temp *= _saCoolingRate;
  }
}

// ── Global palette balance (post-SA tile replacement) ───────────────────────

const double _paletteDeltaPerPlacementThreshold = 0.02;
const double _paletteVisualTolerance = 0.15;
const int _paletteMaxIterations = 5000;
const int _paletteMaxIterationsFactor = 2;
const double _paletteUsageLimitFactor = 2.0;

void balanceGlobalPalette(
  List<MosaicPlacement> placements,
  Map<String, TileDescriptor> tileMap,
  MosaicSettings settings, {
  List<Set<int>>? adjacency,
  Float64List? saliency,
}) {
  final n = placements.length;
  if (n < 10) return;

  final pool = <TileDescriptor>[];
  for (final t in tileMap.values) {
    if (t.tonalHistogram != null) pool.add(t);
  }
  if (pool.length < 2) return;

  final targetHist = Float64List(8);
  for (var i = 0; i < n; i++) {
    final h = placements[i].tonalHistogram;
    for (var b = 0; b < 8; b++) {
      targetHist[b] += h[b];
    }
  }

  final currentHist = Float64List(8);
  for (var i = 0; i < n; i++) {
    final tile = tileMap[placements[i].tileId];
    final th = tile?.tonalHistogram;
    if (th != null) {
      for (var b = 0; b < 8; b++) {
        currentHist[b] += th[b];
      }
    } else {
      for (var b = 0; b < 8; b++) {
        currentHist[b] += 0.125;
      }
    }
  }

  var currentDelta = 0.0;
  for (var b = 0; b < 8; b++) {
    currentDelta += (currentHist[b] - targetHist[b]).abs();
  }
  if (currentDelta < n * _paletteDeltaPerPlacementThreshold) return;

  final regionConsts = <RegionConstants>[];
  for (var i = 0; i < n; i++) {
    final p = placements[i];
    final regionAR = p.width / p.height;
    final regionEdgeMean = _weightedEdgeMean(p.subregionEdges, null);
    final rA = p.averageLabColor.a;
    final rB = p.averageLabColor.b;
    regionConsts.add(RegionConstants(
      regionAR: regionAR,
      cellIsPortrait: regionAR < 0.85,
      cellIsLandscape: regionAR > 1.18,
      regionEdgeMean: regionEdgeMean,
      texThreshold: _adaptiveTextureThreshold(regionEdgeMean),
      regionChroma: math.sqrt(rA * rA + rB * rB),
      regionL: p.averageLabColor.L,
      saliency: saliency != null ? saliency[i] : clampD(p.detailScore, 0, 1),
    ));
  }

  final usageCounts = <String, int>{};
  for (final p in placements) {
    final baseId = getBaseTileId(p.tileId);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;
  }
  final usageLimit =
      math.max(1, (n / pool.length * _paletteUsageLimitFactor).ceil());

  final adjArrays = adjacency?.map((s) => s.toList()).toList();

  final td = ResolvedTile();

  final scores = Float64List(n);
  for (var i = 0; i < n; i++) {
    final tile = tileMap[placements[i].tileId];
    if (tile != null) {
      scores[i] =
          _visualScoreFast(placements[i], tile, settings, regionConsts[i], td);
    }
  }

  var rngState = _u32(n * 2246822519);
  if (rngState == 0) rngState = 1;
  int next() {
    rngState = _u32(rngState ^ _u32(rngState << 13));
    rngState = _u32(rngState ^ (_i32(rngState) >> 17));
    rngState = _u32(rngState ^ _u32(rngState << 5));
    return rngState;
  }

  final maxIter = math.min(_paletteMaxIterations, n * _paletteMaxIterationsFactor);
  final deltaThreshold = n * _paletteDeltaPerPlacementThreshold;

  for (var iter = 0; iter < maxIter; iter++) {
    if (currentDelta < deltaThreshold) break;

    final i = next() % n;
    final placement = placements[i];
    final currentTile = tileMap[placement.tileId];
    if (currentTile?.tonalHistogram == null) continue;

    final ci = next() % pool.length;
    final candidate = pool[ci];
    if (identical(candidate, currentTile)) continue;

    final candidateBaseId = getBaseTileId(candidate.id);
    final oldBaseId = getBaseTileId(placement.tileId);
    if (candidateBaseId == oldBaseId) continue;

    final candidateUsage = usageCounts[candidateBaseId] ?? 0;
    if (candidateUsage >= usageLimit) continue;

    if (adjArrays != null) {
      final adj = adjArrays[i];
      var collision = false;
      for (var k = 0; k < adj.length; k++) {
        if (getBaseTileId(placements[adj[k]].tileId) == candidateBaseId) {
          collision = true;
          break;
        }
      }
      if (collision) continue;
    }

    final cHist = currentTile!.tonalHistogram!;
    final tHist = candidate.tonalHistogram!;
    var newDelta = currentDelta;
    for (var b = 0; b < 8; b++) {
      final oldBinDelta = (currentHist[b] - targetHist[b]).abs();
      final newBinValue = currentHist[b] - cHist[b] + tHist[b];
      final newBinDelta = (newBinValue - targetHist[b]).abs();
      newDelta += newBinDelta - oldBinDelta;
    }
    if (newDelta >= currentDelta) continue;

    final candidateScore =
        _visualScoreFast(placement, candidate, settings, regionConsts[i], td);
    if (candidateScore - scores[i] > _paletteVisualTolerance) continue;

    for (var b = 0; b < 8; b++) {
      currentHist[b] += tHist[b] - cHist[b];
    }
    currentDelta = newDelta;
    usageCounts[oldBaseId] = math.max(0, (usageCounts[oldBaseId] ?? 1) - 1);
    usageCounts[candidateBaseId] = candidateUsage + 1;
    placement.tileId = candidate.id;
    placement.tileName = candidate.name;
    placement.score = candidateScore;
    scores[i] = candidateScore;
  }
}
