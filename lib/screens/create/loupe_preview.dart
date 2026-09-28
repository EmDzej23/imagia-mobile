import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Renders one region of the picture at [outW]x[outH] device pixels.
/// [crop] is in the preview image's own pixel space.
typedef LoupeCropRenderer = Future<ui.Image> Function(
    ui.Rect crop, int outW, int outH);

/// Displays a rendered [ui.Image] with pinch-to-zoom and drag-to-pan.
///
/// The tile-less counterpart of the photo-mosaic preview: same gestures, so every mode
/// in the studio behaves the same way. There is no tap-to-open magnifier — the picture
/// itself zooms.
///
/// Zoom stays SHARP rather than magnifying the preview bitmap. The preview raster is
/// ~1400 px on its long side, so at any real zoom it would be upscaled several times
/// over; instead the visible region is re-rendered from the resolution-independent
/// geometry through [cropRenderer]. The bitmap is still drawn while a gesture is in
/// flight, because re-rendering every frame would stutter — so a pinch reads as
/// slightly soft and then snaps sharp when the fingers lift.
class LoupePreviewImage extends StatefulWidget {
  const LoupePreviewImage({
    super.key,
    required this.image,
    this.cropRenderer,
  });

  final ui.Image image;

  /// Optional so the widget still works for a caller that only has a bitmap; without
  /// it the zoom simply magnifies [image].
  final LoupeCropRenderer? cropRenderer;

  @override
  State<LoupePreviewImage> createState() => _LoupePreviewImageState();
}

class _LoupePreviewImageState extends State<LoupePreviewImage> {
  /// 1 = the whole picture, fitted. Above that the visible window shrinks.
  double _zoom = 1;
  double _zoomAtGestureStart = 1;

  /// Centre of the visible window in IMAGE pixels; null = centred.
  Offset? _focus;

  /// Sharp re-render for the current window, or null when none is ready.
  ui.Image? _sharp;
  int _token = 0;

  static const double _maxZoom = 40;

  double get _imgW => widget.image.width.toDouble();
  double get _imgH => widget.image.height.toDouble();

  @override
  void didUpdateWidget(LoupePreviewImage old) {
    super.didUpdateWidget(old);
    // A new render (settings changed) invalidates the sharp crop — it belongs to the
    // previous picture and would otherwise linger on screen as a stale overlay.
    if (!identical(old.image, widget.image)) {
      _token++;
      _sharp?.dispose();
      _sharp = null;
      _requestSharp();
    }
  }

  @override
  void dispose() {
    _sharp?.dispose();
    super.dispose();
  }

  /// Window centre, clamped so it can never leave the picture. When the window is
  /// wider than the image on an axis, centre on that axis instead of clamping —
  /// otherwise the drag fights the user at the edges.
  Offset _clamp(Offset f, double winW, double winH) => Offset(
        winW >= _imgW ? _imgW / 2 : f.dx.clamp(winW / 2, _imgW - winW / 2),
        winH >= _imgH ? _imgH / 2 : f.dy.clamp(winH / 2, _imgH - winH / 2),
      );

  /// Contain-fit scale for a box: screen px per image px at zoom 1.
  double _fitScale(Size box) =>
      math.min(box.width / _imgW, box.height / _imgH);

  ui.Rect _window(Size box) {
    final s = _fitScale(box) * _zoom;
    final w = box.width / s, h = box.height / s;
    final f = _clamp(_focus ?? Offset(_imgW / 2, _imgH / 2), w, h);
    return ui.Rect.fromCenter(center: f, width: w, height: h);
  }

  Future<void> _requestSharp() async {
    final render = widget.cropRenderer;
    final box = context.size;
    if (render == null || box == null || box.isEmpty) return;
    final token = ++_token;
    final crop = _window(box);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    // Ask for the window at its true device resolution — that, not the zoom factor,
    // is how many pixels actually reach the screen.
    final outW = (box.width * dpr).round().clamp(64, 2048);
    final outH = (box.height * dpr).round().clamp(64, 2048);
    try {
      final img = await render(crop, outW, outH);
      if (!mounted || token != _token) {
        img.dispose();
        return;
      }
      setState(() {
        _sharp?.dispose();
        _sharp = img;
      });
    } catch (_) {
      // Fall back to magnifying the bitmap — a soft view beats a blank one.
    }
  }

  void _dropSharp() {
    if (_sharp == null) return;
    _token++;
    _sharp?.dispose();
    _sharp = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final box = constraints.biggest;
      final win = _window(box);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () {
          setState(() {
            _zoom = 1;
            _focus = null;
            _dropSharp();
          });
          _requestSharp();
        },
        onScaleStart: (_) => _zoomAtGestureStart = _zoom,
        onScaleUpdate: (d) {
          setState(() {
            if (d.scale != 1.0) {
              _zoom = (_zoomAtGestureStart * d.scale).clamp(1.0, _maxZoom);
            }
            final s = _fitScale(box) * _zoom;
            final w = box.width / s, h = box.height / s;
            _focus = _clamp(
                (_focus ?? Offset(_imgW / 2, _imgH / 2)) -
                    d.focalPointDelta / s,
                w,
                h);
            // The sharp crop belongs to where the window WAS.
            _dropSharp();
          });
        },
        // Re-render once the gesture settles, not per frame: each render repaints the
        // whole geometry and would make the pinch stutter.
        onScaleEnd: (_) => _requestSharp(),
        child: ClipRect(
          child: CustomPaint(
            size: Size.infinite,
            painter: _ImageWindowPainter(
              image: widget.image,
              sharp: _sharp,
              window: win,
            ),
          ),
        ),
      );
    });
  }
}

class _ImageWindowPainter extends CustomPainter {
  _ImageWindowPainter({
    required this.image,
    required this.sharp,
    required this.window,
  });

  final ui.Image image;

  /// Natively-rendered pixels for exactly [window], when available.
  final ui.Image? sharp;
  final ui.Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    canvas.drawRect(dst, Paint()..color = AppColors.background);
    final s = sharp;
    if (s != null) {
      // Already rendered at this window and resolution — draw it 1:1.
      canvas.drawImageRect(
        s,
        Rect.fromLTWH(0, 0, s.width.toDouble(), s.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    canvas.drawImageRect(
      image,
      window,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_ImageWindowPainter old) =>
      old.image != image || old.sharp != sharp || old.window != window;
}
