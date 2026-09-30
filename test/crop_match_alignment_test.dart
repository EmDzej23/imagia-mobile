import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/matching.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// The scorer must judge a tile on the part of it that will be VISIBLE.
///
/// Square layout anchors a portrait tile to the TOP of the cell (it keeps faces), so the
/// bottom of a tall photo is thrown away at draw time. If the crop weights model a
/// centre crop instead, the matcher scores a band the viewer never sees and ignores the
/// band they do — picking tiles by their middle and showing their top.
void main() {
  /// A tall tile that is bright in exactly one 5x5 row and dark everywhere else.
  ///
  /// One row, not a half: the two crops differ ONLY at the outer rows, so a tile split
  /// down the middle scores almost the same under both and cannot tell them apart. An
  /// earlier version of this test did exactly that and proved nothing.
  TileDescriptor brightRow(String id, int row, double bright) {
    final colors = List<LabColor>.generate(
      25,
      (k) => LabColor(k ~/ 5 == row ? bright : 20.0, 0, 0),
    );
    return createTileDescriptor(
      id,
      id,
      90,
      160, // 9:16
      RgbColor(128, 128, 128),
      0.3,
      colors,
      List.filled(25, 0.2),
      List.filled(25, 0.2),
      LuminanceBalance(0, 0),
      0.1,
      0,
      List.filled(8, 0.125),
      Float32List(100),
    );
  }

  test('a top-anchored cell is matched on the tile top, not its middle', () {
    // Row 2 (the middle) is the boundary: it belongs to the BOTTOM half here, so a
    // centre-weighted scorer leans on it while a top-anchored draw discards most of it.
    const brightTop = 80.0, darkBottom = 20.0;

    final weightsCentre = computeCropWeights(90 / 160, 1.0, null, false)!;
    final weightsTop = computeCropWeights(90 / 160, 1.0, null, true)!;

    double rowSum(List<double> w, int r) {
      var t = 0.0;
      for (var c = 0; c < 5; c++) {
        t += w[r * 5 + c];
      }
      return t;
    }

    // Centre crop fades BOTH ends; a top anchor keeps the top intact and fades only the
    // bottom. This is the whole difference, stated as the invariant.
    expect(
      rowSum(weightsCentre, 0),
      lessThan(rowSum(weightsCentre, 2)),
      reason: 'centre crop must discount the top row',
    );
    expect(
      rowSum(weightsTop, 0),
      greaterThan(rowSum(weightsCentre, 0)),
      reason: 'a top anchor must NOT discount the top row',
    );
    expect(
      rowSum(weightsTop, 4),
      lessThan(rowSum(weightsTop, 0)),
      reason: 'a top anchor must discount the bottom row',
    );
    expect(
      rowSum(weightsTop, 0),
      closeTo(rowSum(subregionWeights.toList(), 0), 1e-9),
      reason: 'the visible top band must carry its full weight',
    );

    // And end to end. Two tiles, each bright in one row only:
    //   topLit    — bright at row 0, which a top anchor SHOWS and a centre crop discards
    //   bottomLit — bright at row 4, which a top anchor DISCARDS, and brighter still, so
    //               that under centre weights (where rows 0 and 4 are discounted
    //               equally) it is the better match.
    // Centre weights therefore pick bottomLit; only weights that model the top anchor
    // pick topLit — the one that will actually look bright once drawn.
    final tiles = [brightRow('topLit', 0, 80), brightRow('bottomLit', 4, 95)];
    final region = RegionAnalysis(
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      averageColor: RgbColor(200, 200, 200),
      averageLabColor: LabColor(60, 0, 0),
      detailScore: 0.3,
      subregionColors: List.filled(25, LabColor(60, 0, 0)),
      subregionEdges: List.filled(25, 0.2),
      contrastMap: List.filled(25, 0.2),
      luminanceBalance: LuminanceBalance(0, 0),
      colorVariance: 0.1,
      edgeOrientation: 0,
      tonalHistogram: List.filled(8, 0.125),
      subregionEdgeOrientations: Float32List(100),
    );

    final match = selectBestTileUniform(
      UniformMatchInput(
        region: region,
        resolved: preResolveTiles(tiles, 1.0, true),
        settings: defaultSettings()..mosaicMode = 'square',
        usageCounts: <String, int>{},
      ),
    );
    expect(
      match.tile.id,
      'topLit',
      reason:
          'square mode shows the TOP of a tall photo, so the tile that is bright '
          'at the top is the one that will actually look bright in the cell',
    );
  });
}
