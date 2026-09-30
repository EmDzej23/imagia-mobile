import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// The "use every photo equally often" switch.
///
/// The failure this guards against is not a crash — it is the cap INVERTING. Every
/// scorer here skips a photo that has hit its ceiling and then needs something to fall
/// back on; fall back to "the first candidate" and every exhausted cell picks the same
/// globally-cheapest photo, so switching the cap on makes the mosaic *more* repetitive
/// than leaving it off. On the web that shipped as one photo filling 247 cells under a
/// cap of 9. Nothing in the type system or the analyzer can see it, and the plan still
/// looks perfectly well-formed — only counting uses catches it.
void main() {
  const w = 640.0, h = 480.0;

  ImageAnalyzer makeAnalyzer() {
    final px = Uint8List(w.toInt() * h.toInt() * 4);
    for (var y = 0; y < h.toInt(); y++) {
      for (var x = 0; x < w.toInt(); x++) {
        final o = (y * w.toInt() + x) * 4;
        px[o] = (x * 255 ~/ w.toInt());
        px[o + 1] = (y * 255 ~/ h.toInt());
        px[o + 2] = 128;
        px[o + 3] = 255;
      }
    }
    return ImageAnalyzer.fromPixels(px, w.toInt(), h.toInt(), w, h);
  }

  List<TileDescriptor> makeTiles(int n) => List.generate(n, (i) {
    final t = i / n;
    return createTileDescriptor(
      't$i',
      't$i',
      100,
      i.isEven ? 75 : 133,
      RgbColor(255 * t, 255 * (1 - t), 128),
      0.5,
      List.filled(25, LabColor(60 * t, 10, -10)),
      List.filled(25, 0.2),
      List.filled(25, 0.3),
      LuminanceBalance(0, 0),
      0.2,
      0,
      List.filled(8, 0.125),
      Float32List(100),
    );
  });

  /// Cells held by the single most-used photo.
  int worstReuse(List<MosaicPlacement> placements) {
    final counts = <String, int>{};
    for (final p in placements) {
      final id = getBaseTileId(p.tileId);
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts.values.fold(0, (a, b) => a > b ? a : b);
  }

  List<MosaicPlacement> build({required int maxTileUses}) => buildGridLayout(
    baseWidth: w,
    baseHeight: h,
    analyzer: makeAnalyzer(),
    tiles: makeTiles(60),
    settings: defaultSettings()
      ..mosaicMode = 'original'
      ..density = 120
      ..maxTileUses = maxTileUses,
  );

  test('the even switch reduces reuse instead of concentrating it', () {
    final off = build(maxTileUses: 0);
    final on = build(maxTileUses: evenTileUses);

    expect(off, isNotEmpty);
    expect(on, isNotEmpty);

    final offWorst = worstReuse(off);
    final onWorst = worstReuse(on);

    // The whole point of the switch. A regression in the at-capacity fallback shows up
    // here as onWorst climbing far ABOVE offWorst.
    expect(
      onWorst,
      lessThan(offWorst),
      reason:
          'switching the cap on must spread the library, not concentrate it '
          '(off=$offWorst on=$onWorst)',
    );

    // And it should land near the arithmetic floor. Some overshoot is expected and
    // accepted: each cell only sees its top-80 candidates, so a cell whose best 80 are
    // all spent takes the least-used one and can step over. Pinning it exactly costs
    // more accuracy than it is worth — see the note on K in _vogelAssign.
    final floor = minFeasibleTileUses(60, on.length);
    expect(
      onWorst,
      lessThanOrEqualTo(floor * 3),
      reason: 'cap floor=$floor but worst photo holds $onWorst cells',
    );
  });

  test('the switch does not move a single cell', () {
    // The regression that made this test file necessary a second time.
    //
    // Cell shapes are chosen by COMPARING scores — one photo across four cells versus
    // four photos in them. A reuse cap makes those scores incomparable, and unevenly:
    // 1x1 draws from the whole library while multi-cell shapes draw from narrow
    // orientation pools, so the cap starves the big shapes first and 1x1 wins every
    // comparison. A setting about repeats silently rebuilt `original` as a field of
    // small squares, and every metric this file measured stayed green while it did.
    //
    // Geometry must be byte-identical with the cap on or off. Only which photo lands
    // in each cell may change.
    final off = build(maxTileUses: 0);
    final on = build(maxTileUses: evenTileUses);

    expect(
      on.length,
      off.length,
      reason: 'cell COUNT changed: ${off.length} → ${on.length}',
    );
    for (var i = 0; i < off.length; i++) {
      expect(
        [on[i].x, on[i].y, on[i].width, on[i].height],
        [off[i].x, off[i].y, off[i].width, off[i].height],
        reason: 'cell $i moved or resized',
      );
    }
  });

  test('the switch off changes nothing', () {
    final a = build(maxTileUses: 0);
    final b = build(maxTileUses: 0);
    expect(
      a.map((p) => p.tileId).toList(),
      b.map((p) => p.tileId).toList(),
      reason: 'unlimited must stay the deterministic path it always was',
    );
  });
}
