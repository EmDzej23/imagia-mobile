import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/fine_placement.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/looks.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/tone_fit.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Parity with the web's fine placement (foto-mozaik lib/mosaic/fine-placement.ts). Fixture:
/// `npx tsx scripts/fine-placement-fidelity-gen.ts` in foto-mozaik.
void main() {
  final fx = jsonDecode(
    File('test/fixtures/fine_placement.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final b = fx['base'] as Map<String, dynamic>;
  ImageAnalyzer analyzer() => ImageAnalyzer.fromPixels(
    base64Decode(b['px'] as String),
    b['w'] as int,
    b['h'] as int,
    (b['w'] as int).toDouble(),
    (b['h'] as int).toDouble(),
  );
  final tiles = <TileDescriptor>[];
  for (final p in (fx['photos'] as List).cast<Map<String, dynamic>>()) {
    final w = p['w'] as int, h = p['h'] as int;
    final integral = buildIntegralImage(base64Decode(p['px'] as String), w, h);
    final r = sampleRegionFromIntegral(
      0, 0, w.toDouble(), h.toDouble(), w.toDouble(), h.toDouble(), integral,
    );
    tiles.add(createTileDescriptor(
      p['id'] as String, p['id'] as String, w.toDouble(), h.toDouble(),
      r.averageColor, r.detailScore, r.subregionColors, r.subregionEdges,
      r.contrastMap, r.luminanceBalance, r.colorVariance, r.edgeOrientation,
      r.tonalHistogram, r.subregionEdgeOrientations,
      fine: fineThumb(integral),
    ));
  }

  test('photo thumbnails match the web byte for byte', () {
    final photos = (fx['photos'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < photos.length; i++) {
      expect(tiles[i].fine, base64Decode(photos[i]['fine'] as String));
    }
  });

  test('the thumbnail survives the analysis cache', () {
    final back = TileDescriptor.fromJson(
      (jsonDecode(jsonEncode(tiles[3].toJson())) as Map).cast<String, dynamic>(),
    );
    expect(back.fine, tiles[3].fine);
  });

  for (final c in (fx['cases'] as List).cast<Map<String, dynamic>>()) {
    test('same photo in every cell as the web: ${c['name']}', () {
      final settings = sanitizeSettings(MosaicSettings.fromJson(
        (c['settings'] as Map).cast<String, dynamic>(),
      ));
      final crops = (c['settings'] as Map)['tileCrops'] as Map?;
      if (crops != null && crops.isNotEmpty) {
        settings.tileCrops = {
          for (final e in crops.entries)
            e.key as String: TileCrop.fromJson((e.value as Map).cast<String, dynamic>()),
        };
      }
      final base = analyzer();
      final seen = lookAnalyzer(
        toneFitAnalyzer(base, tiles, settings.fitLightToLibrary),
        settings.look,
      );
      final cells = (c['cells'] as List).cast<Map<String, dynamic>>();
      final ps = <MosaicPlacement>[];
      for (final q in cells) {
        final x = (q['x'] as num).toDouble(), y = (q['y'] as num).toDouble();
        final w = (q['w'] as num).toDouble(), h = (q['h'] as num).toDouble();
        final r = base.sampleRegion(x: x, y: y, width: w, height: h);
        ps.add(MosaicPlacement(
          x: x, y: y, width: w, height: h,
          averageColor: r.averageColor, averageLabColor: r.averageLabColor,
          detailScore: r.detailScore, subregionColors: r.subregionColors,
          subregionEdges: r.subregionEdges, contrastMap: r.contrastMap,
          luminanceBalance: r.luminanceBalance, colorVariance: r.colorVariance,
          edgeOrientation: r.edgeOrientation, tonalHistogram: r.tonalHistogram,
          subregionEdgeOrientations: r.subregionEdgeOrientations,
          index: ps.length, tileId: q['t'] as String, tileName: q['t'] as String,
          score: 0,
        ));
      }
      final f = seen.sampleFine(ps[3].x, ps[3].y, ps[3].width, ps[3].height, 6);
      final wf = (c['fine'] as List).cast<num>();
      for (var i = 0; i < f.length; i++) {
        expect(f[i], closeTo(wf[i].toDouble(), 1e-9));
      }
      final counts = <String, int>{};
      for (final p in ps) {
        counts[p.tileId] = (counts[p.tileId] ?? 0) + 1;
      }
      final res = refineFinePlacement(
        ps,
        lookTiles(tiles, settings.look),
        settings,
        (c['saliency'] as List).map((v) => (v as num).toDouble()).toList(),
        [for (final s in c['adjacency'] as List) (s as List).cast<int>().toSet()],
        c['radius'] as int,
        seen,
      );
      expect([for (final p in ps) p.tileId], (c['result'] as List).cast<String>());
      expect(res.swaps, c['swaps']);
      expect(res.grid, c['grid']);
      expect(res.before, closeTo((c['before'] as num).toDouble(), 1e-3));
      expect(res.after, closeTo((c['after'] as num).toDouble(), 1e-3));
      expect(res.after, lessThan(res.before));
      for (final p in ps) {
        counts[p.tileId] = counts[p.tileId]! - 1;
      }
      expect(counts.values.every((v) => v == 0), isTrue);
    });
  }

  test('runs inside the layout, keeps counts, and is skipped without thumbnails', () {
    List<String> build(List<TileDescriptor> t, bool on) => buildGridLayout(
      baseWidth: (b['w'] as int).toDouble(),
      baseHeight: (b['h'] as int).toDouble(),
      analyzer: analyzer(),
      tiles: t,
      settings: sanitizeSettings(MosaicSettings.fromJson({
        ...(fx['cases'][0]['settings'] as Map).cast<String, dynamic>(),
        'mosaicMode': 'square',
        'density': 60,
      })).copyWith(finePlacement: on),
    ).map((p) => p.tileId).toList();
    final off = build(tiles, false), on = build(tiles, true);
    expect(on, isNot(off));
    expect([...on]..sort(), [...off]..sort());
    final bare = [
      for (final t in tiles) TileDescriptor.fromJson(t.toJson()..remove('fine')),
    ];
    expect(build(bare, true), build(bare, false));
  });

  test('speed (information)', () {
    final r = math.Random(1);
    final many = [
      for (var i = 0; i < 300; i++)
        TileDescriptor.fromJson(tiles[(i * 5) % 30].toJson()..['id'] = 'm$i')
          ..fine = Uint8List.fromList(List.generate(3072, (_) => r.nextInt(256))),
    ];
    for (final n in [1500, 6000]) {
      final cols = math.sqrt(n * 1.5).round(), rows = n ~/ cols;
      final a = analyzer(), cw = 180 / cols, ch = 120 / rows;
      final ps = <MosaicPlacement>[];
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          final g = a.sampleRegion(x: x * cw, y: y * ch, width: cw, height: ch);
          ps.add(MosaicPlacement(
            x: x * cw, y: y * ch, width: cw, height: ch,
            averageColor: g.averageColor, averageLabColor: g.averageLabColor,
            detailScore: g.detailScore, subregionColors: g.subregionColors,
            subregionEdges: g.subregionEdges, contrastMap: g.contrastMap,
            luminanceBalance: g.luminanceBalance, colorVariance: g.colorVariance,
            edgeOrientation: g.edgeOrientation, tonalHistogram: g.tonalHistogram,
            subregionEdgeOrientations: g.subregionEdgeOrientations,
            index: ps.length, tileId: 'm${ps.length % 300}', tileName: 'm', score: 0,
          ));
        }
      }
      final sw = Stopwatch()..start();
      final res = refineFinePlacement(
        ps, many, sanitizeSettings(MosaicSettings.fromJson((fx['cases'][0]['settings'] as Map).cast<String, dynamic>())),
        List.filled(ps.length, 0.3), List.generate(ps.length, (_) => <int>{}), 2, a,
      );
      // ignore: avoid_print
      print('${ps.length} cells × 300 photos: ${sw.elapsedMilliseconds} ms, ${res.swaps} swaps, grid ${res.grid}');
    }
  });
}
