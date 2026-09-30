import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/analyze.dart';
import 'package:imagia_mobile/mosaic/grid_layout.dart';
import 'package:imagia_mobile/mosaic/shared.dart';
import 'package:imagia_mobile/mosaic/types.dart';

/// Cells must tile the picture: no two overlap, none escapes the canvas.
///
/// This is the invariant behind "some tiles look out of place". Every quality metric
/// can look fine while the geometry is broken — a mosaic made of overlapping cells
/// still scores well on colour, because the score never asks where the cells ARE.
void main() {
  const w = 900.0, h = 1200.0; // portrait base, like a phone selfie

  ImageAnalyzer makeAnalyzer() {
    final px = Uint8List(w.toInt() * h.toInt() * 4);
    for (var y = 0; y < h.toInt(); y++) {
      for (var x = 0; x < w.toInt(); x++) {
        final o = (y * w.toInt() + x) * 4;
        px[o] = x * 255 ~/ w.toInt();
        px[o + 1] = y * 255 ~/ h.toInt();
        px[o + 2] = ((x + y) % 255);
        px[o + 3] = 255;
      }
    }
    return ImageAnalyzer.fromPixels(px, w.toInt(), h.toInt(), w, h);
  }

  TileDescriptor tile(String id, double ar) => createTileDescriptor(
    id,
    id,
    100,
    100 / ar,
    RgbColor(128, 128, 128),
    0.5,
    List.filled(25, LabColor(55, 5, -5)),
    List.filled(25, 0.2),
    List.filled(25, 0.3),
    LuminanceBalance(0, 0),
    0.2,
    0,
    List.filled(8, 0.125),
    Float32List(100),
  );

  List<TileDescriptor> lib(Map<double, int> spec) {
    final out = <TileDescriptor>[];
    var i = 0;
    spec.forEach((ar, n) {
      for (var k = 0; k < n; k++) out.add(tile('t${i++}', ar));
    });
    return out;
  }

  // The reported library: 57 photos spread across video and photo aspects, which is
  // the case that drops `dominantCellAspect` to its square fallback.
  final diverse57 = lib({16 / 9: 14, 9 / 16: 14, 4 / 3: 15, 3 / 4: 14});
  final phone57 = lib({4 / 3: 30, 3 / 4: 22, 16 / 9: 5});
  final landscape200 = lib({3 / 2: 200});

  final libs = {
    'diverse 57': diverse57,
    'phone 57': phone57,
    'landscape 200': landscape200,
  };

  test('a tall-phone library gets tall cells, not square ones', () {
    // The reported defect, read off a real debug log: 57 photos, ~55 of them tall
    // portrait, and the grid chose SQUARE cells — for a library with no square photo in
    // it. Every 1x1 cell (78% of that mosaic) then centre-cropped a tall photo to fit,
    // which is what "these tiles are square and none of my photos are" was.
    //
    // Cause: the cell-aspect candidate list stopped at 2:3, and a 9:16 photo is 17%
    // away from it — outside the 15% tolerance — so it agreed with no candidate at all
    // and the chooser fell through to its square default.
    final tall = [
      ...List.generate(55, (i) => tile('t$i', 9 / 16)),
      ...List.generate(2, (i) => tile('w$i', 3 / 2)),
    ];
    final placements = buildGridLayout(
      baseWidth: w,
      baseHeight: h,
      analyzer: makeAnalyzer(),
      tiles: tall,
      settings: defaultSettings()
        ..mosaicMode = 'original'
        ..density = 150,
    );
    expect(placements, isNotEmpty);

    // The BASE cell, taken as the most common footprint, must be tall.
    var cellMin = double.infinity;
    for (final p in placements) {
      cellMin = math.min(cellMin, p.width * p.height);
    }
    var arSum = 0.0, n = 0;
    for (final p in placements) {
      if (p.width * p.height >= cellMin * 1.3) continue;
      arSum += p.width / p.height;
      n++;
    }
    final baseAR = arSum / n;
    expect(
      baseAR,
      lessThan(0.8),
      reason: 'base cell aspect $baseAR — a tall library must not get square cells',
    );
  });

  test('original delivers the cell count the density asked for', () {
    // The reported defect. `original` merges cells into bigger shapes, and how much it
    // merges depends on how many multi-cell shapes the library can fill — which is not
    // a constant, though the density→grid mapping assumes one. A library whose aspects
    // spread evenly gets square cells, where nearly the whole shape menu survives, and
    // the mosaic came out at HALF the requested detail: every photo covering twice the
    // intended area, which is what "tiles look out of place" actually was.
    //
    // Measured against the phone library, which is not short, so this fails if the
    // re-grid either stops working or starts firing on libraries that were fine.
    final counts = <String, int>{};
    for (final entry in {'diverse 57': diverse57, 'phone 57': phone57}.entries) {
      counts[entry.key] = buildGridLayout(
        baseWidth: w,
        baseHeight: h,
        analyzer: makeAnalyzer(),
        tiles: entry.value,
        settings: defaultSettings()
          ..mosaicMode = 'original'
          ..density = 150,
      ).length;
    }
    final diverse = counts['diverse 57']!;
    final phone = counts['phone 57']!;
    // Within a third of each other. They will never match exactly — the shape menus
    // differ — but a 2x gap means one of them is not honouring the density at all.
    expect(
      diverse,
      greaterThan((phone * 0.66).round()),
      reason:
          'diverse library delivered $diverse cells vs $phone for phone — '
          'the density is being merged away',
    );
  });

  for (final mode in ['original', 'square', 'blocks', 'landscape', 'portrait']) {
    for (final entry in libs.entries) {
      test('$mode · ${entry.key} · cells tile the picture', () {
        final placements = buildGridLayout(
          baseWidth: w,
          baseHeight: h,
          analyzer: makeAnalyzer(),
          tiles: entry.value,
          settings: defaultSettings()
            ..mosaicMode = mode
            ..density = 120,
        );
        expect(placements, isNotEmpty);

        const eps = 0.01;
        for (final p in placements) {
          expect(p.width > 0 && p.height > 0, isTrue, reason: 'degenerate cell $p');
          expect(
            p.x >= -eps && p.y >= -eps,
            isTrue,
            reason: 'cell starts outside the canvas at (${p.x}, ${p.y})',
          );
          expect(
            p.x + p.width <= w + eps && p.y + p.height <= h + eps,
            isTrue,
            reason:
                'cell runs past the canvas: '
                '(${p.x}, ${p.y}) ${p.width}x${p.height} on ${w}x$h',
          );
        }

        // Pairwise overlap, swept by row so this stays near-linear.
        final byY = [...placements]
          ..sort((a, b) {
            final c = a.y.compareTo(b.y);
            return c != 0 ? c : a.x.compareTo(b.x);
          });
        var overlaps = 0;
        String? first;
        for (var i = 0; i < byY.length; i++) {
          final a = byY[i];
          for (var j = i + 1; j < byY.length && byY[j].y < a.y + a.height - eps; j++) {
            final b = byY[j];
            if (b.x < a.x + a.width - eps && b.x + b.width > a.x + eps) {
              overlaps++;
              first ??=
                  '(${a.x},${a.y} ${a.width}x${a.height}) vs '
                  '(${b.x},${b.y} ${b.width}x${b.height})';
            }
          }
        }
        expect(overlaps, 0, reason: '$overlaps overlapping cells, first: $first');
      });
    }
  }
}
