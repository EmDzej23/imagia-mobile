import 'dart:typed_data';

import 'matching.dart';
import 'types.dart';

/// A batch of independent scoring the layout asks for while it runs — every item
/// scored on its own, against the same photos, so the batch can be split anywhere.
///
/// The layout steps (grid_layout.dart) hand these out instead of computing them:
/// a sync driver just calls [computeHere]; the layout worker splits a big batch into
/// [slice]s, runs them on helper isolates and on itself, and hands the parts to
/// [take] in order. Either way the results are the same numbers.
abstract class LayoutBatch {
  int get length;

  /// Items [a, b) as a batch of their own — plain data, sendable to an isolate
  /// ([send]: in the form that copies fastest; else as it is, to run here).
  LayoutBatch slice(int a, int b, {bool send = true});

  /// This batch's result (what [take] expects, one part per slice).
  Object run();

  /// The results of consecutive slices covering the batch, in order.
  void take(List<Object> parts);

  void computeHere() => take([run()]);
}

/// The regions a batch scores: the objects themselves, or — in a slice sent to a
/// helper — [PackedRegions], rebuilt there on first use.
class _Regions {
  _Regions.of(List<RegionAnalysis> list)
    : _list = list,
      _packed = null,
      length = list.length;
  _Regions.packed(PackedRegions p) : _list = null, _packed = p, length = p.n;

  List<RegionAnalysis>? _list;
  final PackedRegions? _packed;
  final int length;

  List<RegionAnalysis> get list => _list ??= _packed!.unpack();

  /// Items [a, b) for a helper: packed when possible.
  _Regions slice(int a, int b, bool send) {
    final l = _list;
    if (l == null || !send) return _Regions.of(list.sublist(a, b));
    final p = PackedRegions.pack(l, a, b);
    return p != null ? _Regions.packed(p) : _Regions.of(l.sublist(a, b));
  }
}

/// Each region's best-match score (`selectBestTileMatch` with no usage so far):
/// against `pools[poolIndex[i]]` with `saliencies[i]`, or — when [poolIndex] is null —
/// against `pools[0]` with no saliency.
class RegionScoreBatch extends LayoutBatch {
  RegionScoreBatch(
    List<RegionAnalysis> regions,
    Float32List? saliencies,
    List<int>? poolIndex,
    List<List<TileDescriptor>> pools,
    MosaicSettings settings,
  ) : this._(_Regions.of(regions), saliencies, poolIndex, pools, settings);

  RegionScoreBatch._(
    this._regions,
    this.saliencies,
    this.poolIndex,
    this.pools,
    this.settings,
  );

  final _Regions _regions;
  final Float32List? saliencies;
  final List<int>? poolIndex;
  final List<List<TileDescriptor>> pools;
  final MosaicSettings settings;
  Float64List? result;

  @override
  int get length => _regions.length;

  @override
  LayoutBatch slice(int a, int b, {bool send = true}) => RegionScoreBatch._(
    _regions.slice(a, b, send),
    saliencies == null ? null : Float32List.sublistView(saliencies!, a, b),
    poolIndex?.sublist(a, b),
    _usedPools(a, b),
    settings,
  );

  /// Only the pools items [a, b) use go along (the others are left empty, so the
  /// indices stay valid) — less to copy into a helper.
  List<List<TileDescriptor>> _usedPools(int a, int b) {
    final pi = poolIndex;
    if (pi == null) return pools;
    final used = List<bool>.filled(pools.length, false);
    for (var i = a; i < b; i++) {
      used[pi[i]] = true;
    }
    return [
      for (var k = 0; k < pools.length; k++)
        used[k] ? pools[k] : const <TileDescriptor>[],
    ];
  }

  @override
  Object run() {
    final regions = _regions.list;
    final out = Float64List(regions.length);
    final emptyUsage = <String, int>{};
    final pi = poolIndex, sal = saliencies;
    for (var i = 0; i < regions.length; i++) {
      out[i] = selectBestTileMatch(
        MatchInput(
          region: regions[i],
          tiles: pools[pi == null ? 0 : pi[i]],
          settings: settings,
          usageCounts: emptyUsage,
          saliency: sal?[i],
        ),
      ).score;
    }
    return out;
  }

  @override
  void take(List<Object> parts) {
    if (parts.length == 1) {
      result = parts.single as Float64List;
      return;
    }
    final out = Float64List(length);
    var o = 0;
    for (final p in parts) {
      final f = p as Float64List;
      out.setRange(o, o + f.length, f);
      o += f.length;
    }
    result = out;
  }
}

/// Each region's top-[k] candidates (`getTopKCandidates`) over [tiles].
class TopKBatch extends LayoutBatch {
  TopKBatch(
    List<RegionAnalysis> regions,
    List<TileDescriptor> tiles,
    MosaicSettings settings,
    Float64List saliency,
    int k,
  ) : this._(_Regions.of(regions), tiles, settings, saliency, k);

  TopKBatch._(this._regions, this.tiles, this.settings, this.saliency, this.k);

  final _Regions _regions;
  final List<TileDescriptor> tiles;
  final MosaicSettings settings;
  final Float64List saliency;
  final int k;

  /// Per region, its candidates (in [tiles]' own objects).
  List<List<RegionCandidate>>? result;

  /// A region's scoring threw (the caller decides what that means).
  bool failed = false;

  @override
  int get length => _regions.length;

  @override
  LayoutBatch slice(int a, int b, {bool send = true}) => TopKBatch._(
    _regions.slice(a, b, send),
    tiles,
    settings,
    Float64List.sublistView(saliency, a, b),
    k,
  );

  /// Per region: how many candidates, then (tile index, cost) for each — indices so
  /// the candidates come back as [tiles]' own objects, not a helper's copies.
  @override
  Object run() {
    final regions = _regions.list;
    final index = Map<TileDescriptor, int>.identity();
    for (var t = 0; t < tiles.length; t++) {
      index.putIfAbsent(tiles[t], () => t);
    }
    final counts = Int32List(regions.length);
    final idx = <int>[];
    final cost = <double>[];
    try {
      for (var i = 0; i < regions.length; i++) {
        final top = getTopKCandidates(
          regions[i],
          tiles,
          settings,
          saliency[i],
          k,
        );
        counts[i] = top.length;
        for (final c in top) {
          idx.add(index[c.tile]!);
          cost.add(c.baseCost);
        }
        // The sequential loop stopped at the first region with no candidates.
        if (top.isEmpty) break;
      }
    } catch (_) {
      return const _TopKFailed();
    }
    return (counts, Int32List.fromList(idx), Float64List.fromList(cost));
  }

  @override
  void take(List<Object> parts) {
    final lists = <List<RegionCandidate>>[];
    for (final p in parts) {
      if (p is _TopKFailed) {
        failed = true;
        return;
      }
      final (Int32List counts, Int32List idx, Float64List cost) =
          p as (Int32List, Int32List, Float64List);
      var o = 0;
      for (var i = 0; i < counts.length; i++) {
        final n = counts[i];
        lists.add([
          for (var c = 0; c < n; c++)
            RegionCandidate(tiles[idx[o + c]], cost[o + c]),
        ]);
        o += n;
      }
    }
    result = lists;
  }
}

class _TopKFailed {
  const _TopKFailed();
}

/// Regions as two flat arrays — what a batch slice sends to a helper instead of the
/// region objects. Copying ~30 small objects per region took longer than scoring it;
/// typed arrays copy as one block. Every value goes over exactly (doubles as doubles,
/// the float32 orientations as float32), so the rebuilt regions score identically.
class PackedRegions {
  PackedRegions._(this.n, this.d, this.o);

  final int n;
  final Float64List d;
  final Float32List o;

  static const int _stride = 148;

  /// Null if a region's arrays are not the standard sizes (then send the objects).
  static PackedRegions? pack(List<RegionAnalysis> regions, int a, int b) {
    final n = b - a;
    final d = Float64List(n * _stride);
    final o = Float32List(n * 100);
    for (var i = 0; i < n; i++) {
      final r = regions[a + i];
      if (r.subregionColors.length != 25 ||
          r.subregionEdges.length != 25 ||
          r.contrastMap.length != 25 ||
          r.tonalHistogram.length != 8 ||
          r.subregionEdgeOrientations.length != 100) {
        return null;
      }
      var k = i * _stride;
      d[k++] = r.x;
      d[k++] = r.y;
      d[k++] = r.width;
      d[k++] = r.height;
      d[k++] = r.averageColor.r;
      d[k++] = r.averageColor.g;
      d[k++] = r.averageColor.b;
      d[k++] = r.averageLabColor.L;
      d[k++] = r.averageLabColor.a;
      d[k++] = r.averageLabColor.b;
      d[k++] = r.detailScore;
      for (final c in r.subregionColors) {
        d[k++] = c.L;
        d[k++] = c.a;
        d[k++] = c.b;
      }
      for (var j = 0; j < 25; j++) {
        d[k++] = r.subregionEdges[j];
      }
      for (var j = 0; j < 25; j++) {
        d[k++] = r.contrastMap[j];
      }
      d[k++] = r.luminanceBalance.vertical;
      d[k++] = r.luminanceBalance.horizontal;
      d[k++] = r.colorVariance;
      d[k++] = r.edgeOrientation;
      for (var j = 0; j < 8; j++) {
        d[k++] = r.tonalHistogram[j];
      }
      o.setRange(i * 100, i * 100 + 100, r.subregionEdgeOrientations);
    }
    return PackedRegions._(n, d, o);
  }

  List<RegionAnalysis> unpack() {
    return List<RegionAnalysis>.generate(n, (i) {
      var k = i * _stride;
      final x = d[k++], y = d[k++], w = d[k++], h = d[k++];
      final rgb = RgbColor(d[k++], d[k++], d[k++]);
      final lab = LabColor(d[k++], d[k++], d[k++]);
      final detail = d[k++];
      final colors = List<LabColor>.generate(25, (_) {
        final c = LabColor(d[k], d[k + 1], d[k + 2]);
        k += 3;
        return c;
      }, growable: false);
      final edges = Float64List.fromList(Float64List.sublistView(d, k, k + 25));
      k += 25;
      final contrast = Float64List.fromList(
        Float64List.sublistView(d, k, k + 25),
      );
      k += 25;
      final balance = LuminanceBalance(d[k++], d[k++]);
      final variance = d[k++];
      final orientation = d[k++];
      final hist = Float64List.fromList(Float64List.sublistView(d, k, k + 8));
      return RegionAnalysis(
        x: x,
        y: y,
        width: w,
        height: h,
        averageColor: rgb,
        averageLabColor: lab,
        detailScore: detail,
        subregionColors: colors,
        subregionEdges: edges,
        contrastMap: contrast,
        luminanceBalance: balance,
        colorVariance: variance,
        edgeOrientation: orientation,
        tonalHistogram: hist,
        subregionEdgeOrientations: Float32List.fromList(
          Float32List.sublistView(o, i * 100, i * 100 + 100),
        ),
      );
    }, growable: false);
  }
}

/// Placements as flat data for a helper (see [PackedRegions]): the region part packed,
/// plus each placement's own fields.
class PackedPlacements {
  PackedPlacements._(
    this._regions,
    this._index,
    this._score,
    this._tileIds,
    this._tileNames,
    this._quads,
    this._faces,
  );

  final PackedRegions _regions;
  final Int32List _index;
  final Float64List _score;
  final List<String> _tileIds, _tileNames;
  final List<List<double>?> _quads;
  final List<String?> _faces;

  static PackedPlacements? pack(List<MosaicPlacement> ps) {
    final r = PackedRegions.pack(ps, 0, ps.length);
    if (r == null) return null;
    return PackedPlacements._(
      r,
      Int32List.fromList([for (final p in ps) p.index]),
      Float64List.fromList([for (final p in ps) p.score]),
      [for (final p in ps) p.tileId],
      [for (final p in ps) p.tileName],
      [for (final p in ps) p.quad],
      [for (final p in ps) p.face],
    );
  }

  List<MosaicPlacement> unpack() {
    final rs = _regions.unpack();
    return List<MosaicPlacement>.generate(rs.length, (i) {
      final r = rs[i];
      return MosaicPlacement(
        x: r.x,
        y: r.y,
        width: r.width,
        height: r.height,
        averageColor: r.averageColor,
        averageLabColor: r.averageLabColor,
        detailScore: r.detailScore,
        subregionColors: r.subregionColors,
        subregionEdges: r.subregionEdges,
        contrastMap: r.contrastMap,
        luminanceBalance: r.luminanceBalance,
        colorVariance: r.colorVariance,
        edgeOrientation: r.edgeOrientation,
        tonalHistogram: r.tonalHistogram,
        subregionEdgeOrientations: r.subregionEdgeOrientations,
        index: _index[i],
        tileId: _tileIds[i],
        tileName: _tileNames[i],
        score: _score[i],
        quad: _quads[i],
        face: _faces[i],
      );
    }, growable: true);
  }
}

/// Neighbour sets as two int arrays (each set's members in its own order).
class PackedAdjacency {
  PackedAdjacency(List<Set<int>> sets)
    : _start = Int32List(sets.length + 1),
      _items = Int32List(sets.fold<int>(0, (n, s) => n + s.length)) {
    var o = 0;
    for (var i = 0; i < sets.length; i++) {
      _start[i] = o;
      for (final j in sets[i]) {
        _items[o++] = j;
      }
    }
    _start[sets.length] = o;
  }

  final Int32List _start, _items;

  List<Set<int>> unpack() => [
    for (var i = 0; i < _start.length - 1; i++)
      {for (var k = _start[i]; k < _start[i + 1]; k++) _items[k]},
  ];
}
