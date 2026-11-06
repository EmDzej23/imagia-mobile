import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/collage/collage_renderer.dart';

/// The Dart planPile must lay the SAME pile as the web's (fixture generated from
/// foto-mozaik/lib/collage/collage-renderer.ts by scripts/collage-fidelity-gen.ts),
/// so a collage looks the same in the app and on the web.
void main() {
  test('drawPile paints a pile (whole, cut-outs, outline, shadow)', () async {
    Future<ui.Image> solid(int w, int h, Color c, {bool round = false}) async {
      final rec = ui.PictureRecorder();
      final cv = Canvas(rec);
      final r = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      if (round) {
        cv.drawOval(r, Paint()..color = c);
      } else {
        cv.drawRect(r, Paint()..color = c);
      }
      return rec.endRecording().toImage(w, h);
    }

    final pieces = <PilePiece>[];
    for (var i = 0; i < 14; i++) {
      final cut = i % 4 == 0;
      final aspect = [0.7, 1.4, 1.0, 2.6][i % 4];
      final img = await solid((60 * aspect).round(), 60,
          Color.fromARGB(255, 40 + i * 12, 200 - i * 9, 90), round: cut);
      pieces.add(PilePiece(
        id: 'p$i',
        kind: cut ? 'cutout' : 'full',
        image: img,
        aspect: aspect,
        hero: i == 2,
        keep: cut ? null : [0.3, 0.25, 0.7, 0.65],
        mask: cut ? await buildPieceMask(img) : null,
      ));
    }
    const params = PileParams(
        format: 'square', rotation: 14, outline: 0.6, shadow: 0.7, background: '#f4d23c', seedNonce: 1);
    final size = formatSize(params.format, 300);
    final placements = planPile(pieces, size.w, size.h, params);
    expect(placements.length, pieces.length);
    final rec = ui.PictureRecorder();
    drawPile(Canvas(rec), pieces, placements, params, size.w, size.h);
    final out = await rec.endRecording().toImage(size.w.toInt(), size.h.toInt());
    final bd = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    // Count pixels still showing the yellow background — the pile covers the print.
    var bg = 0;
    for (var i = 0; i < bd.lengthInBytes; i += 4) {
      if (bd.getUint8(i) == 0xf4 && bd.getUint8(i + 1) == 0xd2 && bd.getUint8(i + 2) == 0x3c) bg++;
    }
    expect(bg / (bd.lengthInBytes / 4), lessThan(0.08));
    final plan = collagePlanJson(placements: placements, params: params);
    expect(plan['version'], 2);
    expect((plan['placements'] as List).length, pieces.length);
  });

  test('planPile reproduces the web layout', () async {
    final fx = jsonDecode(File('test/fixtures/collage_plan.json').readAsStringSync())
        as Map<String, dynamic>;
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint());
    final img = await rec.endRecording().toImage(4, 4);
    final pieces = [
      for (final p in (fx['pieces'] as List).cast<Map<String, dynamic>>())
        PilePiece(
          id: p['id'] as String,
          kind: p['kind'] as String,
          image: img,
          aspect: (p['aspect'] as num).toDouble(),
          hero: p['hero'] == true,
          keep: (p['keep'] as List?)?.map((v) => (v as num).toDouble()).toList(),
          mask: p['mask'] == null
              ? null
              : PieceMask(
                  (p['mask']['w'] as num).toInt(),
                  (p['mask']['h'] as num).toInt(),
                  Uint8List.fromList((p['mask']['data'] as List).cast<int>())),
        ),
    ];
    for (final c in (fx['cases'] as List).cast<Map<String, dynamic>>()) {
      final pr = c['params'] as Map<String, dynamic>;
      final params = PileParams(
        format: pr['format'] as String,
        rotation: (pr['rotation'] as num).toDouble(),
        outline: (pr['outline'] as num).toDouble(),
        shadow: (pr['shadow'] as num).toDouble(),
        background: pr['background'] as String,
        seedNonce: (pr['seedNonce'] as num).toInt(),
      );
      final W = (c['W'] as num).toDouble(), H = (c['H'] as num).toDouble();
      final size = formatSize(params.format);
      expect(size.w, W);
      expect(size.h, H);
      final got = planPile(pieces, W, H, params);
      final want = (c['placements'] as List).cast<Map<String, dynamic>>();
      expect(got.length, want.length);
      for (var i = 0; i < want.length; i++) {
        final w = want[i], g = got[i];
        expect(g.tileId, w['tileId'], reason: '${params.format} #$i id');
        expect(g.kind, w['kind']);
        for (final k in ['cx', 'cy', 'w', 'h', 'angle']) {
          final gv = switch (k) { 'cx' => g.cx, 'cy' => g.cy, 'w' => g.w, 'h' => g.h, _ => g.angle };
          expect(gv, closeTo((w[k] as num).toDouble(), 1e-6), reason: '${params.format} #$i $k');
        }
        final wc = w['crop'] as List?;
        expect(g.crop == null, wc == null, reason: 'crop presence #$i');
      }
    }
  });
}
