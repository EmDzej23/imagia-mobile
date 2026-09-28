import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/ancient/ancient_renderer.dart';

/// The loupe used to MAGNIFY the finished preview bitmap, so zooming showed
/// preview-resolution pixels blown up ~3x. `renderAncientCrop` re-paints the same
/// vector geometry through a scaled canvas instead, so the stone edges are rasterised
/// at the device resolution.
///
/// Measuring "sharp" as mean SQUARED neighbour difference. The obvious metric — mean
/// absolute gradient — cannot see blur at all: spreading an edge of height S over three
/// pixels still sums to S, so it scored the two paths within 1% of each other. Squaring
/// separates them, because one hard step contributes S² where a three-pixel ramp
/// contributes only S²/3. Same picture, same framing; the only difference is whether
/// the pixels were interpolated or drawn.
void main() {
  const int previewLong = 1400; // matches _previewLong in the previews
  const int windowPx = 972; // ~324pt loupe window at devicePixelRatio 3

  /// A base photo with real structure, so stones take varied colours.
  Uint8List syntheticBase(int w, int h) {
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final r = math.sqrt(math.pow((x - w / 2) / w, 2) + math.pow((y - h / 2) / h, 2));
        px[o] = (255 * (1 - r)).clamp(0, 255).toInt();
        px[o + 1] = (200 * (x / w)).clamp(0, 255).toInt();
        px[o + 2] = (200 * (y / h)).clamp(0, 255).toInt();
        px[o + 3] = 255;
      }
    }
    return px;
  }

  /// Mean squared luminance step between horizontally adjacent pixels.
  Future<double> edgeEnergy(ui.Image img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final b = data!.buffer.asUint8List();
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y < img.height; y++) {
      for (var x = 1; x < img.width; x++) {
        final i = (y * img.width + x) * 4;
        final j = (y * img.width + (x - 1)) * 4;
        final l1 = 0.2126 * b[i] + 0.7152 * b[i + 1] + 0.0722 * b[i + 2];
        final l0 = 0.2126 * b[j] + 0.7152 * b[j + 1] + 0.0722 * b[j + 2];
        final d = l1 - l0;
        sum += d * d;
        n++;
      }
    }
    return sum / n;
  }

  test('loupe crop is sharper than magnifying the preview raster', () async {
    const sw = 700, sh = 700;
    final rgba = syntheticBase(sw, sh);
    const params = AncientParams(
      stoneSize: 14,
      grout: 1.4,
      irregularity: 0.85,
      variation: 0.12,
      bevel: 0.35,
      groutColor: 'dark',
    );

    final geo = buildAncientGeometry(
        rgba, sw, sh, previewLong.toDouble(), previewLong.toDouble(), params);
    expect(geo.stones, isNotEmpty, reason: 'nothing to compare if no stones');

    // The window the loupe frames: ~1/4.5 of the long side, centred.
    const cropSize = previewLong / 4.5;
    const crop = Rect.fromLTWH(
        (previewLong - cropSize) / 2, (previewLong - cropSize) / 2, cropSize, cropSize);

    // OLD PATH: render the preview once, then blow the crop up to the window.
    final preview = await renderAncientImage(geo, previewLong, previewLong);
    final recorder = ui.PictureRecorder();
    const windowRect = Rect.fromLTWH(0, 0, windowPx * 1.0, windowPx * 1.0);
    final canvas = Canvas(recorder, windowRect);
    canvas.drawImageRect(
      preview,
      crop,
      windowRect,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
    final magnified = await recorder.endRecording().toImage(windowPx, windowPx);

    // NEW PATH: paint the same crop straight from geometry at window resolution.
    final sharp = await renderAncientCrop(
        geo, previewLong, previewLong, crop, windowPx, windowPx);

    final before = await edgeEnergy(magnified);
    final after = await edgeEnergy(sharp);
    // ignore: avoid_print
    print('edge energy  magnified=${before.toStringAsFixed(2)}  '
        'native=${after.toStringAsFixed(2)}  (+${((after / before - 1) * 100).toStringAsFixed(0)}%)');

    expect(after, greaterThan(before * 1.5),
        reason: 'native crop should carry clearly harder edges than a 3x upscale');

    preview.dispose();
    magnified.dispose();
    sharp.dispose();
  });
}
