import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Displays a rendered [ui.Image] (fit: contain) with a tap-to-zoom loupe — the
/// tile-less equivalent of the photo-mosaic loupe (ancient + word-art previews).
/// Tapping opens a draggable magnified window centred on the tapped point.
class LoupePreviewImage extends StatelessWidget {
  const LoupePreviewImage({super.key, required this.image});

  final ui.Image image;

  void _openLoupe(BuildContext context, double fx0, double fy0) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    // Window shows ~1/4.5 of the long side ⇒ roughly 4.5× the fitted preview.
    final cropSize = math.max(24.0, math.max(imgW, imgH) / 4.5);

    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        final side =
            (MediaQuery.of(ctx).size.width.clamp(0, 360) * 0.9).toDouble();
        double fx = fx0, fy = fy0;
        return GestureDetector(
          onTap: () => Navigator.pop(ctx), // tap outside closes
          child: Center(
            child: StatefulBuilder(
              builder: (ctx, setLoupe) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      final s = side / cropSize; // screen px per image px
                      setLoupe(() {
                        fx = (fx - d.delta.dx / s).clamp(0.0, imgW);
                        fy = (fy - d.delta.dy / s).clamp(0.0, imgH);
                      });
                    },
                    child: Container(
                      width: side,
                      height: side,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(
                            color: AppColors.primaryBright, width: 2),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CustomPaint(
                        painter: _ImageZoomPainter(
                            image: image,
                            focusX: fx,
                            focusY: fy,
                            cropSize: cropSize),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  Text('Drag to explore', style: AppTypography.caption),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth, boxH = constraints.maxHeight;
        // Map a tap in the box to image pixel coords (image is fit: contain).
        final scale = math.min(boxW / imgW, boxH / imgH);
        final ox = (boxW - imgW * scale) / 2, oy = (boxH - imgH * scale) / 2;
        return GestureDetector(
          onTapUp: (d) {
            final ix = (d.localPosition.dx - ox) / scale;
            final iy = (d.localPosition.dy - oy) / scale;
            if (ix < 0 || iy < 0 || ix > imgW || iy > imgH) return;
            _openLoupe(context, ix, iy);
          },
          child: SizedBox.expand(
            child: RawImage(image: image, fit: BoxFit.contain),
          ),
        );
      },
    );
  }
}

class _ImageZoomPainter extends CustomPainter {
  _ImageZoomPainter({
    required this.image,
    required this.focusX,
    required this.focusY,
    required this.cropSize,
  });

  final ui.Image image;
  final double focusX, focusY, cropSize;

  @override
  void paint(Canvas canvas, Size size) {
    final half = cropSize / 2;
    final src = Rect.fromLTWH(focusX - half, focusY - half, cropSize, cropSize);
    final dst = Offset.zero & size;
    canvas.drawRect(dst, Paint()..color = AppColors.background);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_ImageZoomPainter old) =>
      old.focusX != focusX ||
      old.focusY != focusY ||
      old.image != image ||
      old.cropSize != cropSize;
}
