import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'types.dart';

/// Deterministic pseudo-random in [0, 1) from an int — used to scatter the
/// tile-reveal order so the mosaic "assembles" rather than wiping in.
double _hash01(int n) {
  var x = (n * 2654435761) & 0xFFFFFFFF;
  x ^= x >> 15;
  x = (x * 2246822519) & 0xFFFFFFFF;
  x ^= x >> 13;
  return (x & 0xFFFFFF) / 0x1000000;
}

/// Geometry of the "contain" fit used to place the mosaic inside a canvas.
typedef MosaicFit = ({double scale, double ox, double oy, double drawW, double drawH});

MosaicFit computeMosaicFit(Size size, double baseW, double baseH) {
  final sx = size.width / baseW;
  final sy = size.height / baseH;
  final s = sx < sy ? sx : sy;
  final drawW = baseW * s;
  final drawH = baseH * s;
  return (
    scale: s,
    ox: (size.width - drawW) / 2,
    oy: (size.height - drawH) / 2,
    drawW: drawW,
    drawH: drawH,
  );
}

/// Source rect that center-crops [img] to the target [cellAR] (w/h).
Rect centerCropSrc(ui.Image img, double cellAR) {
  final tw = img.width.toDouble();
  final th = img.height.toDouble();
  final tileAR = tw / th;
  if (tileAR > cellAR) {
    final srcW = th * cellAR;
    return Rect.fromLTWH((tw - srcW) / 2, 0, srcW, th);
  }
  final srcH = tw / cellAR;
  return Rect.fromLTWH(0, (th - srcH) / 2, tw, srcH);
}

/// Renders a [SlimMosaicPlan] on a canvas: each placement draws its matched
/// tile thumbnail, center-cropped to the cell's aspect ratio, with an optional
/// tinted overlay of the base image (the `tintStrength` setting).
class MosaicPreviewPainter extends CustomPainter {
  MosaicPreviewPainter({
    required this.plan,
    required this.tileImages,
    this.baseImage,
    double? tintStrength,
    this.appear = 1.0,
  }) : tintStrength = tintStrength ?? plan.tintStrength;

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;

  /// The tint overlay strength. Kept separate from [plan] so adjusting the tint
  /// slider repaints instantly without rebuilding the (matching) plan.
  final double tintStrength;

  /// Reveal progress 0→1. At 1 the steady-state fast path runs (no per-tile
  /// transform); below 1 tiles fade + scale + drift into place, staggered.
  final double appear;

  /// Fraction of the timeline a single tile's animation occupies.
  static const double _tileWindow = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (plan.baseWidth <= 0 || plan.baseHeight <= 0) return;
    final fit = computeMosaicFit(size, plan.baseWidth, plan.baseHeight);
    final s = fit.scale;
    final animating = appear < 1.0;

    canvas.save();
    canvas.translate(fit.ox, fit.oy);

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;

    var i = -1;
    for (final p in plan.placements) {
      i++;
      final dst = Rect.fromLTWH(p.x * s, p.y * s, p.width * s, p.height * s);

      var drawRect = dst;
      double opacity = 1;
      if (animating) {
        final start = _hash01(i) * (1 - _tileWindow);
        final lt = ((appear - start) / _tileWindow).clamp(0.0, 1.0);
        if (lt <= 0) continue; // not yet revealed
        final e = Curves.easeOutCubic.transform(lt);
        opacity = e;
        final scale = 0.55 + 0.45 * e;
        final ang = _hash01(i * 2 + 1) * 2 * math.pi;
        final dist = (1 - e) * dst.width * 1.3;
        drawRect = Rect.fromCenter(
          center: dst.center.translate(
              math.cos(ang) * dist, math.sin(ang) * dist),
          width: dst.width * scale,
          height: dst.height * scale,
        );
      }

      final img = tileImages[p.tileId];
      if (img == null) {
        final c = p.regionAvgColor;
        if (c != null) {
          canvas.drawRect(
              drawRect,
              Paint()
                ..color = Color.fromRGBO(c[0].round(), c[1].round(),
                    c[2].round(), opacity));
        }
        continue;
      }
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
      canvas.drawImageRect(
          img, centerCropSrc(img, p.width / p.height), drawRect, paint);
    }

    if (baseImage != null && tintStrength > 0) {
      final src = Rect.fromLTWH(
          0, 0, baseImage!.width.toDouble(), baseImage!.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, fit.drawW, fit.drawH);
      // Fade the tint in alongside the reveal so the picture resolves last.
      final tintAlpha = tintStrength.toDouble() * appear;
      canvas.drawImageRect(
        baseImage!,
        src,
        dst,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, tintAlpha)
          ..filterQuality = FilterQuality.high,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MosaicPreviewPainter old) =>
      old.plan != plan ||
      old.baseImage != baseImage ||
      old.tintStrength != tintStrength ||
      old.appear != appear ||
      old.tileImages.length != tileImages.length;
}

/// Draws a magnified window of the mosaic centered on a base-image point —
/// the "loupe" popup. [windowSize] is the side (in base px) of the square
/// region shown; smaller = more zoomed in.
class MosaicZoomPainter extends CustomPainter {
  MosaicZoomPainter({
    required this.plan,
    required this.tileImages,
    required this.focusX,
    required this.focusY,
    required this.windowSize,
    this.baseImage,
    this.tintStrength = 0,
  });

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;
  final double focusX;
  final double focusY;
  final double windowSize;
  final double tintStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / windowSize; // square popup
    final ox = size.width / 2 - focusX * s;
    final oy = size.height / 2 - focusY * s;

    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = false;

    for (final p in plan.placements) {
      final dx = p.x * s + ox;
      final dy = p.y * s + oy;
      final dw = p.width * s;
      final dh = p.height * s;
      if (dx + dw < 0 || dy + dh < 0 || dx > size.width || dy > size.height) {
        continue; // cull off-window cells
      }
      final dst = Rect.fromLTWH(dx, dy, dw, dh);
      final img = tileImages[p.tileId];
      if (img == null) {
        final c = p.regionAvgColor;
        if (c != null) {
          canvas.drawRect(
              dst,
              Paint()
                ..color = Color.fromRGBO(
                    c[0].round(), c[1].round(), c[2].round(), 1));
        }
        continue;
      }
      canvas.drawImageRect(img, centerCropSrc(img, p.width / p.height), dst, paint);
    }

    if (baseImage != null && tintStrength > 0) {
      final src = Rect.fromLTWH(
          0, 0, baseImage!.width.toDouble(), baseImage!.height.toDouble());
      final dst =
          Rect.fromLTWH(ox, oy, plan.baseWidth * s, plan.baseHeight * s);
      canvas.drawImageRect(
        baseImage!,
        src,
        dst,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, tintStrength.toDouble())
          ..filterQuality = FilterQuality.high,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MosaicZoomPainter old) =>
      old.plan != plan ||
      old.focusX != focusX ||
      old.focusY != focusY ||
      old.windowSize != windowSize ||
      old.tintStrength != tintStrength;
}
