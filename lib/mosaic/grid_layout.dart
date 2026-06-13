import 'dart:math' as math;
import 'dart:typed_data';

import 'analyze.dart';
import 'matching.dart';
import 'shared.dart';
import 'types.dart';

/// Dart port of `foto-mozaik/lib/mosaic/grid-layout.ts` — the active layout
/// orchestrator (`browser.ts` imports `buildGridLayout` from here).
///
/// The web parallelizes scoring via a Web Worker pool (`scoring-pool.ts`) whose
/// output is documented as "bit-identical to the main-thread version"; we run
/// the sync equivalents inline. Async `yieldToMain()` calls are cooperative
/// only and dropped (this is meant to run inside an Isolate).
///
/// Fidelity note: the uniform path (square/landscape/portrait — the app
/// default) sorts only by transitive numeric comparators, so it is
/// deterministic and bit-exact. The original/blocks multi-cell path uses one
/// non-transitive comparator (the 0.01 improvement threshold); it is ported
/// faithfully but the sort tiebreak order is not guaranteed identical to V8's
/// TimSort when many candidates tie within 0.01.

// ── JS 32-bit helpers (local copies; matching.dart's are private) ───────────
int _u32(int x) => x & 0xFFFFFFFF;
int _i32(int x) {
  final v = x & 0xFFFFFFFF;
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

/// Stable sort preserving original order on ties (matches JS Array.sort for
/// transitive comparators).
void _stableSort<T>(List<T> list, int Function(T a, T b) cmp) {
  final indexed =
      List<MapEntry<int, T>>.generate(list.length, (i) => MapEntry(i, list[i]));
  indexed.sort((a, b) {
    final c = cmp(a.value, b.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].value;
  }
}

class CellShape {
  const CellShape(this.cols, this.rows, this.cells, this.ar);
  final int cols;
  final int rows;
  final int cells;
  final double ar;
}

const double _maxCrop = 0.28;
const double _maxCropFallback = 0.35;

const List<CellShape> _multiCellShapes = [
  CellShape(3, 3, 9, 1.0),
  CellShape(2, 4, 8, 0.5),
  CellShape(4, 2, 8, 2.0),
  CellShape(2, 3, 6, 2 / 3),
  CellShape(3, 2, 6, 3 / 2),
  CellShape(2, 2, 4, 1.0),
  CellShape(1, 2, 2, 0.5),
  CellShape(2, 1, 2, 2.0),
];

const List<CellShape> _fillShapes = [
  CellShape(2, 3, 6, 2 / 3),
  CellShape(3, 2, 6, 3 / 2),
  CellShape(2, 2, 4, 1.0),
  CellShape(1, 2, 2, 0.5),
  CellShape(2, 1, 2, 2.0),
  CellShape(1, 1, 1, 1.0),
];

const CellShape _shape1x1 = CellShape(1, 1, 1, 1.0);

const List<CellShape> _blocksShapes = [
  CellShape(3, 2, 6, 3 / 2),
  CellShape(2, 3, 6, 2 / 3),
  CellShape(2, 2, 4, 1.0),
];
const List<CellShape> _blocksFillShapes = [
  CellShape(3, 2, 6, 3 / 2),
  CellShape(2, 3, 6, 2 / 3),
  CellShape(2, 2, 4, 1.0),
  _shape1x1,
];

// ── Spatial grid ────────────────────────────────────────────────────────────

class SpatialGrid {
  SpatialGrid(this.cellSize, this.cols);
  final Map<int, List<int>> buckets = {};
  double cellSize;
  int cols;
}

SpatialGrid _createSpatialGrid(double cellSize, double totalWidth) {
  final cs = math.max(1, cellSize).toDouble();
  return SpatialGrid(cs, (totalWidth / cs).ceil() + 2);
}

void _spatialInsert(SpatialGrid grid, int index, double cx, double cy) {
  final key =
      (cy / grid.cellSize).floor() * grid.cols + (cx / grid.cellSize).floor();
  (grid.buckets[key] ??= []).add(index);
}

List<int> _spatialQuery(SpatialGrid grid, double cx, double cy, double reach) {
  final r = (reach / grid.cellSize).ceil();
  final gc = (cx / grid.cellSize).floor();
  final gr = (cy / grid.cellSize).floor();
  final result = <int>[];
  for (var dr = -r; dr <= r; dr++) {
    for (var dc = -r; dc <= r; dc++) {
      final bucket = grid.buckets[(gr + dr) * grid.cols + (gc + dc)];
      if (bucket != null) {
        for (var k = 0; k < bucket.length; k++) {
          result.add(bucket[k]);
        }
      }
    }
  }
  return result;
}

double _cropFraction(double tileAR, double shapeAR) =>
    1 - math.min(tileAR, shapeAR) / math.max(tileAR, shapeAR);

List<TileDescriptor>? _poolForShape(
    Map<double, List<TileDescriptor>> tilePools, double ar) {
  final exact = tilePools[ar];
  if (exact != null) return exact;
  double? bestKey;
  var bestDiff = double.infinity;
  for (final key in tilePools.keys) {
    final diff = (math.log(ar / key)).abs();
    if (diff < bestDiff) {
      bestDiff = diff;
      bestKey = key;
    }
  }
  return bestKey != null ? tilePools[bestKey] : null;
}

bool _orientationCompatible(double tileAR, double shapeAR) {
  final tileIsPortrait = tileAR < 0.85;
  final tileIsLandscape = tileAR > 1.18;
  final tileIsSquare = !tileIsPortrait && !tileIsLandscape;
  final shapeIsPortrait = shapeAR < 0.85;
  final shapeIsLandscape = shapeAR > 1.18;
  final shapeIsSquare = !shapeIsPortrait && !shapeIsLandscape;
  if (tileIsPortrait && shapeIsLandscape) return false;
  if (tileIsLandscape && shapeIsPortrait) return false;
  if (tileIsSquare && shapeIsLandscape) return false;
  if (tileIsSquare && shapeIsPortrait) return false;
  if (tileIsPortrait && shapeIsSquare) return false;
  if (tileIsLandscape && shapeIsSquare) return false;
  return true;
}

// ── Error diffusion ─────────────────────────────────────────────────────────

const double _maxColorError = 30;
const double _diffuseMaxColorD = 50;
const double _baseDiffuseStrength = 0.35;

String _cellKey(int col, int row) => '$col,$row';

void _addCellError(Map<String, LabColor> errors, int col, int row, double dL,
    double da, double db, double strength) {
  final key = _cellKey(col, row);
  final prev = errors[key];
  errors[key] = LabColor(
    math.max(-_maxColorError,
        math.min(_maxColorError, (prev?.L ?? 0) + dL * strength)),
    math.max(-_maxColorError,
        math.min(_maxColorError, (prev?.a ?? 0) + da * strength)),
    math.max(-_maxColorError,
        math.min(_maxColorError, (prev?.b ?? 0) + db * strength)),
  );
}

void _spreadColorError(
    Map<String, LabColor> errors,
    int col,
    int row,
    CellShape shape,
    int M,
    int N,
    List<List<bool>> occupied,
    double residualL,
    double residualA,
    double residualB) {
  final magSq =
      residualL * residualL + residualA * residualA + residualB * residualB;
  if (magSq > _diffuseMaxColorD * _diffuseMaxColorD) return;

  final neighbors = <List<int>>[];
  for (var dr = -1; dr <= shape.rows; dr++) {
    for (var dc = -1; dc <= shape.cols; dc++) {
      if (dr >= 0 && dr < shape.rows && dc >= 0 && dc < shape.cols) continue;
      final nc = col + dc;
      final nr = row + dr;
      if (nc < 0 || nc >= M || nr < 0 || nr >= N) continue;
      if (occupied[nr][nc]) continue;
      neighbors.add([nc, nr]);
    }
  }
  if (neighbors.isEmpty) return;

  final perNeighbor = _baseDiffuseStrength / neighbors.length;
  for (final nb in neighbors) {
    _addCellError(errors, nb[0], nb[1], residualL, residualA, residualB,
        perNeighbor);
  }
}

// ── Constants ───────────────────────────────────────────────────────────────

const int _maxPlacements = 6500;
const int _optimalAssignmentMaxRegions = 4000;
const int _lowCountSeedAttempts = 3;
const double _originalCellsPerTile = 3.0;
const double _blocksCellsPerTile = 5.0;
const int _maxCellsOriginal = 45000;

class _GridDims {
  _GridDims(this.M, this.N, this.cellW, this.cellH);
  int M;
  int N;
  double cellW;
  double cellH;
}

/// Builds the full mosaic plan placement list. [isMobile] selects the SA
/// iteration cap (false = full desktop budget, matching the web's Node-side
/// reference; the engine passes true on phones).
List<MosaicPlacement> buildGridLayout({
  required double baseWidth,
  required double baseHeight,
  required ImageAnalyzer analyzer,
  required List<TileDescriptor> tiles,
  required MosaicSettings settings,
  List<FaceRect> faceRegions = const [],
  bool isMobile = false,
}) {
  final mode = settings.mosaicMode;
  final uniformMode = mode != 'original' && mode != 'blocks';

  _GridDims gridDims;
  if (mode == 'square') {
    gridDims = _computeSquareGrid(baseWidth, baseHeight, settings.density);
  } else if (mode == 'landscape') {
    gridDims =
        _computeFixedARGrid(baseWidth, baseHeight, settings.density, 3 / 2);
  } else if (mode == 'portrait') {
    gridDims =
        _computeFixedARGrid(baseWidth, baseHeight, settings.density, 2 / 3);
  } else {
    gridDims = _computeGrid(baseWidth, baseHeight, settings.density);
  }

  var M = gridDims.M, N = gridDims.N;
  var cellW = gridDims.cellW, cellH = gridDims.cellH;

  final maxCells = uniformMode ? _maxPlacements : _maxCellsOriginal;
  if (M * N > maxCells) {
    final scale = math.sqrt(maxCells / (M * N));
    M = math.max(4, jsRound(M * scale).toInt());
    N = math.max(4, jsRound(N * scale).toInt());
    cellW = baseWidth / M;
    cellH = baseHeight / N;
  }

  final tilePools = _buildTilePools(tiles);
  final placements = <MosaicPlacement>[];
  final grid = _createSpatialGrid(math.max(cellW, cellH), baseWidth + cellW);
  final cellSaliency = _computeCellSaliency(
      M, N, cellW, cellH, baseWidth, baseHeight, faceRegions);

  final totalGridCells = M * N;
  final cellsPerTile =
      mode == 'blocks' ? _blocksCellsPerTile : _originalCellsPerTile;
  final estimatedPlacements = uniformMode
      ? totalGridCells
      : jsRound(totalGridCells / cellsPerTile).toInt();

  if (uniformMode) {
    final cellAR =
        mode == 'landscape' ? 3 / 2 : mode == 'portrait' ? 2 / 3 : 1.0;
    final pool = (mode == 'landscape' || mode == 'portrait')
        ? (tilePools[cellAR] ?? tiles)
        : tiles;
    final resolved = preResolveTiles(pool, cellAR);
    _fillUniformGrid(M, N, cellW, cellH, cellSaliency, resolved, analyzer,
        settings, placements, grid, pool.length, estimatedPlacements);
  } else {
    final occupied =
        List.generate(N, (_) => List<bool>.filled(M, false), growable: false);
    final usageCounts = <String, int>{};
    final baselinePool = tilePools[1.0] ?? tiles;
    final baselines =
        _computeBaselines(M, N, cellW, cellH, analyzer, baselinePool, settings);

    final isBlocks = mode == 'blocks';
    final colorErrors = <String, LabColor>{};
    _placeMultiCellShapes(
        M, N, cellW, cellH, occupied, baselines, cellSaliency, tilePools,
        analyzer, settings, usageCounts, placements, grid, tiles.length,
        estimatedPlacements, isBlocks ? _blocksShapes : null, colorErrors);

    _fillRemainingCells(
        M, N, cellW, cellH, occupied, baselines, cellSaliency, tilePools,
        analyzer, settings, usageCounts, placements, grid, tiles.length,
        estimatedPlacements, isBlocks ? _blocksFillShapes : null,
        isBlocks ? 0.95 : 0.5, colorErrors);

    if (isMinimumDetailOriginalMode(settings)) {
      _refineShapesByMerging(placements, cellW, cellH, tilePools, analyzer,
          settings, usageCounts, tiles.length, estimatedPlacements);
    }
  }

  final tileMap = {for (final t in tiles) t.id: t};

  final adjacency = _buildAdjacencyMap(placements);
  final saliency = _computePlacementSaliency(
      placements, adjacency, baseWidth, baseHeight, faceRegions);

  final saBudgetFactor = placements.isNotEmpty &&
          placements.length <= _optimalAssignmentMaxRegions
      ? 0.25
      : 1.0;
  if (saBudgetFactor < 1.0) {
    try {
      _vogelAssign(placements, tiles, settings, saliency);
    } catch (_) {
      // Fall back to greedy result.
    }

    final n = placements.length;
    final vogelTileIds = List<String>.generate(n, (i) => placements[i].tileId);
    final vogelTileNames =
        List<String>.generate(n, (i) => placements[i].tileName);

    var bestScore = double.infinity;
    final bestTileIds = List<String>.filled(n, '');
    final bestTileNames = List<String>.filled(n, '');

    for (var attempt = 0; attempt < _lowCountSeedAttempts; attempt++) {
      if (attempt > 0) {
        for (var i = 0; i < n; i++) {
          placements[i].tileId = vogelTileIds[i];
          placements[i].tileName = vogelTileNames[i];
        }
      }

      optimizePlacementSwaps(placements, tileMap, settings,
          adjacency: adjacency,
          saliency: saliency,
          budgetFactor: saBudgetFactor,
          seedOffset: attempt,
          isMobile: isMobile);
      balanceGlobalPalette(placements, tileMap, settings,
          adjacency: adjacency, saliency: saliency);

      final score =
          _scoreMosaicReconstruction(placements, tileMap, saliency, adjacency);
      if (score < bestScore) {
        bestScore = score;
        for (var i = 0; i < n; i++) {
          bestTileIds[i] = placements[i].tileId;
          bestTileNames[i] = placements[i].tileName;
        }
      }
    }

    for (var i = 0; i < n; i++) {
      placements[i].tileId = bestTileIds[i];
      placements[i].tileName = bestTileNames[i];
    }
  } else {
    optimizePlacementSwaps(placements, tileMap, settings,
        adjacency: adjacency, saliency: saliency, budgetFactor: saBudgetFactor,
        isMobile: isMobile);
    balanceGlobalPalette(placements, tileMap, settings,
        adjacency: adjacency, saliency: saliency);
  }

  return placements;
}

_GridDims _computeGrid(double baseWidth, double baseHeight, double density) {
  final shorter = math.min(baseWidth, baseHeight);
  final longer = math.max(baseWidth, baseHeight);
  final aspect = longer / shorter;
  final cellsOnShort = math.max(4, jsRound(density / 4).toInt());
  final cellsOnLong = math.max(4, jsRound(cellsOnShort * aspect).toInt());
  final M = baseWidth >= baseHeight ? cellsOnLong : cellsOnShort;
  final N = baseWidth >= baseHeight ? cellsOnShort : cellsOnLong;
  return _GridDims(M, N, baseWidth / M, baseHeight / N);
}

_GridDims _computeSquareGrid(
    double baseWidth, double baseHeight, double density) {
  final shorter = math.min(baseWidth, baseHeight);
  final cellsOnShort = math.max(4, jsRound(density / 4).toInt());
  final cellSize = shorter / cellsOnShort;
  final M = math.max(1, jsRound(baseWidth / cellSize).toInt());
  final N = math.max(1, jsRound(baseHeight / cellSize).toInt());
  return _GridDims(M, N, baseWidth / M, baseHeight / N);
}

_GridDims _computeFixedARGrid(
    double baseWidth, double baseHeight, double density, double cellAR) {
  final cellsOnShort = math.max(4, jsRound(density / 4).toInt());
  final shorter = math.min(baseWidth, baseHeight);
  final targetArea = math.pow(shorter / cellsOnShort, 2).toDouble();
  final cellH = math.sqrt(targetArea / cellAR);
  final cellW = cellH * cellAR;
  final M = math.max(1, jsRound(baseWidth / cellW).toInt());
  final N = math.max(1, jsRound(baseHeight / cellH).toInt());
  return _GridDims(M, N, baseWidth / M, baseHeight / N);
}

final Expando<Map<double, List<TileDescriptor>>> _tilePoolsCache = Expando();

Map<double, List<TileDescriptor>> _buildTilePools(List<TileDescriptor> tiles) {
  final cached = _tilePoolsCache[tiles];
  if (cached != null) return cached;

  final pools = <double, List<TileDescriptor>>{};
  final uniqueARs = [1.0, 0.5, 2.0, 2 / 3, 3 / 2];

  for (final ar in uniqueARs) {
    var pool = tiles
        .where((t) =>
            _orientationCompatible(t.aspectRatio, ar) &&
            _cropFraction(t.aspectRatio, ar) < _maxCrop)
        .toList();
    if (pool.length < 3) {
      pool = tiles
          .where((t) =>
              _orientationCompatible(t.aspectRatio, ar) &&
              _cropFraction(t.aspectRatio, ar) < _maxCropFallback)
          .toList();
    }
    if (ar == 1.0 && pool.length < 3) {
      pool = List<TileDescriptor>.from(tiles);
    }
    pools[ar] = pool;
  }

  _tilePoolsCache[tiles] = pools;
  return pools;
}

// scoring-pool.ts sync equivalents (the worker output is bit-identical).
Float64List _scoreRegionsSync(List<RegionAnalysis> regions,
    List<TileDescriptor> tiles, MosaicSettings settings) {
  final out = Float64List(regions.length);
  final emptyUsage = <String, int>{};
  for (var i = 0; i < regions.length; i++) {
    out[i] = selectBestTileMatch(MatchInput(
            region: regions[i],
            tiles: tiles,
            settings: settings,
            usageCounts: emptyUsage))
        .score;
  }
  return out;
}

Float64List _scoreMultiPoolRegionsSync(
    List<RegionAnalysis> regions,
    Float32List saliencies,
    List<int> poolIndex,
    List<List<TileDescriptor>> pools,
    MosaicSettings settings) {
  final out = Float64List(regions.length);
  final emptyUsage = <String, int>{};
  for (var i = 0; i < regions.length; i++) {
    out[i] = selectBestTileMatch(MatchInput(
            region: regions[i],
            tiles: pools[poolIndex[i]],
            settings: settings,
            usageCounts: emptyUsage,
            saliency: saliencies[i]))
        .score;
  }
  return out;
}

List<List<double>> _computeBaselines(
    int M,
    int N,
    double cellW,
    double cellH,
    ImageAnalyzer analyzer,
    List<TileDescriptor> allTiles,
    MosaicSettings settings) {
  const maxSample = 60;
  List<TileDescriptor> sample;
  if (allTiles.length <= maxSample) {
    sample = allTiles;
  } else {
    var rng = _u32(allTiles.length * 2654435761);
    if (rng == 0) rng = 1;
    int advance() {
      rng = _u32(rng ^ _u32(rng << 13));
      rng = _u32(rng ^ (_i32(rng) >> 17));
      rng = _u32(rng ^ _u32(rng << 5));
      return rng;
    }

    final picked = <int>{};
    while (picked.length < maxSample) {
      picked.add(advance() % allTiles.length);
    }
    sample = picked.map((i) => allTiles[i]).toList();
  }

  final regions = List<RegionAnalysis>.filled(
      M * N,
      analyzer.sampleRegion(x: 0, y: 0, width: 1, height: 1),
      growable: false);
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      regions[r * M + c] = analyzer.sampleRegion(
          x: c * cellW, y: r * cellH, width: cellW, height: cellH);
    }
  }

  final flatScores = _scoreRegionsSync(regions, sample, settings);

  final scores = List<List<double>>.generate(N, (r) {
    final row = List<double>.filled(M, 0);
    for (var c = 0; c < M; c++) {
      row[c] = flatScores[r * M + c];
    }
    return row;
  });
  return scores;
}

List<List<double>> _computeCellSaliency(int M, int N, double cellW,
    double cellH, double baseWidth, double baseHeight, List<FaceRect> faceRegions) {
  final cx = baseWidth / 2;
  final cy = baseHeight / 2;
  final maxDist = math.sqrt(cx * cx + cy * cy);
  final hasFaces = faceRegions.isNotEmpty;
  final saliency = <List<double>>[];
  var maxVal = 0.0;

  for (var r = 0; r < N; r++) {
    final row = <double>[];
    for (var c = 0; c < M; c++) {
      final rcx = (c + 0.5) * cellW;
      final rcy = (r + 0.5) * cellH;
      final centerProximity = 1 -
          math.sqrt(math.pow(rcx - cx, 2).toDouble() +
                  math.pow(rcy - cy, 2).toDouble()) /
              maxDist;

      var faceOverlap = 0.0;
      if (hasFaces) {
        final cellArea = cellW * cellH;
        for (final f in faceRegions) {
          final ox = math.max(
              0,
              math.min(c * cellW + cellW, f.x + f.width) -
                  math.max(c * cellW, f.x));
          final oy = math.max(
              0,
              math.min(r * cellH + cellH, f.y + f.height) -
                  math.max(r * cellH, f.y));
          faceOverlap = math.max(faceOverlap, (ox * oy) / cellArea);
        }
      }

      final val = hasFaces
          ? centerProximity * 0.3 + faceOverlap * 0.7
          : centerProximity;
      row.add(val);
      if (val > maxVal) maxVal = val;
    }
    saliency.add(row);
  }

  if (maxVal > 0) {
    for (var r = 0; r < N; r++) {
      for (var c = 0; c < M; c++) {
        saliency[r][c] /= maxVal;
      }
    }
  }

  return saliency;
}

double _avgCellSaliency(
    int col, int row, CellShape shape, List<List<double>> cellSaliency) {
  var sum = 0.0;
  for (var dr = 0; dr < shape.rows; dr++) {
    for (var dc = 0; dc < shape.cols; dc++) {
      sum += cellSaliency[row + dr][col + dc];
    }
  }
  return sum / shape.cells;
}

class _ShapeCandidate {
  _ShapeCandidate(this.col, this.row, this.shape, this.totalImprovement,
      this.region, this.saliency);
  int col;
  int row;
  CellShape shape;
  double totalImprovement;
  RegionAnalysis region;
  double saliency;
}

void _placeMultiCellShapes(
    int M,
    int N,
    double cellW,
    double cellH,
    List<List<bool>> occupied,
    List<List<double>> baselines,
    List<List<double>> cellSaliency,
    Map<double, List<TileDescriptor>> tilePools,
    ImageAnalyzer analyzer,
    MosaicSettings settings,
    Map<String, int> usageCounts,
    List<MosaicPlacement> placements,
    SpatialGrid grid,
    int tilePoolSize,
    int placementCount,
    List<CellShape>? shapesOverride,
    Map<String, LabColor>? colorErrors) {
  final regions = <RegionAnalysis>[];
  final positions = <({int col, int row, CellShape shape, double avgBaseline})>[];
  final saliencyList = <double>[];
  final poolIndexList = <int>[];

  final poolList = <List<TileDescriptor>>[];
  final poolKeyByAR = <double, int>{};
  int getPoolIndex(List<TileDescriptor> pool, double ar) {
    final existing = poolKeyByAR[ar];
    if (existing != null) return existing;
    final idx = poolList.length;
    poolList.add(pool);
    poolKeyByAR[ar] = idx;
    return idx;
  }

  final isMinDetail = isMinimumDetailOriginalMode(settings);
  final isBlocks = settings.mosaicMode == 'blocks';
  final shapesToTry = shapesOverride ?? _multiCellShapes;
  final minBaselineForShape = (isMinDetail || isBlocks) ? 0.0 : 0.06;

  for (final shape in shapesToTry) {
    final pool = _poolForShape(tilePools, shape.ar);
    if (pool == null || pool.isEmpty) continue;
    final poolIdx = getPoolIndex(pool, shape.ar);

    final posStride = shape.cells >= 16 ? 3 : shape.cells >= 8 ? 2 : 1;

    for (var r = 0; r <= N - shape.rows; r += posStride) {
      for (var c = 0; c <= M - shape.cols; c += posStride) {
        var baselineSum = 0.0;
        for (var dr = 0; dr < shape.rows; dr++) {
          for (var dc = 0; dc < shape.cols; dc++) {
            baselineSum += baselines[r + dr][c + dc];
          }
        }
        final avgBaseline = baselineSum / shape.cells;
        if (avgBaseline < minBaselineForShape) continue;

        final region = analyzer.sampleRegion(
            x: c * cellW,
            y: r * cellH,
            width: shape.cols * cellW,
            height: shape.rows * cellH);
        final sal = _avgCellSaliency(c, r, shape, cellSaliency);

        regions.add(region);
        positions.add((col: c, row: r, shape: shape, avgBaseline: avgBaseline));
        saliencyList.add(sal);
        poolIndexList.add(poolIdx);
      }
    }
  }

  final candidates = <_ShapeCandidate>[];
  if (regions.isNotEmpty) {
    final saliencies = Float32List.fromList(saliencyList);
    final scores = _scoreMultiPoolRegionsSync(
        regions, saliencies, poolIndexList, poolList, settings);
    for (var i = 0; i < regions.length; i++) {
      final pos = positions[i];
      final perCellImprovement = pos.avgBaseline - scores[i];
      if (perCellImprovement > -0.005) {
        final sal = saliencyList[i];
        final salPenalty = sal > 0.4 && pos.shape.cells > 4
            ? 1 + (sal - 0.4) * (pos.shape.cells / 6)
            : 1.0;
        final weight = math.sqrt(pos.shape.cells) / salPenalty;
        candidates.add(_ShapeCandidate(pos.col, pos.row, pos.shape,
            perCellImprovement * weight, regions[i], sal));
      }
    }
  }

  _stableSort(candidates, (a, b) {
    final impDiff = b.totalImprovement - a.totalImprovement;
    if (impDiff.abs() > 0.01) return impDiff > 0 ? 1 : -1;
    return b.shape.cells - a.shape.cells;
  });

  for (final cand in candidates) {
    if (!_shapeFits(cand.col, cand.row, cand.shape, M, N, occupied)) continue;

    final pool = _poolForShape(tilePools, cand.shape.ar)!;
    final nearbyTiles = _collectNearbyTiles(
        cand.col, cand.row, cellW, cellH, placements, grid, settings.reusePenalty);
    final neighborAvgColor = _computeNeighborAvgColor(
        cand.col, cand.row, cellW, cellH, placements, grid);
    final colorBias = colorErrors?[_cellKey(cand.col, cand.row)];
    final m = selectBestTileMatch(MatchInput(
        region: cand.region,
        tiles: pool,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: cand.saliency,
        neighborAvgColor: neighborAvgColor,
        tilePoolSize: tilePoolSize,
        placementCount: placementCount,
        colorBias: colorBias));

    _commitPlacement(cand.col, cand.row, cand.shape, cellW, cellH, cand.region,
        m.tile, m.score, occupied, usageCounts, placements, grid);
    if (colorErrors != null) {
      _spreadColorError(
          colorErrors,
          cand.col,
          cand.row,
          cand.shape,
          M,
          N,
          occupied,
          cand.region.averageLabColor.L + (colorBias?.L ?? 0) - m.tile.averageLabColor.L,
          cand.region.averageLabColor.a + (colorBias?.a ?? 0) - m.tile.averageLabColor.a,
          cand.region.averageLabColor.b + (colorBias?.b ?? 0) - m.tile.averageLabColor.b);
    }
  }
}

void _refineShapesByMerging(
    List<MosaicPlacement> placements,
    double cellW,
    double cellH,
    Map<double, List<TileDescriptor>> tilePools,
    ImageAnalyzer analyzer,
    MosaicSettings settings,
    Map<String, int> usageCounts,
    int tilePoolSize,
    int placementCount) {
  const maxMergedCells = 9;
  const perCellTolerance = 1.15;
  const maxIterations = 2;

  final emptyUsage = <String, int>{};

  for (var iter = 0; iter < maxIterations; iter++) {
    final infos = placements.map((p) {
      final cols = math.max(1, jsRound(p.width / cellW).toInt());
      final rows = math.max(1, jsRound(p.height / cellH).toInt());
      return _MergeInfo(jsRound(p.x / cellW).toInt(),
          jsRound(p.y / cellH).toInt(), cols, rows, cols * rows, p);
    }).toList();

    final cornerMap = <String, int>{};
    for (var i = 0; i < infos.length; i++) {
      cornerMap['${infos[i].col},${infos[i].row}'] = i;
    }

    final mergedThisPass = <MosaicPlacement>[];
    var mergeCountThisPass = 0;

    for (var i = 0; i < infos.length; i++) {
      final a = infos[i];
      if (a.removed) continue;

      final candidates = <({_MergeInfo other, String direction})>[];
      final rightIdx = cornerMap['${a.col + a.cols},${a.row}'];
      if (rightIdx != null) {
        final b = infos[rightIdx];
        if (!b.removed &&
            !identical(b, a) &&
            b.rows == a.rows &&
            a.cells + b.cells <= maxMergedCells) {
          candidates.add((other: b, direction: 'h'));
        }
      }
      final downIdx = cornerMap['${a.col},${a.row + a.rows}'];
      if (downIdx != null) {
        final b = infos[downIdx];
        if (!b.removed &&
            !identical(b, a) &&
            b.cols == a.cols &&
            a.cells + b.cells <= maxMergedCells) {
          candidates.add((other: b, direction: 'v'));
        }
      }

      for (final cand in candidates) {
        final b = cand.other;
        final cols = cand.direction == 'h' ? a.cols + b.cols : a.cols;
        final rows = cand.direction == 'h' ? a.rows : a.rows + b.rows;
        final cells = cols * rows;

        final region = analyzer.sampleRegion(
            x: a.col * cellW,
            y: a.row * cellH,
            width: cols * cellW,
            height: rows * cellH);
        final mergedAR = (cols * cellW) / (rows * cellH);

        var nearestDiff = double.infinity;
        var nearestPoolAR = mergedAR;
        for (final key in tilePools.keys) {
          final diff = (math.log(mergedAR / key)).abs();
          if (diff < nearestDiff) {
            nearestDiff = diff;
            nearestPoolAR = key;
          }
        }
        if (_cropFraction(nearestPoolAR, mergedAR) > _maxCrop) continue;

        final pool = _poolForShape(tilePools, mergedAR);
        if (pool == null || pool.isEmpty) continue;

        final m = selectBestTileMatch(MatchInput(
            region: region,
            tiles: pool,
            settings: settings,
            usageCounts: emptyUsage,
            tilePoolSize: tilePoolSize,
            placementCount: placementCount));

        final mergedPerCell = m.score / cells;
        final sumPerCell =
            (a.placement.score + b.placement.score) / (a.cells + b.cells);
        if (mergedPerCell > sumPerCell * perCellTolerance) continue;

        a.removed = true;
        b.removed = true;
        _decrementUsage(usageCounts, a.placement.tileId);
        _decrementUsage(usageCounts, b.placement.tileId);
        final newBaseId = getBaseTileId(m.tile.id);
        usageCounts[newBaseId] = (usageCounts[newBaseId] ?? 0) + 1;

        mergedThisPass
            .add(region.toPlacement(-1, m.tile.id, m.tile.name, m.score));
        mergeCountThisPass++;
        break;
      }
    }

    if (mergeCountThisPass == 0) break;

    final survivors = <MosaicPlacement>[];
    for (var i = 0; i < placements.length; i++) {
      if (!infos[i].removed) survivors.add(placements[i]);
    }
    survivors.addAll(mergedThisPass);
    placements
      ..clear()
      ..addAll(survivors);
  }

  for (var i = 0; i < placements.length; i++) {
    placements[i].index = i;
  }
}

class _MergeInfo {
  _MergeInfo(this.col, this.row, this.cols, this.rows, this.cells, this.placement);
  int col;
  int row;
  int cols;
  int rows;
  int cells;
  MosaicPlacement placement;
  bool removed = false;
}

void _decrementUsage(Map<String, int> usageCounts, String tileId) {
  final baseId = getBaseTileId(tileId);
  final cur = usageCounts[baseId] ?? 0;
  if (cur <= 1) {
    usageCounts.remove(baseId);
  } else {
    usageCounts[baseId] = cur - 1;
  }
}

void _fillRemainingCells(
    int M,
    int N,
    double cellW,
    double cellH,
    List<List<bool>> occupied,
    List<List<double>> baselines,
    List<List<double>> cellSaliency,
    Map<double, List<TileDescriptor>> tilePools,
    ImageAnalyzer analyzer,
    MosaicSettings settings,
    Map<String, int> usageCounts,
    List<MosaicPlacement> placements,
    SpatialGrid grid,
    int tilePoolSize,
    int placementCount,
    List<CellShape>? shapesOverride,
    double fillSalThreshold,
    Map<String, LabColor>? colorErrors) {
  final cells = <({int col, int row, double priority, double sal})>[];
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      if (occupied[r][c]) continue;
      final sal = cellSaliency[r][c];
      cells.add(
          (col: c, row: r, priority: baselines[r][c] * 0.5 + sal * 0.5, sal: sal));
    }
  }
  _stableSort(cells, (a, b) => b.priority.compareTo(a.priority));

  for (final cell in cells) {
    final col = cell.col, row = cell.row, sal = cell.sal;
    if (occupied[row][col]) continue;

    final nearbyTiles = _collectNearbyTiles(
        col, row, cellW, cellH, placements, grid, settings.reusePenalty);
    final neighborAvgColor =
        _computeNeighborAvgColor(col, row, cellW, cellH, placements, grid);

    var bestShape = _shape1x1;
    RegionAnalysis? bestRegion;
    TileDescriptor? bestTile;
    var bestScore = double.infinity;
    final colorBias = colorErrors?[_cellKey(col, row)];

    for (final shape in (shapesOverride ?? _fillShapes)) {
      if (!_shapeFits(col, row, shape, M, N, occupied)) continue;
      if (shape.cells > 1 && sal > fillSalThreshold) continue;
      final pool = tilePools[shape.ar];
      if (pool == null || pool.isEmpty) continue;

      final region = analyzer.sampleRegion(
          x: col * cellW,
          y: row * cellH,
          width: shape.cols * cellW,
          height: shape.rows * cellH);

      final shapeSal = shape.cells > 1
          ? _avgCellSaliency(col, row, shape, cellSaliency)
          : sal;
      final m = selectBestTileMatch(MatchInput(
          region: region,
          tiles: pool,
          settings: settings,
          usageCounts: usageCounts,
          nearbyTiles: nearbyTiles,
          saliency: shapeSal,
          neighborAvgColor: neighborAvgColor,
          tilePoolSize: tilePoolSize,
          placementCount: placementCount,
          colorBias: colorBias));

      if (m.score < bestScore) {
        bestScore = m.score;
        bestShape = shape;
        bestRegion = region;
        bestTile = m.tile;
      }
    }

    if (bestTile != null && bestRegion != null) {
      _commitPlacement(col, row, bestShape, cellW, cellH, bestRegion, bestTile,
          bestScore, occupied, usageCounts, placements, grid);
      if (colorErrors != null) {
        _spreadColorError(
            colorErrors,
            col,
            row,
            bestShape,
            M,
            N,
            occupied,
            bestRegion.averageLabColor.L + (colorBias?.L ?? 0) - bestTile.averageLabColor.L,
            bestRegion.averageLabColor.a + (colorBias?.a ?? 0) - bestTile.averageLabColor.a,
            bestRegion.averageLabColor.b + (colorBias?.b ?? 0) - bestTile.averageLabColor.b);
      }
    }
  }
}

void _vogelAssign(List<MosaicPlacement> placements, List<TileDescriptor> tiles,
    MosaicSettings settings, Float64List placementSaliency) {
  if (placements.isEmpty || tiles.isEmpty) return;

  final n = placements.length;
  final K = math.min(80, tiles.length);

  final candidateLists = List<List<RegionCandidate>>.filled(n, const []);
  for (var i = 0; i < n; i++) {
    candidateLists[i] =
        getTopKCandidates(placements[i], tiles, settings, placementSaliency[i], K);
    if (candidateLists[i].isEmpty) return;
  }

  final regrets = Float64List(n);
  for (var i = 0; i < n; i++) {
    final c = candidateLists[i];
    regrets[i] = c.length >= 2 ? c[1].baseCost - c[0].baseCost : 0;
  }

  final order = List<int>.generate(n, (i) => i);
  _stableSort(order, (a, b) => regrets[b].compareTo(regrets[a]));

  final tilePoolSize = tiles.length;
  final usageCounts = <String, int>{};

  for (var oi = 0; oi < n; oi++) {
    final i = order[oi];
    final cands = candidateLists[i];
    final sal = placementSaliency[i];
    final salVarietyScale = 0.7 + sal * 0.6;
    final unusedCount = math.max(0, tilePoolSize - usageCounts.length);
    final expectedUsage = n / tilePoolSize;
    final varietyStrength = settings.reusePenalty > 0
        ? (settings.reusePenalty * settings.reusePenalty * 2 +
                settings.reusePenalty) *
            salVarietyScale
        : 0.0;

    var bestTile = cands[0].tile;
    var bestTotal = double.infinity;

    for (final cand in cands) {
      final tile = cand.tile;
      final baseCost = cand.baseCost;
      final baseId = getBaseTileId(tile.id);
      final usageCount = usageCounts[baseId] ?? 0;

      var varietyAdj = 0.0;
      if (varietyStrength > 0) {
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
        varietyAdj += math.log(1 + usageCount) * varietyStrength * 1.5;
      }

      final total = baseCost + varietyAdj;
      if (total < bestTotal) {
        bestTotal = total;
        bestTile = tile;
      }
    }

    placements[i].tileId = bestTile.id;
    placements[i].tileName = bestTile.name;
    final baseId = getBaseTileId(bestTile.id);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;
  }
}

void _fillUniformGrid(
    int M,
    int N,
    double cellW,
    double cellH,
    List<List<double>> cellSaliency,
    List<ResolvedTileEntry> resolved,
    ImageAnalyzer analyzer,
    MosaicSettings settings,
    List<MosaicPlacement> placements,
    SpatialGrid grid,
    int tilePoolSize,
    int placementCount) {
  final cells =
      <({int col, int row, double priority, double sal, RegionAnalysis region})>[];
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      final region = analyzer.sampleRegion(
          x: c * cellW, y: r * cellH, width: cellW, height: cellH);
      final sal = cellSaliency[r][c];
      cells.add((
        col: c,
        row: r,
        priority: region.detailScore * 0.5 + sal * 0.5,
        sal: sal,
        region: region
      ));
    }
  }
  _stableSort(cells, (a, b) => b.priority.compareTo(a.priority));

  final usageCounts = <String, int>{};
  final occupied =
      List.generate(N, (_) => List<bool>.filled(M, false), growable: false);
  final colorErrors = <String, LabColor>{};

  for (final cell in cells) {
    final col = cell.col, row = cell.row, sal = cell.sal, region = cell.region;
    final nearbyTiles = _collectNearbyTiles(
        col, row, cellW, cellH, placements, grid, settings.reusePenalty);
    final neighborAvgColor =
        _computeNeighborAvgColor(col, row, cellW, cellH, placements, grid);
    final colorBias = colorErrors[_cellKey(col, row)];

    final m = selectBestTileUniform(UniformMatchInput(
        region: region,
        resolved: resolved,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: sal,
        neighborAvgColor: neighborAvgColor,
        tilePoolSize: tilePoolSize,
        placementCount: placementCount,
        colorBias: colorBias));

    occupied[row][col] = true;
    final baseId = getBaseTileId(m.tile.id);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

    placements
        .add(region.toPlacement(placements.length, m.tile.id, m.tile.name, m.score));

    final cx = col * cellW + cellW / 2;
    final cy = row * cellH + cellH / 2;
    final gc = (cx / grid.cellSize).floor();
    final gr = (cy / grid.cellSize).floor();
    final key = gr * grid.cols + gc;
    (grid.buckets[key] ??= []).add(placements.length - 1);

    _spreadColorError(
        colorErrors,
        col,
        row,
        _shape1x1,
        M,
        N,
        occupied,
        region.averageLabColor.L + (colorBias?.L ?? 0) - m.tile.averageLabColor.L,
        region.averageLabColor.a + (colorBias?.a ?? 0) - m.tile.averageLabColor.a,
        region.averageLabColor.b + (colorBias?.b ?? 0) - m.tile.averageLabColor.b);
  }
}

Map<String, double> _collectNearbyTiles(int col, int row, double cellW,
    double cellH, List<MosaicPlacement> placements, SpatialGrid grid,
    [double reusePenalty = 0]) {
  final nearby = <String, double>{};
  final cx = (col + 0.5) * cellW;
  final cy = (row + 0.5) * cellH;
  final cellSize = math.max(cellW, cellH);
  final reach = cellSize * (3 + reusePenalty * 4);

  final candidates = _spatialQuery(grid, cx, cy, reach);
  for (var k = 0; k < candidates.length; k++) {
    final p = placements[candidates[k]];
    final nearestX = math.max(p.x, math.min(cx, p.x + p.width));
    final nearestY = math.max(p.y, math.min(cy, p.y + p.height));
    final edgeDist = math.sqrt(math.pow(nearestX - cx, 2).toDouble() +
        math.pow(nearestY - cy, 2).toDouble());
    final proximity = math.max(0, 1 - edgeDist / reach).toDouble();
    if (proximity <= 0) continue;

    final baseId = getBaseTileId(p.tileId);
    final prev = nearby[baseId] ?? 0;
    if (proximity > prev) nearby[baseId] = proximity;
  }

  return nearby;
}

LabColor? _computeNeighborAvgColor(int col, int row, double cellW, double cellH,
    List<MosaicPlacement> placements, SpatialGrid grid) {
  final cx = (col + 0.5) * cellW;
  final cy = (row + 0.5) * cellH;
  final cellSize = math.max(cellW, cellH);
  final reach = cellSize * 2;

  var wSum = 0.0, sL = 0.0, sA = 0.0, sB = 0.0;
  final candidates = _spatialQuery(grid, cx, cy, reach);
  for (var k = 0; k < candidates.length; k++) {
    final p = placements[candidates[k]];
    final nearestX = math.max(p.x, math.min(cx, p.x + p.width));
    final nearestY = math.max(p.y, math.min(cy, p.y + p.height));
    final dist = math.sqrt(math.pow(nearestX - cx, 2).toDouble() +
        math.pow(nearestY - cy, 2).toDouble());
    final prox = math.max(0, 1 - dist / reach).toDouble();
    if (prox <= 0) continue;
    sL += p.averageLabColor.L * prox;
    sA += p.averageLabColor.a * prox;
    sB += p.averageLabColor.b * prox;
    wSum += prox;
  }
  if (wSum < 0.01) return null;
  return LabColor(sL / wSum, sA / wSum, sB / wSum);
}

bool _shapeFits(
    int col, int row, CellShape shape, int M, int N, List<List<bool>> occupied) {
  if (col + shape.cols > M || row + shape.rows > N) return false;
  for (var dr = 0; dr < shape.rows; dr++) {
    for (var dc = 0; dc < shape.cols; dc++) {
      if (occupied[row + dr][col + dc]) return false;
    }
  }
  return true;
}

void _markOccupied(
    int col, int row, CellShape shape, List<List<bool>> occupied) {
  for (var dr = 0; dr < shape.rows; dr++) {
    for (var dc = 0; dc < shape.cols; dc++) {
      occupied[row + dr][col + dc] = true;
    }
  }
}

void _commitPlacement(
    int col,
    int row,
    CellShape shape,
    double cellW,
    double cellH,
    RegionAnalysis region,
    TileDescriptor tile,
    double score,
    List<List<bool>> occupied,
    Map<String, int> usageCounts,
    List<MosaicPlacement> placements,
    SpatialGrid grid) {
  _markOccupied(col, row, shape, occupied);

  final baseId = getBaseTileId(tile.id);
  usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

  final idx = placements.length;
  final px = col * cellW;
  final py = row * cellH;
  final pw = shape.cols * cellW;
  final ph = shape.rows * cellH;

  placements.add(MosaicPlacement(
    index: idx,
    x: px,
    y: py,
    width: pw,
    height: ph,
    averageColor: region.averageColor,
    averageLabColor: region.averageLabColor,
    detailScore: region.detailScore,
    subregionColors: region.subregionColors,
    subregionEdges: region.subregionEdges,
    contrastMap: region.contrastMap,
    luminanceBalance: region.luminanceBalance,
    colorVariance: region.colorVariance,
    edgeOrientation: region.edgeOrientation,
    tonalHistogram: region.tonalHistogram,
    subregionEdgeOrientations: region.subregionEdgeOrientations,
    tileId: tile.id,
    tileName: tile.name,
    score: score,
  ));

  if (shape.cells > 1) {
    final margin = math.min(cellW, cellH) * 0.3;
    _spatialInsert(grid, idx, px + margin, py + margin);
    _spatialInsert(grid, idx, px + pw - margin, py + margin);
    _spatialInsert(grid, idx, px + margin, py + ph - margin);
    _spatialInsert(grid, idx, px + pw - margin, py + ph - margin);
    _spatialInsert(grid, idx, px + pw / 2, py + ph / 2);
  } else {
    _spatialInsert(grid, idx, px + pw / 2, py + ph / 2);
  }
}

const double _coherenceWeight = 2.0;

double _scoreMosaicReconstruction(List<MosaicPlacement> placements,
    Map<String, TileDescriptor> tileMap, Float64List saliency,
    List<Set<int>> adjacency) {
  final n = placements.length;

  var perCellWeighted = 0.0;
  var perCellTotalW = 0.0;
  for (var i = 0; i < n; i++) {
    final p = placements[i];
    final tile = tileMap[p.tileId];
    if (tile == null) continue;
    final w = 0.2 + saliency[i] * 0.8;
    final err = (tile.subregionColors != null)
        ? subregionDistance(p.subregionColors, tile.subregionColors!)
        : labDistance(p.averageLabColor, tile.averageLabColor);
    perCellWeighted += err * w;
    perCellTotalW += w;
  }
  final perCellScore = perCellTotalW > 0 ? perCellWeighted / perCellTotalW : 0.0;

  var coherenceWeighted = 0.0;
  var coherenceTotalW = 0.0;
  for (var i = 0; i < n; i++) {
    final pi = placements[i];
    final tileI = tileMap[pi.tileId];
    if (tileI == null) continue;
    for (final j in adjacency[i]) {
      if (j <= i) continue;
      final pj = placements[j];
      final tileJ = tileMap[pj.tileId];
      if (tileJ == null) continue;
      final tileLumDiff = (tileI.averageLabColor.L - tileJ.averageLabColor.L) / 100;
      final regionLumDiff = (pi.averageLabColor.L - pj.averageLabColor.L) / 100;
      final err = math.pow(tileLumDiff - regionLumDiff, 2).toDouble();
      final w = (saliency[i] + saliency[j]) * 0.5;
      coherenceWeighted += err * w;
      coherenceTotalW += w;
    }
  }
  final coherenceScore =
      coherenceTotalW > 0 ? coherenceWeighted / coherenceTotalW : 0.0;

  return perCellScore + _coherenceWeight * coherenceScore;
}

Float64List _computePlacementSaliency(List<RegionAnalysis> regions,
    List<Set<int>> adjacency, double baseWidth, double baseHeight,
    List<FaceRect> faceRegions) {
  final n = regions.length;
  final sal = Float64List(n);
  final cx = baseWidth / 2;
  final cy = baseHeight / 2;
  final maxDist = math.sqrt(cx * cx + cy * cy);
  final hasFaces = faceRegions.isNotEmpty;

  for (var i = 0; i < n; i++) {
    final r = regions[i];
    final rcx = r.x + r.width / 2;
    final rcy = r.y + r.height / 2;
    final centerProximity = 1 -
        math.sqrt(math.pow(rcx - cx, 2).toDouble() +
                math.pow(rcy - cy, 2).toDouble()) /
            maxDist;

    var neighborContrast = 0.0;
    if (adjacency[i].isNotEmpty) {
      var contrastSum = 0.0;
      for (final ni in adjacency[i]) {
        contrastSum +=
            labDistance(r.averageLabColor, regions[ni].averageLabColor);
      }
      neighborContrast = contrastSum / adjacency[i].length;
    }

    if (hasFaces) {
      final fb = _regionFaceOverlap(r, faceRegions);
      sal[i] = r.detailScore * 0.20 +
          r.colorVariance * 0.10 +
          centerProximity * 0.10 +
          neighborContrast * 0.15 +
          fb * 0.45;
    } else {
      sal[i] = r.detailScore * 0.30 +
          r.colorVariance * 0.20 +
          centerProximity * 0.25 +
          neighborContrast * 0.25;
    }
  }

  var maxSal = 0.0;
  for (var i = 0; i < n; i++) {
    if (sal[i] > maxSal) maxSal = sal[i];
  }
  if (maxSal > 0) {
    for (var i = 0; i < n; i++) {
      sal[i] /= maxSal;
    }
  }

  return sal;
}

double _regionFaceOverlap(RegionAnalysis r, List<FaceRect> faces) {
  if (faces.isEmpty) return 0;
  final area = r.width * r.height;
  if (area <= 0) return 0;
  var best = 0.0;
  for (final f in faces) {
    final ox = math.max(
        0, math.min(r.x + r.width, f.x + f.width) - math.max(r.x, f.x));
    final oy = math.max(
        0, math.min(r.y + r.height, f.y + f.height) - math.max(r.y, f.y));
    best = math.max(best, (ox * oy) / area);
  }
  return best;
}

List<Set<int>> _buildAdjacencyMap(List<RegionAnalysis> regions) {
  final n = regions.length;
  final adj = List<Set<int>>.generate(n, (_) => <int>{});
  if (n < 2) return adj;

  const touch = 1;
  var maxDim = 0.0;
  var maxRight = 0.0;
  for (var i = 0; i < n; i++) {
    maxDim = math.max(maxDim, math.max(regions[i].width, regions[i].height));
    maxRight = math.max(maxRight, regions[i].x + regions[i].width);
  }

  final cs = math.max(1, maxDim).toDouble();
  final cols = (maxRight / cs).ceil() + 2;
  final buckets = <int, List<int>>{};

  for (var i = 0; i < n; i++) {
    final key = ((regions[i].y + regions[i].height / 2) / cs).floor() * cols +
        ((regions[i].x + regions[i].width / 2) / cs).floor();
    (buckets[key] ??= []).add(i);
  }

  for (var i = 0; i < n; i++) {
    final a = regions[i];
    final aR = a.x + a.width;
    final aB = a.y + a.height;
    final gc = ((a.x + a.width / 2) / cs).floor();
    final gr = ((a.y + a.height / 2) / cs).floor();

    for (var dr = -2; dr <= 2; dr++) {
      for (var dc = -2; dc <= 2; dc++) {
        final bucket = buckets[(gr + dr) * cols + (gc + dc)];
        if (bucket == null) continue;
        for (var k = 0; k < bucket.length; k++) {
          final j = bucket[k];
          if (j <= i) continue;
          final b = regions[j];
          if (a.x < b.x + b.width + touch &&
              aR + touch > b.x &&
              a.y < b.y + b.height + touch &&
              aB + touch > b.y) {
            adj[i].add(j);
            adj[j].add(i);
          }
        }
      }
    }
  }

  return adj;
}
