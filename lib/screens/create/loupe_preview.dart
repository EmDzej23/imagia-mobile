import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Renders one square crop of the picture at [outPx]×[outPx] device pixels.
/// [crop] is in the preview image's own pixel space.
typedef LoupeCropRenderer = Future<ui.Image> Function(ui.Rect crop, int outPx);

/// Displays a rendered [ui.Image] (fit: contain) with a tap-to-zoom loupe — the
/// tile-less equivalent of the photo-mosaic loupe (ancient + word-art previews).
/// Tapping opens a draggable magnified window centred on the tapped point.
class LoupePreviewImage extends StatelessWidget {
  const LoupePreviewImage({super.key, required this.image, this.cropRenderer});

  final ui.Image image;

  /// When given, the loupe re-renders the framed region at the screen's real
  /// resolution instead of magnifying [image]. The preview raster is ~1400 px on its
  /// long side and the window shows about a quarter of that blown up to a full-width
  /// square, so magnifying it is a ~3x upscale — which is why the zoom looked soft.
  /// Re-rendering asks the resolution-independent geometry for those pixels instead.
  ///
  /// Optional so the widget still works for any caller that only has a bitmap.
  final LoupeCropRenderer? cropRenderer;

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
        return GestureDetector(
          onTap: () => Navigator.pop(ctx), // tap outside closes
          child: Center(
            child: _LoupeWindow(
              image: image,
              cropRenderer: cropRenderer,
              side: side,
              cropSize: cropSize,
              imgW: imgW,
              imgH: imgH,
              startX: fx0,
              startY: fy0,
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


/// The magnified window itself.
///
/// Owns the focus point and, when a [LoupeCropRenderer] is supplied, the sharp image
/// rendered for the current position. Split out of the dialog closure so the rendered
/// crops get DISPOSED — a StatefulBuilder has no teardown hook, and each of these is a
/// full-window RGBA buffer.
class _LoupeWindow extends StatefulWidget {
  const _LoupeWindow({
    required this.image,
    required this.cropRenderer,
    required this.side,
    required this.cropSize,
    required this.imgW,
    required this.imgH,
    required this.startX,
    required this.startY,
  });

  final ui.Image image;
  final LoupeCropRenderer? cropRenderer;
  final double side, cropSize, imgW, imgH, startX, startY;

  @override
  State<_LoupeWindow> createState() => _LoupeWindowState();
}

class _LoupeWindowState extends State<_LoupeWindow> {
  late double _fx = widget.startX;
  late double _fy = widget.startY;

  /// Sharp render for the CURRENT focus, or null while none is ready.
  ui.Image? _sharp;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _requestSharp();
  }

  @override
  void dispose() {
    _sharp?.dispose();
    super.dispose();
  }

  Future<void> _requestSharp() async {
    final render = widget.cropRenderer;
    if (render == null) return;
    final token = ++_token;
    final half = widget.cropSize / 2;
    final crop = ui.Rect.fromLTWH(
        _fx - half, _fy - half, widget.cropSize, widget.cropSize);
    // Ask for the window at its true device resolution — that, and not the zoom
    // factor, is how many pixels actually reach the screen.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final outPx = (widget.side * dpr).round().clamp(64, 2048);
    try {
      final img = await render(crop, outPx);
      // A newer request (or a closed dialog) won: throw this one away rather than
      // showing a crop for a position the user has already dragged away from.
      if (!mounted || token != _token) {
        img.dispose();
        return;
      }
      setState(() {
        _sharp?.dispose();
        _sharp = img;
      });
    } catch (_) {
      // Fall back to magnifying the preview bitmap — a soft loupe beats none.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            final s = widget.side / widget.cropSize; // screen px per image px
            setState(() {
              _fx = (_fx - d.delta.dx / s).clamp(0.0, widget.imgW);
              _fy = (_fy - d.delta.dy / s).clamp(0.0, widget.imgH);
              // The sharp crop belongs to the old position; drop it so the window
              // shows the (fast) magnified bitmap while the finger is down.
              _token++;
              _sharp?.dispose();
              _sharp = null;
            });
          },
          // Re-render once the drag settles, not on every frame: each render is a
          // full repaint of the geometry and would make panning stutter.
          onPanEnd: (_) => _requestSharp(),
          child: Container(
            width: widget.side,
            height: widget.side,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.primaryBright, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: _sharp != null
                ? RawImage(image: _sharp, fit: BoxFit.fill)
                : CustomPaint(
                    painter: _ImageZoomPainter(
                      image: widget.image,
                      focusX: _fx,
                      focusY: _fy,
                      cropSize: widget.cropSize,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Text('Drag to explore', style: AppTypography.caption),
      ],
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
