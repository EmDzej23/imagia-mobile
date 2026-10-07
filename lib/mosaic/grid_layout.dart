import 'dart:math' as math;
import 'dart:typed_data';

import 'analyze.dart';
import 'hexagon.dart';
import 'matching.dart';
import 'no_touch.dart';
import 'rhombille.dart';
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
  final indexed = List<MapEntry<int, T>>.generate(
    list.length,
    (i) => MapEntry(i, list[i]),
  );
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
  Map<double, List<TileDescriptor>> tilePools,
  double ar,
) {
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

/// Cell aspects the grid may adopt, chosen from the library by [dominantCellAspect].
///
/// 9:16 and 16:9 are in this list because a phone shoots them and the list used to stop
/// at 2:3 and 3:2.
///
/// With the +/-15% tolerance, a 9:16 photo (0.5625) agrees with NOTHING on the old list
/// — 2:3 is 17% away, just outside. So a library of tall phone photos reached consensus
/// on no candidate at all and `dominantCellAspect` fell through to its 1.0 default:
/// SQUARE cells, for a library with no square photo in it. Every 1x1 then centre-cropped
/// a tall photo to fit, and 1x1 is most of the mosaic.
///
/// Measured on a 55x9:16 + 2x3:2 library — a real reported one, read off its debug
/// output: cell aspect 1.01 -> 0.56, mean crop 37% -> 2%, worst crop 63% -> 25%.
///
/// The tolerance keeps these from stealing libraries that already worked: a 3:2 photo is
/// 17% from 16:9 and a 4:3 photo 29%, so neither counts toward the new candidates.
const List<double> _cellArCandidates = [
  9 / 16,
  2 / 3,
  3 / 4,
  1.0,
  4 / 3,
  3 / 2,
  16 / 9,
];

/// Fraction of the library that must agree on an aspect before the grid adopts it.
///
/// Deliberately LOW. Measured on a 60/40 landscape/portrait library — the ordinary
/// case — every non-square choice beats square:
///
///   square cells  mean crop 25.1%  worst 33%
///   3:2 cells     mean crop  1.7%  worst 11%
///   2:3 cells     mean crop  4.5%  worst  9%
///
/// So the threshold only needs to be high enough to catch a library with no dominant
/// aspect at all, where square is the honest compromise.
const double _cellArConsensus = 0.35;

/// Log-space band within which a photo counts as "agreeing" with a candidate aspect.
const double _cellArTolerance = 0.14;

/// Never offer a crop frame more extreme than 3:2 / 2:3 — no camera produces 1:2, and
/// a frame that shape slices a portrait down to a sliver.
const double _cropFrameMinAR = 2 / 3;
const double _cropFrameMaxAR = 3 / 2;

/// Widest shape the derived menu may contain. At 3:2 cells the 2x1 shape becomes 3:1,
/// which no photograph fills honestly. Measured: 1.8 drops worst-case crop 33% -> 26%
/// at no cost to colour, while 1.5 is too tight and kills the 3:2 shape outright.
const double _shapeArLimit = 1.8;

/// The aspect the GRID's cells take, chosen from the library.
///
/// Two stages, and both matter. CONSENSUS first, because it protects the minority
/// orientation: a 50/50 library must stay square even though "average crop" alone would
/// happily pick a side and ruin half the photos. Then, among candidates that clear
/// consensus, the one with the LOWEST MEAN CROP — not the highest count, because the
/// tolerance band is wide enough that 4:3 and 3:2 each count the other's photos, so
/// counting alone ties them.
///
/// Must match `dominantCellAspect` in foto-mozaik/lib/mosaic/grid-layout.ts.
double dominantCellAspect(List<TileDescriptor> tiles) {
  if (tiles.isEmpty) return 1.0;
  var best = 1.0;
  var bestMeanCrop = double.infinity;
  for (final cand in _cellArCandidates) {
    var within = 0;
    var cropSum = 0.0;
    for (final t in tiles) {
      if ((math.log(t.aspectRatio / cand)).abs() <= _cellArTolerance) within++;
      cropSum += _cropFraction(t.aspectRatio, cand);
    }
    if (within / tiles.length < _cellArConsensus) continue;
    final meanCrop = cropSum / tiles.length;
    if (meanCrop < bestMeanCrop) {
      bestMeanCrop = meanCrop;
      best = cand;
    }
  }
  return best;
}

/// Every shape aspect reachable from a cell of `cellAR`.
///
/// (cols, rows) pairs rather than pre-divided ratios: the aspect must be computed with
/// the exact same expression `_shapesForCellAR` uses, or the two disagree in the last
/// bits and every pool lookup misses.
List<double> _poolARsForCellAR(double cellAR) {
  const shapes = [
    [1, 1],
    [1, 2],
    [2, 1],
    [2, 3],
    [3, 2],
    [3, 3],
    [2, 2],
    [2, 4],
    [4, 2],
  ];
  final out = <double>{};
  for (final sh in shapes) {
    out.add((cellAR * sh[0]) / sh[1]);
  }
  return out.toList();
}

/// The crop frame a given photo should be framed against, in a grid of `cellAR` cells.
///
/// Must match `cellAspectForTile` in foto-mozaik/lib/mosaic/grid-layout.ts.
double cellAspectForTile(double tileAR, double cellAR) {
  var best = cellAR;
  var bestD = double.infinity;
  for (final ar in _poolARsForCellAR(cellAR)) {
    if (!_orientationCompatible(tileAR, ar)) continue;
    final d = (math.log(tileAR / ar)).abs();
    if (d < bestD) {
      bestD = d;
      best = ar;
    }
  }
  return math.min(math.max(best, _cropFrameMinAR), _cropFrameMaxAR);
}

/// Derive the shape menu for a non-square cell, dropping shapes no photo can fill.
///
/// A non-square cell stretches the menu: at 3:2 cells the 2x1 shape becomes 3:1. The
/// tile pools would still populate those through the crop fallback — a deliberate
/// escape hatch for a library with nothing better — but here it would reintroduce the
/// exact 33% crop this exists to remove. The 1x1 fill is the true last resort and is
/// never pruned.
List<CellShape> _shapesForCellAR(
  List<CellShape> shapes,
  double cellAR,
  List<TileDescriptor> tiles,
) {
  final derived = cellAR == 1.0
      ? shapes
      : shapes
            .map(
              (sh) => CellShape(
                sh.cols,
                sh.rows,
                sh.cells,
                (cellAR * sh.cols) / sh.rows,
              ),
            )
            .toList();
  return derived
      .where(
        (sh) =>
            sh.cells == 1 ||
            (tiles.any(
                  (t) =>
                      _orientationCompatible(t.aspectRatio, sh.ar) &&
                      _cropFraction(t.aspectRatio, sh.ar) < _maxCrop,
                ) &&
                sh.ar >= 1 / _shapeArLimit &&
                sh.ar <= _shapeArLimit),
      )
      .toList();
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

void _addCellError(
  Map<String, LabColor> errors,
  int col,
  int row,
  double dL,
  double da,
  double db,
  double strength,
) {
  final key = _cellKey(col, row);
  final prev = errors[key];
  errors[key] = LabColor(
    math.max(
      -_maxColorError,
      math.min(_maxColorError, (prev?.L ?? 0) + dL * strength),
    ),
    math.max(
      -_maxColorError,
      math.min(_maxColorError, (prev?.a ?? 0) + da * strength),
    ),
    math.max(
      -_maxColorError,
      math.min(_maxColorError, (prev?.b ?? 0) + db * strength),
    ),
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
  double residualB,
) {
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
    _addCellError(
      errors,
      nb[0],
      nb[1],
      residualL,
      residualA,
      residualB,
      perNeighbor,
    );
  }
}

// ── Constants ───────────────────────────────────────────────────────────────

const int _maxPlacements = 6500;
const int _optimalAssignmentMaxRegions = 4000;
const int _lowCountSeedAttempts = 3;

/// Average cells one photo occupies in `original` mode.
///
/// MEASURED on the web bench, not assumed: with the fill-first layout the mix is
/// dominated by 1x1 cells, so a photo covers ~1.3 cells, not the 3.0 the old
/// shapes-first layout produced. A wrong value here is invisible in the mosaic and
/// only shows up as the density slider disagreeing with the result.
///
/// Must match ORIGINAL_CELLS_PER_TILE in foto-mozaik/lib/mosaic/density.ts.
const double _originalCellsPerTile = 1.3;
const double _blocksCellsPerTile = 5.0;
const int _maxCellsOriginal = 45000;

/// Below this share of the requested cell count, `original`/`blocks` re-grid once.
///
/// The density control promises a number of cells, and the density→grid mapping assumes
/// a fixed merge rate (`_originalCellsPerTile`). That rate is not fixed: it is set by how
/// many multi-cell shapes the library can fill, and a library whose aspects spread evenly
/// enough that no orientation reaches the cell-aspect consensus gets SQUARE cells, where
/// almost the whole shape menu survives pruning. Measured on the web bench asking for
/// 1600 cells: normal libraries delivered 1234–1534, a library of 16:9 + 9:16 + 4:3 + 3:4
/// delivered 812.
///
/// Half the requested detail means every photo covers twice the intended area, and a
/// photo spread over a large region rarely matches what is under it — which is what
/// "some tiles look out of place" is. Only `original` shows it; the uniform modes place
/// one tile per cell and always land on target.
///
/// Measured delivered/estimated: 0.85, 0.86, 0.87 for the healthy libraries, 0.70 for a
/// 60/40 land/port mix, 0.47 for the reported one. 0.6 sits in the gap, so only the
/// genuinely-short case re-grids. A threshold of 0.7 caught the 60/40 mix by a hair and
/// moved it from 1234 cells to 1781 — not a fix, a second regression.
const double _regridShortfall = 0.6;

/// Cap on how much finer the second attempt may go. A bound, not a target: without a
/// ceiling a pathological library could ask for a grid several times denser and pay for
/// it in build time on a phone. 1.6x covers the measured 812→1600 case (needs 1.40x).
const double _maxRegridScale = 1.6;

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
  // Variety is pinned in sanitizeSettings — see fixedReusePenalty. The adaptive
  // per-library value that used to be derived here is gone: it existed to soften a
  // neighbour-duplicate penalty strong enough to ban local reuse, and once that was
  // corrected a flat 0.01 measured better at every library size.

  final mode = settings.mosaicMode;
  final uniformMode = mode != 'original' && mode != 'blocks';

  // original / blocks: the CELL takes the library's dominant photo aspect, so the 1x1
  // last-resort fill — which covers most of a low-detail image — no longer centre-crops
  // a third off every landscape photo to force it into a square. Square when the
  // library is mixed, which is the old behaviour.
  final cellAR = uniformMode ? 1.0 : dominantCellAspect(tiles);

  _GridDims gridDims;
  if (mode == 'square') {
    gridDims = _computeSquareGrid(baseWidth, baseHeight, settings.density);
  } else if (mode == 'landscape') {
    gridDims = _computeFixedARGrid(
      baseWidth,
      baseHeight,
      settings.density,
      3 / 2,
    );
  } else if (mode == 'portrait') {
    gridDims = _computeFixedARGrid(
      baseWidth,
      baseHeight,
      settings.density,
      2 / 3,
    );
  } else if (cellAR != 1.0) {
    gridDims = _computeFixedARGrid(
      baseWidth,
      baseHeight,
      settings.density,
      cellAR,
    );
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

  // The REAL cell aspect after the grid rounded M/N to whole cells — shapes and pools
  // must both key off this, not off the requested value, or a shape's declared aspect
  // and the rectangle actually drawn drift apart.
  var actualCellAR = cellW / cellH;
  // Uniform modes look their pool up by the mode's EXACT aspect (3/2, 2/3, 1). Keying
  // off the rounded actualCellAR would put 1.4983 in the map where 1.5 is looked up — a
  // miss, which falls through to the whole library and silently drops landscape/portrait
  // mode's orientation restriction.
  final poolCellAR = uniformMode
      ? (mode == 'landscape'
            ? 3 / 2
            : mode == 'portrait'
            ? 2 / 3
            : 1.0)
      : actualCellAR;
  var tilePools = _buildTilePools(tiles, poolCellAR);
  final placements = <MosaicPlacement>[];
  var grid = _createSpatialGrid(math.max(cellW, cellH), baseWidth + cellW);
  var cellSaliency = _computeCellSaliency(
    M,
    N,
    cellW,
    cellH,
    baseWidth,
    baseHeight,
    faceRegions,
  );

  final totalGridCells = M * N;
  final cellsPerTile = mode == 'blocks'
      ? _blocksCellsPerTile
      : _originalCellsPerTile;
  final estimatedPlacements = uniformMode
      ? totalGridCells
      : jsRound(totalGridCells / cellsPerTile).toInt();

  // The tiles this layout is actually allowed to draw from — landscape/portrait grids
  // exclude cross-orientation photos outright, so those can never be "missing".
  // Everything else can draw on the whole library. Used by the coverage pass below.
  var eligibleTiles = tiles;
  if (mode == 'rhombille') {
    // Rhombi are not an MxN lattice, so this bypasses the grid machinery entirely and
    // matches over the cells directly. Everything downstream — SA, palette balance,
    // coverage — is untouched: a placement is still a region plus a tile id.
    _fillRhombilleCells(
      baseWidth,
      baseHeight,
      settings,
      tiles,
      analyzer,
      placements,
      grid,
      faceRegions,
      estimatedPlacements,
    );
  } else if (mode == 'hexagon') {
    // A honeycomb is not an MxN lattice, so this bypasses the grid machinery and
    // matches over its own cells. Everything downstream — SA, palette balance,
    // coverage, the no-touch pass — is untouched: a placement is still a region plus a
    // tile id.
    _fillHexCells(
      baseWidth,
      baseHeight,
      settings,
      tiles,
      analyzer,
      placements,
      grid,
      faceRegions,
      estimatedPlacements,
    );
  } else if (uniformMode) {
    final cellAR = mode == 'landscape'
        ? 3 / 2
        : mode == 'portrait'
        ? 2 / 3
        : 1.0;
    // `??` is not enough: _buildTilePools returns an EMPTY list when no photo matches
    // the orientation (and deliberately empties near-square pools that are too small),
    // and an empty list is not null. A library of only landscape photos therefore handed
    // `portrait` a pool of zero tiles, which threw out of selectBestTileUniform and
    // failed the whole build. Falling back to the full library centre-crops instead,
    // which is what `square` already does and beats producing no mosaic at all.
    final orientationPool = (mode == 'landscape' || mode == 'portrait')
        ? tilePools[cellAR]
        : null;
    final pool = (orientationPool != null && orientationPool.isNotEmpty)
        ? orientationPool
        : tiles;
    eligibleTiles = pool;
    // Square mode anchors portrait tiles to the TOP when drawing, so the scorer has to
    // weight the top band — see computeCropWeights.
    final resolved = preResolveTiles(
      pool,
      cellAR,
      mode == 'square',
      settings.tileCrops,
    );
    _fillUniformGrid(
      M,
      N,
      cellW,
      cellH,
      cellSaliency,
      resolved,
      analyzer,
      settings,
      placements,
      grid,
      pool.length,
      estimatedPlacements,
    );
  } else {
    // Two attempts at most: the requested grid, then — only if the layout merged away
    // far more cells than the density model assumes — one finer grid. See
    // [_regridShortfall] for why a single fixed merge rate cannot hold.
    for (var attempt = 0; ; attempt++) {
      final occupied = List.generate(
        N,
        (_) => List<bool>.filled(M, false),
        growable: false,
      );
      final usageCounts = <String, int>{};
      final baselinePool = tilePools[_anyOrientationAR] ?? tiles;
      final baselines = _computeBaselines(
        M,
        N,
        cellW,
        cellH,
        analyzer,
        baselinePool,
        settings,
      );

      final isBlocks = mode == 'blocks';
      final colorErrors = <String, LabColor>{};

      // GEOMETRY IS DECIDED WITH THE REUSE CAP OFF.
      //
      // Cell shapes here are chosen by comparing scores: is one photo across these four
      // cells better than four photos in them, is a 2x1 better than two 1x1s. A cap makes
      // those scores incomparable, and not evenly — 1x1 draws from the whole library while
      // every multi-cell shape draws from a narrow orientation pool, so the cap starves
      // the big shapes first and 1x1 wins every comparison it is in. A setting about how
      // often a photo REPEATS was silently deciding how big the cells are: on the web
      // bench's mixed-200 library it took 782 cells at 1.61 cells/tile to 966 at 1.30 — a
      // mixed-block mosaic rebuilt as a field of small squares.
      //
      // Gating each comparison individually is not enough: the tiles this pass commits
      // feed the next cell's neighbour context, so a capped assignment still drags the
      // geometry with it. The cut has to be above the whole layout — shapes come out
      // identical with the cap on or off, and the cap binds afterwards in the passes that
      // only REASSIGN tiles (Vogel, SA swaps, palette balance, coverage, no-touch), none
      // of which can move a cell.
      final layoutSettings = settings.maxTileUses != 0
          ? settings.copyWith(maxTileUses: 0)
          : settings;
      // `original` lays the picture out fill-first (see `_fillFirstLayout`). `blocks`
      // keeps the shapes-first path: its whole premise is that every cell is covered by a
      // block shape, and fill-first would leave it a 1x1 mosaic.
      if (!isBlocks) {
        _fillFirstLayout(
          M,
          N,
          cellW,
          cellH,
          occupied,
          cellSaliency,
          tilePools,
          analyzer,
          layoutSettings,
          usageCounts,
          placements,
          grid,
          tiles.length,
          estimatedPlacements,
          _shapesForCellAR(_multiCellShapes, actualCellAR, tiles),
          _shapesForCellAR(_fillShapes, actualCellAR, tiles),
          colorErrors,
          actualCellAR,
        );
      } else {
        // Shape aspects are cols/rows x the CELL aspect, so the menu is derived per build
        // rather than taken from the module constants (which assume square cells).
        _placeMultiCellShapes(
          M,
          N,
          cellW,
          cellH,
          occupied,
          baselines,
          cellSaliency,
          tilePools,
          analyzer,
          layoutSettings,
          usageCounts,
          placements,
          grid,
          tiles.length,
          estimatedPlacements,
          _shapesForCellAR(_blocksShapes, actualCellAR, tiles),
          colorErrors,
        );

        _fillRemainingCells(
          M,
          N,
          cellW,
          cellH,
          occupied,
          baselines,
          cellSaliency,
          tilePools,
          analyzer,
          layoutSettings,
          usageCounts,
          placements,
          grid,
          tiles.length,
          estimatedPlacements,
          _shapesForCellAR(_blocksFillShapes, actualCellAR, tiles),
          // In blocks mode raise the saliency guard so 1x1 is used only when no block
          // shape fits, not whenever a cell happens to be salient.
          0.95,
          colorErrors,
        );
      }

      if (isMinimumDetailOriginalMode(settings)) {
        // Cap-free like the rest of the geometry: this pass MERGES cells, so under a
        // cap it is one more place where a setting about repeats decides cell size.
        _refineShapesByMerging(
          placements,
          cellW,
          cellH,
          tilePools,
          analyzer,
          layoutSettings,
          usageCounts,
          tiles.length,
          estimatedPlacements,
        );
      }

      // Did the density deliver? `estimatedPlacements` is fixed at the FIRST grid, so the
      // target does not chase the grid that is being adjusted to meet it.
      final delivered = placements.length;
      if (attempt == 0 &&
          delivered > 0 &&
          delivered < estimatedPlacements * _regridShortfall) {
        final scale = math.min(
          _maxRegridScale,
          math.sqrt(estimatedPlacements / delivered),
        );
        M = math.max(4, jsRound(M * scale).toInt());
        N = math.max(4, jsRound(N * scale).toInt());
        if (M * N > _maxCellsOriginal) {
          final back = math.sqrt(_maxCellsOriginal / (M * N));
          M = math.max(4, jsRound(M * back).toInt());
          N = math.max(4, jsRound(N * back).toInt());
        }
        cellW = baseWidth / M;
        cellH = baseHeight / N;
        // Everything keyed off the cell must be rebuilt, not reused: pools are keyed by
        // the cell aspect, the spatial grid by the cell size, saliency by MxN. Carrying
        // any of them over would leave the second attempt matching against the first
        // attempt's geometry.
        actualCellAR = cellW / cellH;
        tilePools = _buildTilePools(tiles, actualCellAR);
        grid = _createSpatialGrid(math.max(cellW, cellH), baseWidth + cellW);
        cellSaliency = _computeCellSaliency(
          M,
          N,
          cellW,
          cellH,
          baseWidth,
          baseHeight,
          faceRegions,
        );
        placements.clear();
        continue;
      }
      break;
    }
  }

  final tileMap = {for (final t in tiles) t.id: t};

  // Hexagons need their own neighbour rule. Their stored rect is the SAMPLE window —
  // 59% of the drawn cell — so two neighbours' rects never touch, and the rect test
  // returns zero neighbours for every cell. That silently disables SA's coherence term,
  // the neighbour-contrast part of saliency, and the no-touch gate. Widening the slack
  // does not fix it either: the rect test is separable, so the slack that finally
  // reaches the left/right neighbour also reaches a second-ring cell.
  final adjacency = mode == 'hexagon'
      ? buildHexAdjacency(placements)
      : _buildAdjacencyMap(placements);
  final saliency = _computePlacementSaliency(
    placements,
    adjacency,
    baseWidth,
    baseHeight,
    faceRegions,
  );

  // Vogel + best-of-N seeded SA path is gated purely on region count. The SA iteration
  // BUDGET is separate and admin-overridable (settings.saBudgetFactor) so it can be A/B'd
  // without also toggling Vogel on/off.
  //
  // Vogel is for the MULTI-CELL modes only. Its regret heuristic — assign the most
  // constrained region first — needs regions that differ in how constrained they are,
  // which is what varied cell shapes and per-shape tile pools give `original`/`blocks`.
  // A uniform grid has none of that structure: every cell is the same shape drawing on
  // the same pool, so the ordering buys nothing, while the greedy assignment it discards
  // was neighbour-AWARE (proximity penalty + neighbour average colour) and Vogel's is
  // not. Vogel scores candidates with no context penalties at all, so it happily places
  // a photo beside itself and leaves SA to undo it.
  //
  // Measured on web over 4 library aspect mixes at matched cell counts, mean per-cell
  // Lab error, Vogel on → off:
  //   square   0.094→0.088  0.104→0.094  0.092→0.088  0.089→0.086
  //   hexagon  0.092→0.081  0.105→0.086  0.100→0.088  0.094→0.087
  // and 3-4x FASTER, because building the per-cell candidate lists costs more than the
  // annealing it replaces. The win holds at EVERY budget (square scored 0.089/0.088/
  // 0.087 at 0.25/0.5/1.0 vs Vogel's 0.094), which matters here: this device anneals at
  // 0.25, so the quality gain arrives without spending a single extra iteration.
  //
  // `original`/`blocks` keep Vogel — their FACE error gets worse without it.
  // `rhombille` is deliberately excluded: it measured neutral, so there is no evidence
  // to justify changing how that mode looks.
  final modeSkipsVogel =
      mode == 'square' ||
      mode == 'landscape' ||
      mode == 'portrait' ||
      mode == 'hexagon';
  // Size and mode are kept apart on purpose, so dropping Vogel for a mode does not
  // silently also quadruple this device's annealing — the budget below keys off SIZE
  // only and is unchanged for every mode.
  final withinOptimalSize =
      placements.isNotEmpty &&
      placements.length <= _optimalAssignmentMaxRegions;
  final isOptimalPath = withinOptimalSize && !modeSkipsVogel;
  // Measured on web: 0.5 lifts raw composition SSIM over the old 0.25 with acceptable
  // cost on desktop. Mobile stays 0.25 (SA is main-thread + its iteration cap is already
  // lower, so doubling it there would hurt build time on low-end phones).
  final defaultSaBudget = withinOptimalSize ? (isMobile ? 0.25 : 0.5) : 1.0;
  final saBudgetFactor = settings.saBudgetFactor ?? defaultSaBudget;
  if (isOptimalPath) {
    try {
      _vogelAssign(placements, tiles, settings, saliency);
    } catch (_) {
      // Fall back to greedy result.
    }

    final n = placements.length;
    final vogelTileIds = List<String>.generate(n, (i) => placements[i].tileId);
    final vogelTileNames = List<String>.generate(
      n,
      (i) => placements[i].tileName,
    );

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

      optimizePlacementSwaps(
        placements,
        tileMap,
        settings,
        adjacency: adjacency,
        saliency: saliency,
        budgetFactor: saBudgetFactor,
        seedOffset: attempt,
        isMobile: isMobile,
      );
      balanceGlobalPalette(
        placements,
        tileMap,
        settings,
        adjacency: adjacency,
        saliency: saliency,
      );

      final score = _scoreMosaicReconstruction(
        placements,
        tileMap,
        saliency,
        adjacency,
      );
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
    optimizePlacementSwaps(
      placements,
      tileMap,
      settings,
      adjacency: adjacency,
      saliency: saliency,
      budgetFactor: saBudgetFactor,
      isMobile: isMobile,
    );
    balanceGlobalPalette(
      placements,
      tileMap,
      settings,
      adjacency: adjacency,
      saliency: saliency,
    );
  }

  // Every tile in the library appears at least once. Runs last so nothing can evict
  // what it places; each hole is filled from a cell whose tile is used elsewhere, so
  // it can never open a new one. A no-op when the library is already fully used.
  ensureTileCoverage(
    placements,
    eligibleTiles,
    tileMap,
    settings,
    saliency: saliency,
  );

  // no-touch experiment: LAST, so it cannot be undone by a later pass — and after
  // coverage specifically, because coverage places rare photos wherever it can and is
  // the one pass that can reintroduce a twin. It only ever swaps two cells' tiles, so
  // the coverage guarantee it just established survives intact.
  if (strictNoTouchingTwins) {
    enforceNoTouchingTwins(
      placements,
      tileMap,
      adjacency,
      saliency,
      resolveMaxTileUses(settings.maxTileUses, tiles.length, placements.length),
    );
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
  double baseWidth,
  double baseHeight,
  double density,
) {
  final shorter = math.min(baseWidth, baseHeight);
  final cellsOnShort = math.max(4, jsRound(density / 4).toInt());
  final cellSize = shorter / cellsOnShort;
  final M = math.max(1, jsRound(baseWidth / cellSize).toInt());
  final N = math.max(1, jsRound(baseHeight / cellSize).toInt());
  return _GridDims(M, N, baseWidth / M, baseHeight / N);
}

_GridDims _computeFixedARGrid(
  double baseWidth,
  double baseHeight,
  double density,
  double cellAR,
) {
  final cellsOnShort = math.max(4, jsRound(density / 4).toInt());
  final shorter = math.min(baseWidth, baseHeight);
  final targetArea = math.pow(shorter / cellsOnShort, 2).toDouble();
  final cellH = math.sqrt(targetArea / cellAR);
  final cellW = cellH * cellAR;
  final M = math.max(1, jsRound(baseWidth / cellW).toInt());
  final N = math.max(1, jsRound(baseHeight / cellH).toInt());
  return _GridDims(M, N, baseWidth / M, baseHeight / N);
}

/// Pools are a pure function of (tiles, cellAR) — the cell aspect changes which tiles
/// are even eligible for a given shape — so the cache is keyed by both.
final Expando<Map<double, Map<double, List<TileDescriptor>>>> _tilePoolsCache =
    Expando();

/// Pool key for "any orientation": the 1x1 fill, which may draw on the whole library.
const double _anyOrientationAR = 0;

/// Minimum genuinely-square tiles before multi-cell SQUARE shapes are offered at all.
const int _minSquareShapePool = 3;

Map<double, List<TileDescriptor>> _buildTilePools(
  List<TileDescriptor> tiles,
  double cellAR,
) {
  var byCellAR = _tilePoolsCache[tiles];
  if (byCellAR == null) {
    byCellAR = <double, Map<double, List<TileDescriptor>>>{};
    _tilePoolsCache[tiles] = byCellAR;
  }
  final cached = byCellAR[cellAR];
  if (cached != null) return cached;

  final pools = <double, List<TileDescriptor>>{};
  final uniqueARs = _poolARsForCellAR(cellAR);

  for (final ar in uniqueARs) {
    var pool = tiles
        .where(
          (t) =>
              _orientationCompatible(t.aspectRatio, ar) &&
              _cropFraction(t.aspectRatio, ar) < _maxCrop,
        )
        .toList();
    if (pool.length < 3) {
      pool = tiles
          .where(
            (t) =>
                _orientationCompatible(t.aspectRatio, ar) &&
                _cropFraction(t.aspectRatio, ar) < _maxCropFallback,
          )
          .toList();
    }
    pools[ar] = pool;
  }

  // A square shape is only worth building if the library has enough genuinely
  // square-ish photos to fill several without obvious repetition — and once a square
  // cell exists it is locked to that pool, so SA cannot escape a 2-tile pool. Below the
  // floor, drop square shapes entirely and let 3x2 / 2x3 / 2x1 / 1x2 take the frame.
  // "Square shape" means the shape whose aspect is ~1, which is only the 1x1/2x2/3x3
  // family when the CELL is square; with 3:2 cells the square shape is 2x3.
  for (final ar in pools.keys.toList()) {
    if ((math.log(ar)).abs() > _cellArTolerance) continue;
    final pool = pools[ar]!;
    if (pool.isNotEmpty && pool.length < _minSquareShapePool) pools[ar] = [];
  }

  // The 1x1 fill is the last resort — it must always have tiles, and centre-cropping an
  // arbitrary photo into one small square cell is normal mosaic behaviour. Multi-cell
  // SQUARE shapes get no such escape hatch: they render large, so a 25%+ crop is
  // glaring, and letting them borrow the whole library made them outrank the
  // landscape/portrait shapes purely on pool size.
  pools[_anyOrientationAR] = tiles;

  byCellAR[cellAR] = pools;
  return pools;
}

// scoring-pool.ts sync equivalents (the worker output is bit-identical).
Float64List _scoreRegionsSync(
  List<RegionAnalysis> regions,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
) {
  final out = Float64List(regions.length);
  final emptyUsage = <String, int>{};
  for (var i = 0; i < regions.length; i++) {
    out[i] = selectBestTileMatch(
      MatchInput(
        region: regions[i],
        tiles: tiles,
        settings: settings,
        usageCounts: emptyUsage,
      ),
    ).score;
  }
  return out;
}

Float64List _scoreMultiPoolRegionsSync(
  List<RegionAnalysis> regions,
  Float32List saliencies,
  List<int> poolIndex,
  List<List<TileDescriptor>> pools,
  MosaicSettings settings,
) {
  final out = Float64List(regions.length);
  final emptyUsage = <String, int>{};
  for (var i = 0; i < regions.length; i++) {
    out[i] = selectBestTileMatch(
      MatchInput(
        region: regions[i],
        tiles: pools[poolIndex[i]],
        settings: settings,
        usageCounts: emptyUsage,
        saliency: saliencies[i],
      ),
    ).score;
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
  MosaicSettings settings,
) {
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
    growable: false,
  );
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      regions[r * M + c] = analyzer.sampleRegion(
        x: c * cellW,
        y: r * cellH,
        width: cellW,
        height: cellH,
      );
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

List<List<double>> _computeCellSaliency(
  int M,
  int N,
  double cellW,
  double cellH,
  double baseWidth,
  double baseHeight,
  List<FaceRect> faceRegions,
) {
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
      final centerProximity =
          1 -
          math.sqrt(
                math.pow(rcx - cx, 2).toDouble() +
                    math.pow(rcy - cy, 2).toDouble(),
              ) /
              maxDist;

      var faceOverlap = 0.0;
      if (hasFaces) {
        final cellArea = cellW * cellH;
        for (final f in faceRegions) {
          final ox = math.max(
            0,
            math.min(c * cellW + cellW, f.x + f.width) -
                math.max(c * cellW, f.x),
          );
          final oy = math.max(
            0,
            math.min(r * cellH + cellH, f.y + f.height) -
                math.max(r * cellH, f.y),
          );
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
  int col,
  int row,
  CellShape shape,
  List<List<double>> cellSaliency,
) {
  var sum = 0.0;
  for (var dr = 0; dr < shape.rows; dr++) {
    for (var dc = 0; dc < shape.cols; dc++) {
      sum += cellSaliency[row + dr][col + dc];
    }
  }
  return sum / shape.cells;
}

class _ShapeCandidate {
  _ShapeCandidate(
    this.col,
    this.row,
    this.shape,
    this.totalImprovement,
    this.region,
    this.saliency,
  );
  int col;
  int row;
  CellShape shape;
  double totalImprovement;
  RegionAnalysis region;
  double saliency;
}

/// Saliency at a point — face rects score 1, everything else 0. Mirrors
/// `_computeCellSaliency` without needing a rectangular lattice.
double _saliencyAtPoint(
  double x,
  double y,
  double baseW,
  double baseH,
  List<FaceRect> faceRegions,
) {
  if (faceRegions.isEmpty) return 0;
  for (final f in faceRegions) {
    if (x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height) {
      return 1;
    }
  }
  return 0;
}

/// Nearby-tile proximities around an arbitrary POINT, for layouts with no MxN lattice.
Map<String, double> _collectNearbyTilesAt(
  double cx,
  double cy,
  double cellSize,
  List<MosaicPlacement> placements,
  SpatialGrid grid, [
  double reusePenalty = 0,
]) {
  final nearby = <String, double>{};
  // Radius over which the duplicate penalty applies. Tightened from 3 cells: it is
  // meant to stop a photo clustering ON TOP of itself, not to keep it out of a whole
  // region — see _neighborDuplicatePenaltyBase.
  final reach = cellSize * (1.6 + reusePenalty * 4);
  final candidates = _spatialQuery(grid, cx, cy, reach);
  for (var k = 0; k < candidates.length; k++) {
    final p = placements[candidates[k]];
    final d = math.sqrt(
      math.pow(p.x + p.width / 2 - cx, 2) +
          math.pow(p.y + p.height / 2 - cy, 2),
    );
    if (d > reach) continue;
    final id = getBaseTileId(p.tileId);
    final w = 1 - d / reach;
    final prev = nearby[id];
    if (prev == null || w > prev) nearby[id] = w;
  }
  return nearby;
}

/// Match one tile into every rhombus of a rhombille tiling.
///
/// Deliberately close to the uniform filler: cells are scored by detail and saliency,
/// sorted so the busiest are matched first (they get first pick of the library), then
/// committed one at a time with the usual reuse/neighbour pressure. The only real
/// difference is that a cell's SHAPE and its SAMPLE RECT are different objects — the
/// scorer gets a square, the renderer gets the parallelogram.
///
/// Must match `fillRhombilleCells` in foto-mozaik/lib/mosaic/grid-layout.ts.
void _fillRhombilleCells(
  double baseWidth,
  double baseHeight,
  MosaicSettings settings,
  List<TileDescriptor> tiles,
  ImageAnalyzer analyzer,
  List<MosaicPlacement> placements,
  SpatialGrid grid,
  List<FaceRect> faceRegions,
  int placementCount,
) {
  final cellsOnShort = math.max(3, jsRound(settings.density / 6).toInt());
  final cells = buildRhombilleCells(baseWidth, baseHeight, cellsOnShort);
  if (cells.isEmpty) return;

  // The sample square sits inside the rhombus: a 60-degree rhombus of edge s has an
  // inscribed width of s*(sqrt(3)/2), and 0.62*s stays clear of the acute corners while
  // still covering most of the area the photo will occupy.
  final side = rhombEdge(cells[0]) * 0.62;

  final scored =
      <
        ({RhombCell cell, RegionAnalysis region, double sal, double priority})
      >[];
  for (final cell in cells) {
    final rect = sampleRect(cell, side);
    // Clamp into the image — edge rhombi hang off the canvas by design.
    final x = math.max(0.0, math.min(baseWidth - 1, rect.x));
    final y = math.max(0.0, math.min(baseHeight - 1, rect.y));
    final w = math.max(1.0, math.min(baseWidth - x, rect.width));
    final h = math.max(1.0, math.min(baseHeight - y, rect.height));
    final region = analyzer.sampleRegion(x: x, y: y, width: w, height: h);
    final sal = _saliencyAtPoint(
      cell.cx,
      cell.cy,
      baseWidth,
      baseHeight,
      faceRegions,
    );
    scored.add((
      cell: cell,
      region: region,
      sal: sal,
      priority: region.detailScore * 0.5 + sal * 0.5,
    ));
  }
  _stableSort(scored, (a, b) => b.priority.compareTo(a.priority));

  final usageCounts = <String, int>{};
  for (final entry in scored) {
    final cell = entry.cell;
    final nearbyTiles = _collectNearbyTilesAt(
      cell.cx,
      cell.cy,
      side,
      placements,
      grid,
      settings.reusePenalty,
    );
    final match = selectBestTileMatch(
      MatchInput(
        region: entry.region,
        tiles: tiles,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: entry.sal,
        tilePoolSize: tiles.length,
        placementCount: placementCount,
      ),
    );
    final baseId = getBaseTileId(match.tile.id);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

    final idx = placements.length;
    final placement = entry.region.toPlacement(
      idx,
      match.tile.id,
      match.tile.name,
      match.score,
    );
    placement.quad = cell.quad;
    placement.face = cell.face;
    placements.add(placement);

    final gc = (cell.cx / grid.cellSize).floor();
    final gr = (cell.cy / grid.cellSize).floor();
    (grid.buckets[gr * grid.cols + gc] ??= <int>[]).add(idx);
  }
}

/// Match one tile into every hexagon of a honeycomb tiling.
///
/// Deliberately parallel to the uniform-grid filler: cells are scored by detail and
/// saliency, the busiest are matched first so they get first pick of the library, and
/// each is committed with the usual reuse/neighbour pressure.
///
/// The one thing to be careful about is the difference between the rect the ANALYSER is
/// asked about and the rect stored on the placement. Edge hexagons hang off the canvas
/// by design — that is what fills the border instead of leaving a ragged honeycomb edge
/// — so the analyser has to be given a clamped rect or it would sample outside the
/// image. The placement must keep the TRUE rect, because for this mode that rect is the
/// only record of where the hexagon is: `hexFromRect` reconstructs the six vertices
/// from it at draw time. Storing the clamped rect would shrink every edge hexagon and
/// open a gap around the entire border.
///
/// Must match `fillHexCells` in foto-mozaik/lib/mosaic/grid-layout.ts.
void _fillHexCells(
  double baseWidth,
  double baseHeight,
  MosaicSettings settings,
  List<TileDescriptor> tiles,
  ImageAnalyzer analyzer,
  List<MosaicPlacement> placements,
  SpatialGrid grid,
  List<FaceRect> faceRegions,
  int placementCount,
) {
  // Same divisor as rhombille, so the density slider means the same thing in both.
  final cellsOnShort = math.max(3, jsRound(settings.density / 6).toInt());
  final cells = buildHexCells(baseWidth, baseHeight, cellsOnShort);
  if (cells.isEmpty) return;

  final scored =
      <
        ({
          HexCell cell,
          HexRect rect,
          RegionAnalysis region,
          double sal,
          double priority,
        })
      >[];
  for (final cell in cells) {
    final rect = hexSampleRect(cell);
    final x = math.max(0.0, math.min(baseWidth - 1, rect.x));
    final y = math.max(0.0, math.min(baseHeight - 1, rect.y));
    final w = math.max(1.0, math.min(baseWidth - x, rect.width));
    final h = math.max(1.0, math.min(baseHeight - y, rect.height));
    final region = analyzer.sampleRegion(x: x, y: y, width: w, height: h);
    final sal = _saliencyAtPoint(
      cell.cx,
      cell.cy,
      baseWidth,
      baseHeight,
      faceRegions,
    );
    scored.add((
      cell: cell,
      rect: rect,
      region: region,
      sal: sal,
      priority: region.detailScore * 0.5 + sal * 0.5,
    ));
  }
  _stableSort(scored, (a, b) => b.priority.compareTo(a.priority));

  final usageCounts = <String, int>{};
  for (final entry in scored) {
    final cell = entry.cell;
    final nearbyTiles = _collectNearbyTilesAt(
      cell.cx,
      cell.cy,
      entry.rect.width,
      placements,
      grid,
      settings.reusePenalty,
    );
    final match = selectBestTileMatch(
      MatchInput(
        region: entry.region,
        tiles: tiles,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: entry.sal,
        tilePoolSize: tiles.length,
        placementCount: placementCount,
      ),
    );
    final baseId = getBaseTileId(match.tile.id);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

    final idx = placements.length;
    final placement = entry.region.toPlacement(
      idx,
      match.tile.id,
      match.tile.name,
      match.score,
    );
    // Overwrite with the TRUE, unclamped geometry — see the note above. The region was
    // sampled from a clamped rect so the analyser stays inside the image, but the
    // placement must record where the hexagon really is.
    placement.x = entry.rect.x;
    placement.y = entry.rect.y;
    placement.width = entry.rect.width;
    placement.height = entry.rect.height;
    placements.add(placement);

    final gc = (cell.cx / grid.cellSize).floor();
    final gr = (cell.cy / grid.cellSize).floor();
    (grid.buckets[gr * grid.cols + gc] ??= <int>[]).add(idx);
  }
}

/// The colour a tile actually SHOWS once cover-cropped into a cell of [cellAR].
///
/// Needed because the upgrade decision compares one big cell against several small
/// ones, and the scorer's composite score is NOT comparable across cell sizes — a
/// larger region has more internal variance, so its best score is systematically
/// higher, and a direct comparison would reject every shape. Colour distance between a
/// region's average and the colour its tile displays is size-independent, which makes
/// it the right basis.
LabColor _shownLab(
  TileDescriptor tile,
  double cellAR, [
  Map<String, TileCrop>? crops,
]) {
  // "The colour this tile DISPLAYS" — so it has to honour a manual crop as well as the
  // automatic one, or the upgrade pass compares a shape against a colour the cell will
  // never show. `original` never anchors to the top, hence the literal false.
  final cw = computeCropWeights(
    tile.aspectRatio,
    cellAR,
    null,
    false,
    crops != null ? cropForTile(crops, tile.id, cellAR) : null,
  );
  if (cw == null || tile.subregionColors == null) return tile.averageLabColor;
  var l = 0.0, a = 0.0, b = 0.0, w = 0.0;
  for (var i = 0; i < 25; i++) {
    final wi = cw[i];
    if (wi <= 0) continue;
    final c = tile.subregionColors![i];
    l += c.L * wi;
    a += c.a * wi;
    b += c.b * wi;
    w += wi;
  }
  return w > 0 ? LabColor(l / w, a / w, b / w) : tile.averageLabColor;
}

/// How much WORSE a shape may be than the cells it replaces and still be accepted.
///
/// Counterintuitively this wants to be well above 1. A strict gate admits almost
/// nothing — one photo averaged over four cells rarely beats four individually-chosen
/// photos on colour distance — and the result is a near-uniform mosaic. Loosening it
/// admits more shapes AND measures BETTER, because consolidating four cells into one
/// returns three photos to the pool, easing reuse pressure everywhere else.
///
/// Measured (200 photos, d135): 1.0 -> err 0.105 with 15 multi-cell cells; 2.5 -> 0.102
/// with ~105. 2.5 is where the curve flattens.
const double _upgradeMargin = 2.5;

/// The `original` layout: lay the whole picture out with the FILL shapes first, then
/// upgrade to multi-cell shapes only where a shape demonstrably beats what those cells
/// already achieved.
///
/// In the default order the shape pass runs first and picks its tiles from a pristine
/// library, on scores computed with no usage, no neighbours and no colour bias. Every
/// shape it commits takes a well-matching photo away from the 1x1 fill that follows,
/// which then pays reuse penalties on the leftovers. Measured on the web bench that
/// costs ~0.012 of mean colour error, and it is pure opportunity cost: multi-cell cells
/// actually score BETTER than 1x1 cells (0.098 vs 0.122). They simply do not earn what
/// they take.
///
/// Here a shape must beat the fill's ACHIEVED scores, measured under the same penalty
/// regime, with the tiles it would displace already returned to the pool. Measured
/// against the old shapes-first order: mean colour error 0.118 -> 0.099 on a uniform
/// library, 0.142 -> 0.113 on a 50/50 mixed one, discarded photos 35 -> 8.
///
/// Must match `fillFirstLayout` in foto-mozaik/lib/mosaic/grid-layout.ts.
void _fillFirstLayout(
  int M,
  int N,
  double cellW,
  double cellH,
  List<List<bool>> occupied,
  List<List<double>> cellSaliency,
  Map<double, List<TileDescriptor>> tilePools,
  ImageAnalyzer analyzer,
  MosaicSettings settings,
  Map<String, int> usageCounts,
  List<MosaicPlacement> placements,
  SpatialGrid grid,
  int tilePoolSize,
  int placementCount,
  List<CellShape> shapes,
  List<CellShape> fillShapes,
  Map<String, LabColor> colorErrors,
  double cellAR,
) {
  // `_fillRemainingCells` orders cells by baseline detail, so it needs real baselines
  // even though this pass does not use them to gate shapes.
  final baselinePool =
      tilePools[_anyOrientationAR] ??
      _poolForShape(tilePools, cellAR) ??
      const <TileDescriptor>[];
  final baselines = _computeBaselines(
    M,
    N,
    cellW,
    cellH,
    analyzer,
    baselinePool,
    settings,
  );

  // ── Phase A: the whole picture in the FULL fill menu ──────────────────────
  //
  // Not just 1x1: filling everything with one cell aspect starves the minority
  // orientation, because the matcher rejects portrait photos from landscape cells, so
  // with a mixed library they have nowhere to live and go unused — measured at 93 of
  // 100 dropped on a 50/50 library. The small non-square fill shapes are what give
  // those photos a home, and they have to exist BEFORE the upgrade pass, not compete
  // for an upgrade they will never win.
  final tileById = <String, TileDescriptor>{};
  for (final pool in tilePools.values) {
    for (final t in pool) {
      tileById[t.id] = t;
    }
  }
  _fillRemainingCells(
    M,
    N,
    cellW,
    cellH,
    occupied,
    baselines,
    cellSaliency,
    tilePools,
    analyzer,
    settings,
    usageCounts,
    placements,
    grid,
    tilePoolSize,
    placementCount,
    fillShapes,
    0.5,
    colorErrors,
  );

  // Which placement owns each cell. A fill placement may be multi-cell, so several
  // cells can share one owner — the upgrade pass dedupes and checks containment.
  final owner = List.generate(
    N,
    (_) => List<int>.filled(M, -1),
    growable: false,
  );
  final achieved = List.generate(
    N,
    (_) => List<double>.filled(M, double.infinity),
    growable: false,
  );
  final cellsOf = <int, int>{};
  for (var i = 0; i < placements.length; i++) {
    final p = placements[i];
    final c0 = jsRound(p.x / cellW).toInt();
    final r0 = jsRound(p.y / cellH).toInt();
    final cw = math.max(1, jsRound(p.width / cellW).toInt());
    final ch = math.max(1, jsRound(p.height / cellH).toInt());
    cellsOf[i] = cw * ch;
    for (var dr = 0; dr < ch; dr++) {
      for (var dc = 0; dc < cw; dc++) {
        final r = r0 + dr, c = c0 + dc;
        if (r < 0 || r >= N || c < 0 || c >= M) continue;
        owner[r][c] = i;
        achieved[r][c] = p.score / (cw * ch);
      }
    }
  }

  // ── Phase B: shortlist candidates ─────────────────────────────────────────
  final regions = <RegionAnalysis>[];
  final positions = <({int col, int row, CellShape shape, double gain})>[];
  final saliencyList = <double>[];
  final poolIndexList = <int>[];
  final poolList = <List<TileDescriptor>>[];
  final poolKeyByAR = <double, int>{};

  for (final shape in shapes) {
    final pool = _poolForShape(tilePools, shape.ar);
    if (pool == null || pool.isEmpty) continue;
    var poolIdx = poolKeyByAR[shape.ar];
    if (poolIdx == null) {
      poolIdx = poolList.length;
      poolList.add(pool);
      poolKeyByAR[shape.ar] = poolIdx;
    }
    for (var r = 0; r <= N - shape.rows; r++) {
      for (var c = 0; c <= M - shape.cols; c++) {
        var sum = 0.0;
        var ok = true;
        for (var dr = 0; dr < shape.rows && ok; dr++) {
          for (var dc = 0; dc < shape.cols; dc++) {
            final a = achieved[r + dr][c + dc];
            if (!a.isFinite) {
              ok = false;
              break;
            }
            sum += a;
          }
        }
        if (!ok) continue;
        regions.add(
          analyzer.sampleRegion(
            x: c * cellW,
            y: r * cellH,
            width: shape.cols * cellW,
            height: shape.rows * cellH,
          ),
        );
        positions.add((col: c, row: r, shape: shape, gain: sum / shape.cells));
        saliencyList.add(_avgCellSaliency(c, r, shape, cellSaliency));
        poolIndexList.add(poolIdx);
      }
    }
  }
  if (regions.isEmpty) return;

  final batch = _scoreMultiPoolRegionsSync(
    regions,
    Float32List.fromList(saliencyList),
    poolIndexList,
    poolList,
    settings,
  );

  // Rank by OPTIMISTIC net gain — the shortlist only has to be generous, because every
  // entry is verified for real below.
  final shortlist = <({int i, double net})>[];
  for (var i = 0; i < positions.length; i++) {
    final net = positions[i].gain - batch[i];
    if (net > 0) shortlist.add((i: i, net: net));
  }
  _stableSort(shortlist, (a, b) => b.net.compareTo(a.net));
  final cap = math.max(64, jsRound((M * N) / 2).toInt());
  final candidates = shortlist.length > cap
      ? shortlist.sublist(0, cap)
      : shortlist;

  // ── Phase C: verify each candidate for real, then commit ──────────────────
  final dead = <int>{};
  for (final entry in candidates) {
    final i = entry.i;
    final pos = positions[i];
    // NOT a `shapeFits` occupancy test: after Phase A every cell is occupied, so that
    // rejects every candidate. What matters is whether the covered cells are still
    // owned by LIVE placements — checked as the victims are gathered.
    final candX = pos.col * cellW, candY = pos.row * cellH;
    final candR = candX + pos.shape.cols * cellW;
    final candB = candY + pos.shape.rows * cellH;
    const eps = 0.5;
    final victims = <int>[];
    final seen = <int>{};
    var covered = 0;
    var stale = false;
    for (var dr = 0; dr < pos.shape.rows && !stale; dr++) {
      for (var dc = 0; dc < pos.shape.cols; dc++) {
        final idx = owner[pos.row + dr][pos.col + dc];
        if (idx < 0 || dead.contains(idx)) {
          stale = true;
          break;
        }
        if (seen.contains(idx)) continue;
        final v = placements[idx];
        // A fill placement that pokes out (a 1x2 straddling the edge) cannot be
        // swallowed — otherwise half a portrait cell would be deleted, leaving a hole.
        if (v.x < candX - eps ||
            v.y < candY - eps ||
            v.x + v.width > candR + eps ||
            v.y + v.height > candB + eps) {
          stale = true;
          break;
        }
        seen.add(idx);
        victims.add(idx);
        covered += cellsOf[idx] ?? 1;
      }
    }
    if (stale || victims.isEmpty || covered != pos.shape.cells) continue;

    // Return the displaced tiles to the pool BEFORE scoring, or the shape is charged
    // for competing with photos it is about to free.
    for (final v in victims) {
      final id = getBaseTileId(placements[v].tileId);
      final n = (usageCounts[id] ?? 1) - 1;
      if (n <= 0) {
        usageCounts.remove(id);
      } else {
        usageCounts[id] = n;
      }
    }

    final pool = _poolForShape(tilePools, pos.shape.ar)!;
    final nearbyTiles = _collectNearbyTiles(
      pos.col,
      pos.row,
      cellW,
      cellH,
      placements,
      grid,
      settings.reusePenalty,
      dead,
    );
    final neighborAvgColor = _computeNeighborAvgColor(
      pos.col,
      pos.row,
      cellW,
      cellH,
      placements,
      grid,
      dead,
    );
    final match = selectBestTileMatch(
      MatchInput(
        region: regions[i],
        tiles: pool,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: saliencyList[i],
        neighborAvgColor: neighborAvgColor,
        tilePoolSize: tilePoolSize,
        placementCount: placementCount,
        colorBias: colorErrors[_cellKey(pos.col, pos.row)],
      ),
    );

    // The real test: does ONE photo reconstruct this region better than the several
    // photos already there? Compared as colour distance, which is size-independent.
    final dShape = labDistance(
      regions[i].averageLabColor,
      _shownLab(match.tile, pos.shape.ar, settings.tileCrops),
    );
    var dVictims = 0.0;
    for (final v in victims) {
      final vp = placements[v];
      final vt = tileById[getBaseTileId(vp.tileId)];
      final w = cellsOf[v] ?? 1;
      dVictims +=
          w *
          (vt != null
              ? labDistance(
                  vp.averageLabColor,
                  _shownLab(vt, vp.width / vp.height, settings.tileCrops),
                )
              : dShape);
    }
    dVictims /= covered;

    if (dShape > dVictims * _upgradeMargin) {
      // Not good enough — put the tiles back and leave the fill cells alone.
      for (final v in victims) {
        final id = getBaseTileId(placements[v].tileId);
        usageCounts[id] = (usageCounts[id] ?? 0) + 1;
      }
      continue;
    }

    for (final v in victims) {
      dead.add(v);
      final vp = placements[v];
      final c0 = jsRound(vp.x / cellW).toInt();
      final r0 = jsRound(vp.y / cellH).toInt();
      final cw = math.max(1, jsRound(vp.width / cellW).toInt());
      final ch = math.max(1, jsRound(vp.height / cellH).toInt());
      for (var dr = 0; dr < ch; dr++) {
        for (var dc = 0; dc < cw; dc++) {
          if (r0 + dr < N && c0 + dc < M) owner[r0 + dr][c0 + dc] = -1;
        }
      }
    }
    _commitPlacement(
      pos.col,
      pos.row,
      pos.shape,
      cellW,
      cellH,
      regions[i],
      match.tile,
      match.score,
      occupied,
      usageCounts,
      placements,
      grid,
    );
  }

  // ── Phase D: compact ──────────────────────────────────────────────────────
  // Tombstones must not survive: everything downstream (adjacency, SA, palette
  // balance, coverage) assumes a densely-indexed array.
  if (dead.isNotEmpty) {
    final live = <MosaicPlacement>[];
    for (var i = 0; i < placements.length; i++) {
      if (!dead.contains(i)) live.add(placements[i]);
    }
    placements.clear();
    for (var i = 0; i < live.length; i++) {
      live[i].index = i;
      placements.add(live[i]);
    }
  }

  // Any cell a shape could not cover is already filled from Phase A, so the only work
  // left is the fill shapes for cells never claimed at all (edges).
  _fillRemainingCells(
    M,
    N,
    cellW,
    cellH,
    occupied,
    baselines,
    cellSaliency,
    tilePools,
    analyzer,
    settings,
    usageCounts,
    placements,
    grid,
    tilePoolSize,
    placementCount,
    fillShapes,
    0.5,
    colorErrors,
  );
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
  Map<String, LabColor>? colorErrors,
) {
  final regions = <RegionAnalysis>[];
  final positions =
      <({int col, int row, CellShape shape, double avgBaseline})>[];
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

    final posStride = shape.cells >= 16
        ? 3
        : shape.cells >= 8
        ? 2
        : 1;

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
          height: shape.rows * cellH,
        );
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
      regions,
      saliencies,
      poolIndexList,
      poolList,
      settings,
    );
    for (var i = 0; i < regions.length; i++) {
      final pos = positions[i];
      final perCellImprovement = pos.avgBaseline - scores[i];
      if (perCellImprovement > -0.005) {
        final sal = saliencyList[i];
        final salPenalty = sal > 0.4 && pos.shape.cells > 4
            ? 1 + (sal - 0.4) * (pos.shape.cells / 6)
            : 1.0;
        // FLAT, not sqrt(cells). Weighting by size made the ranking prefer big shapes
        // for their size rather than their fit, so an 8-cell shape with a mediocre
        // per-cell improvement outranked a 2-cell shape with a great one. Measured
        // 10-13% better across every library tested and ~35% faster, because fewer
        // oversized candidates are evaluated. The saliency penalty stays: faces want
        // granular control, so a large shape over a salient region is still pushed down.
        final weight = 1 / salPenalty;
        candidates.add(
          _ShapeCandidate(
            pos.col,
            pos.row,
            pos.shape,
            perCellImprovement * weight,
            regions[i],
            sal,
          ),
        );
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
      cand.col,
      cand.row,
      cellW,
      cellH,
      placements,
      grid,
      settings.reusePenalty,
    );
    final neighborAvgColor = _computeNeighborAvgColor(
      cand.col,
      cand.row,
      cellW,
      cellH,
      placements,
      grid,
    );
    final colorBias = colorErrors?[_cellKey(cand.col, cand.row)];
    final m = selectBestTileMatch(
      MatchInput(
        region: cand.region,
        tiles: pool,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: cand.saliency,
        neighborAvgColor: neighborAvgColor,
        tilePoolSize: tilePoolSize,
        placementCount: placementCount,
        colorBias: colorBias,
      ),
    );

    _commitPlacement(
      cand.col,
      cand.row,
      cand.shape,
      cellW,
      cellH,
      cand.region,
      m.tile,
      m.score,
      occupied,
      usageCounts,
      placements,
      grid,
    );
    if (colorErrors != null) {
      _spreadColorError(
        colorErrors,
        cand.col,
        cand.row,
        cand.shape,
        M,
        N,
        occupied,
        cand.region.averageLabColor.L +
            (colorBias?.L ?? 0) -
            m.tile.averageLabColor.L,
        cand.region.averageLabColor.a +
            (colorBias?.a ?? 0) -
            m.tile.averageLabColor.a,
        cand.region.averageLabColor.b +
            (colorBias?.b ?? 0) -
            m.tile.averageLabColor.b,
      );
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
  int placementCount,
) {
  const maxMergedCells = 9;
  const perCellTolerance = 1.15;
  const maxIterations = 2;

  final emptyUsage = <String, int>{};

  for (var iter = 0; iter < maxIterations; iter++) {
    final infos = placements.map((p) {
      final cols = math.max(1, jsRound(p.width / cellW).toInt());
      final rows = math.max(1, jsRound(p.height / cellH).toInt());
      return _MergeInfo(
        jsRound(p.x / cellW).toInt(),
        jsRound(p.y / cellH).toInt(),
        cols,
        rows,
        cols * rows,
        p,
      );
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
          height: rows * cellH,
        );
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

        final m = selectBestTileMatch(
          MatchInput(
            region: region,
            tiles: pool,
            settings: settings,
            usageCounts: emptyUsage,
            tilePoolSize: tilePoolSize,
            placementCount: placementCount,
          ),
        );

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

        mergedThisPass.add(
          region.toPlacement(-1, m.tile.id, m.tile.name, m.score),
        );
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
  _MergeInfo(
    this.col,
    this.row,
    this.cols,
    this.rows,
    this.cells,
    this.placement,
  );
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
  Map<String, LabColor>? colorErrors,
) {
  final cells = <({int col, int row, double priority, double sal})>[];
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      if (occupied[r][c]) continue;
      final sal = cellSaliency[r][c];
      cells.add((
        col: c,
        row: r,
        priority: baselines[r][c] * 0.5 + sal * 0.5,
        sal: sal,
      ));
    }
  }
  _stableSort(cells, (a, b) => b.priority.compareTo(a.priority));

  for (final cell in cells) {
    final col = cell.col, row = cell.row, sal = cell.sal;
    if (occupied[row][col]) continue;

    final nearbyTiles = _collectNearbyTiles(
      col,
      row,
      cellW,
      cellH,
      placements,
      grid,
      settings.reusePenalty,
    );
    final neighborAvgColor = _computeNeighborAvgColor(
      col,
      row,
      cellW,
      cellH,
      placements,
      grid,
    );

    var bestShape = _shape1x1;
    RegionAnalysis? bestRegion;
    TileDescriptor? bestTile;
    var bestScore = double.infinity;
    final colorBias = colorErrors?[_cellKey(col, row)];

    for (final shape in (shapesOverride ?? _fillShapes)) {
      if (!_shapeFits(col, row, shape, M, N, occupied)) continue;
      if (shape.cells > 1 && sal > fillSalThreshold) continue;
      // The 1x1 fill is the LAST RESORT and draws from the any-orientation pool, not
      // from the square pool its aspect would key. Reading `tilePools[shape.ar]` here
      // sent it to the orientation-filtered square pool — which `_buildTilePools`
      // deliberately EMPTIES when too few photos are square, so the one shape that must
      // always have something to place could be starved or skipped outright, leaving
      // the fill to larger shapes that fit worse.
      final pool = shape.cells == 1
          ? tilePools[_anyOrientationAR]
          : tilePools[shape.ar];
      if (pool == null || pool.isEmpty) continue;

      final region = analyzer.sampleRegion(
        x: col * cellW,
        y: row * cellH,
        width: shape.cols * cellW,
        height: shape.rows * cellH,
      );

      final shapeSal = shape.cells > 1
          ? _avgCellSaliency(col, row, shape, cellSaliency)
          : sal;
      final m = selectBestTileMatch(
        MatchInput(
          region: region,
          tiles: pool,
          settings: settings,
          usageCounts: usageCounts,
          nearbyTiles: nearbyTiles,
          saliency: shapeSal,
          neighborAvgColor: neighborAvgColor,
          tilePoolSize: tilePoolSize,
          placementCount: placementCount,
          colorBias: colorBias,
        ),
      );

      if (m.score < bestScore) {
        bestScore = m.score;
        bestShape = shape;
        bestRegion = region;
        bestTile = m.tile;
      }
    }

    if (bestTile != null && bestRegion != null) {
      _commitPlacement(
        col,
        row,
        bestShape,
        cellW,
        cellH,
        bestRegion,
        bestTile,
        bestScore,
        occupied,
        usageCounts,
        placements,
        grid,
      );
      if (colorErrors != null) {
        _spreadColorError(
          colorErrors,
          col,
          row,
          bestShape,
          M,
          N,
          occupied,
          bestRegion.averageLabColor.L +
              (colorBias?.L ?? 0) -
              bestTile.averageLabColor.L,
          bestRegion.averageLabColor.a +
              (colorBias?.a ?? 0) -
              bestTile.averageLabColor.a,
          bestRegion.averageLabColor.b +
              (colorBias?.b ?? 0) -
              bestTile.averageLabColor.b,
        );
      }
    }
  }
}

void _vogelAssign(
  List<MosaicPlacement> placements,
  List<TileDescriptor> tiles,
  MosaicSettings settings,
  Float64List placementSaliency,
) {
  if (placements.isEmpty || tiles.isEmpty) return;

  final n = placements.length;
  final K = math.min(80, tiles.length);

  final candidateLists = List<List<RegionCandidate>>.filled(n, const []);
  for (var i = 0; i < n; i++) {
    candidateLists[i] = getTopKCandidates(
      placements[i],
      tiles,
      settings,
      placementSaliency[i],
      K,
    );
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
  final maxUses = resolveMaxTileUses(settings.maxTileUses, tiles.length, n);
  final usageCounts = <String, int>{};
  // How many photos are still under the cap — a re-search is pointless once it is 0.
  var openCount = maxUses > 0
      ? tiles.map((t) => getBaseTileId(t.id)).toSet().length
      : 0;
  bool isCapped(TileDescriptor t) =>
      (usageCounts[getBaseTileId(t.id)] ?? 0) >= maxUses;

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

    TileDescriptor? bestTile;
    var bestTotal = double.infinity;
    // Every candidate already at the cap is not a dead end — the cell still has to hold
    // something. The one used LEAST is the least-bad answer, and picking it keeps the
    // overflow spread across the library.
    //
    // This must not fall back to cands[0]: that is the globally cheapest tile, so every
    // exhausted cell picks the SAME photo and the cap inverts into a magnet. Measured on
    // a 200-photo library at a cap of 9, that fallback drove one photo to 247 cells —
    // six times what removing the cap entirely produces.
    TileDescriptor? fallbackTile;
    var fallbackUse = double.infinity;
    var fallbackCost = double.infinity;

    for (final cand in cands) {
      final tile = cand.tile;
      final baseCost = cand.baseCost;
      final baseId = getBaseTileId(tile.id);
      // Vogel assigns every cell from scratch, so the cap has to hold here too —
      // enforcing it only in the greedy pass would leave it undone for any mosaic small
      // enough to take this path.
      if (maxUses > 0 && (usageCounts[baseId] ?? 0) >= maxUses) {
        final used = (usageCounts[baseId] ?? 0).toDouble();
        if (used < fallbackUse ||
            (used == fallbackUse && baseCost < fallbackCost)) {
          fallbackUse = used;
          fallbackCost = baseCost;
          fallbackTile = tile;
        }
        continue;
      }
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

    // The cell's 80 best are all at the cap. With a large library the cap is still
    // satisfiable — there are unused photos just outside the shortlist — so take the best
    // of THOSE instead of repeating one (web parity: vogelAssign). The least-used
    // fallback below still applies once no photo has a use left.
    if (bestTile == null && maxUses > 0 && openCount > 0) {
      final fresh = getTopKCandidates(
        placements[i],
        tiles,
        settings,
        sal,
        8,
        isCapped,
      );
      if (fresh.isNotEmpty) bestTile = fresh.first.tile;
    }
    final chosen = bestTile ?? fallbackTile ?? cands[0].tile;
    placements[i].tileId = chosen.id;
    placements[i].tileName = chosen.name;
    final baseId = getBaseTileId(chosen.id);
    final nowUsed = (usageCounts[baseId] ?? 0) + 1;
    usageCounts[baseId] = nowUsed;
    if (maxUses > 0 && nowUsed == maxUses) openCount--;
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
  int placementCount,
) {
  final cells =
      <
        ({int col, int row, double priority, double sal, RegionAnalysis region})
      >[];
  for (var r = 0; r < N; r++) {
    for (var c = 0; c < M; c++) {
      final region = analyzer.sampleRegion(
        x: c * cellW,
        y: r * cellH,
        width: cellW,
        height: cellH,
      );
      final sal = cellSaliency[r][c];
      cells.add((
        col: c,
        row: r,
        priority: region.detailScore * 0.5 + sal * 0.5,
        sal: sal,
        region: region,
      ));
    }
  }
  _stableSort(cells, (a, b) => b.priority.compareTo(a.priority));

  final usageCounts = <String, int>{};
  final occupied = List.generate(
    N,
    (_) => List<bool>.filled(M, false),
    growable: false,
  );
  final colorErrors = <String, LabColor>{};

  for (final cell in cells) {
    final col = cell.col, row = cell.row, sal = cell.sal, region = cell.region;
    final nearbyTiles = _collectNearbyTiles(
      col,
      row,
      cellW,
      cellH,
      placements,
      grid,
      settings.reusePenalty,
    );
    final neighborAvgColor = _computeNeighborAvgColor(
      col,
      row,
      cellW,
      cellH,
      placements,
      grid,
    );
    final colorBias = colorErrors[_cellKey(col, row)];

    final m = selectBestTileUniform(
      UniformMatchInput(
        region: region,
        resolved: resolved,
        settings: settings,
        usageCounts: usageCounts,
        nearbyTiles: nearbyTiles,
        saliency: sal,
        neighborAvgColor: neighborAvgColor,
        tilePoolSize: tilePoolSize,
        placementCount: placementCount,
        colorBias: colorBias,
      ),
    );

    occupied[row][col] = true;
    final baseId = getBaseTileId(m.tile.id);
    usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

    placements.add(
      region.toPlacement(placements.length, m.tile.id, m.tile.name, m.score),
    );

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
      region.averageLabColor.b + (colorBias?.b ?? 0) - m.tile.averageLabColor.b,
    );
  }
}

/// [dead] holds indices displaced by the upgrade pass — still present in the array and
/// the spatial grid until compaction, but no longer part of the mosaic.
Map<String, double> _collectNearbyTiles(
  int col,
  int row,
  double cellW,
  double cellH,
  List<MosaicPlacement> placements,
  SpatialGrid grid, [
  double reusePenalty = 0,
  Set<int>? dead,
]) {
  final nearby = <String, double>{};
  final cx = (col + 0.5) * cellW;
  final cy = (row + 0.5) * cellH;
  final cellSize = math.max(cellW, cellH);
  // Radius over which the duplicate penalty applies. Tightened from 3 cells: it is
  // meant to stop a photo clustering ON TOP of itself, not to keep it out of a whole
  // region — see _neighborDuplicatePenaltyBase.
  final reach = cellSize * (1.6 + reusePenalty * 4);

  final candidates = _spatialQuery(grid, cx, cy, reach);
  for (var k = 0; k < candidates.length; k++) {
    if (dead != null && dead.contains(candidates[k])) continue;
    final p = placements[candidates[k]];
    final nearestX = math.max(p.x, math.min(cx, p.x + p.width));
    final nearestY = math.max(p.y, math.min(cy, p.y + p.height));
    final edgeDist = math.sqrt(
      math.pow(nearestX - cx, 2).toDouble() +
          math.pow(nearestY - cy, 2).toDouble(),
    );
    final proximity = math.max(0, 1 - edgeDist / reach).toDouble();
    if (proximity <= 0) continue;

    final baseId = getBaseTileId(p.tileId);
    final prev = nearby[baseId] ?? 0;
    if (proximity > prev) nearby[baseId] = proximity;
  }

  return nearby;
}

LabColor? _computeNeighborAvgColor(
  int col,
  int row,
  double cellW,
  double cellH,
  List<MosaicPlacement> placements,
  SpatialGrid grid, [
  Set<int>? dead,
]) {
  final cx = (col + 0.5) * cellW;
  final cy = (row + 0.5) * cellH;
  final cellSize = math.max(cellW, cellH);
  final reach = cellSize * 2;

  var wSum = 0.0, sL = 0.0, sA = 0.0, sB = 0.0;
  final candidates = _spatialQuery(grid, cx, cy, reach);
  for (var k = 0; k < candidates.length; k++) {
    if (dead != null && dead.contains(candidates[k])) continue;
    final p = placements[candidates[k]];
    final nearestX = math.max(p.x, math.min(cx, p.x + p.width));
    final nearestY = math.max(p.y, math.min(cy, p.y + p.height));
    final dist = math.sqrt(
      math.pow(nearestX - cx, 2).toDouble() +
          math.pow(nearestY - cy, 2).toDouble(),
    );
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
  int col,
  int row,
  CellShape shape,
  int M,
  int N,
  List<List<bool>> occupied,
) {
  if (col + shape.cols > M || row + shape.rows > N) return false;
  for (var dr = 0; dr < shape.rows; dr++) {
    for (var dc = 0; dc < shape.cols; dc++) {
      if (occupied[row + dr][col + dc]) return false;
    }
  }
  return true;
}

void _markOccupied(
  int col,
  int row,
  CellShape shape,
  List<List<bool>> occupied,
) {
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
  SpatialGrid grid,
) {
  _markOccupied(col, row, shape, occupied);

  final baseId = getBaseTileId(tile.id);
  usageCounts[baseId] = (usageCounts[baseId] ?? 0) + 1;

  final idx = placements.length;
  final px = col * cellW;
  final py = row * cellH;
  final pw = shape.cols * cellW;
  final ph = shape.rows * cellH;

  placements.add(
    MosaicPlacement(
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
    ),
  );

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

double _scoreMosaicReconstruction(
  List<MosaicPlacement> placements,
  Map<String, TileDescriptor> tileMap,
  Float64List saliency,
  List<Set<int>> adjacency,
) {
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
  final perCellScore = perCellTotalW > 0
      ? perCellWeighted / perCellTotalW
      : 0.0;

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
      final tileLumDiff =
          (tileI.averageLabColor.L - tileJ.averageLabColor.L) / 100;
      final regionLumDiff = (pi.averageLabColor.L - pj.averageLabColor.L) / 100;
      final err = math.pow(tileLumDiff - regionLumDiff, 2).toDouble();
      final w = (saliency[i] + saliency[j]) * 0.5;
      coherenceWeighted += err * w;
      coherenceTotalW += w;
    }
  }
  final coherenceScore = coherenceTotalW > 0
      ? coherenceWeighted / coherenceTotalW
      : 0.0;

  return perCellScore + _coherenceWeight * coherenceScore;
}

Float64List _computePlacementSaliency(
  List<RegionAnalysis> regions,
  List<Set<int>> adjacency,
  double baseWidth,
  double baseHeight,
  List<FaceRect> faceRegions,
) {
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
    final centerProximity =
        1 -
        math.sqrt(
              math.pow(rcx - cx, 2).toDouble() +
                  math.pow(rcy - cy, 2).toDouble(),
            ) /
            maxDist;

    var neighborContrast = 0.0;
    if (adjacency[i].isNotEmpty) {
      var contrastSum = 0.0;
      for (final ni in adjacency[i]) {
        contrastSum += labDistance(
          r.averageLabColor,
          regions[ni].averageLabColor,
        );
      }
      neighborContrast = contrastSum / adjacency[i].length;
    }

    if (hasFaces) {
      final fb = _regionFaceOverlap(r, faceRegions);
      sal[i] =
          r.detailScore * 0.20 +
          r.colorVariance * 0.10 +
          centerProximity * 0.10 +
          neighborContrast * 0.15 +
          fb * 0.45;
    } else {
      sal[i] =
          r.detailScore * 0.30 +
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
      0,
      math.min(r.x + r.width, f.x + f.width) - math.max(r.x, f.x),
    );
    final oy = math.max(
      0,
      math.min(r.y + r.height, f.y + f.height) - math.max(r.y, f.y),
    );
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
    final key =
        ((regions[i].y + regions[i].height / 2) / cs).floor() * cols +
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
