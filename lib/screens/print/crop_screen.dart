import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

/// Aspect-locked crop. The crop window is fixed (at [aspect]); the mosaic pans
/// and zooms behind it. Returns the chosen region as a normalised [Rect]
/// (0–1 in image coordinates), or null if cancelled.
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.image,
    required this.aspect,
    this.initialCrop,
  });

  final ui.Image image;
  final double aspect;
  final Rect? initialCrop;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  // Image displayed top-left (ix, iy) at scale (display px per image px).
  double _scale = 0;
  double _ix = 0;
  double _iy = 0;
  bool _init = false;

  // Gesture start snapshot.
  late double _startScale;
  late Offset _startFocal;
  late double _startIx;
  late double _startIy;

  double get _iw => widget.image.width.toDouble();
  double get _ih => widget.image.height.toDouble();

  Rect _window(Size avail) {
    var w = avail.width;
    var h = w / widget.aspect;
    if (h > avail.height) {
      h = avail.height;
      w = h * widget.aspect;
    }
    return Rect.fromCenter(
        center: Offset(avail.width / 2, avail.height / 2), width: w, height: h);
  }

  void _initTransform(Rect win) {
    final cover = math.max(win.width / _iw, win.height / _ih);
    if (widget.initialCrop != null) {
      final c = widget.initialCrop!;
      _scale = win.width / (c.width * _iw);
      _ix = win.left - c.left * _iw * _scale;
      _iy = win.top - c.top * _ih * _scale;
    } else {
      _scale = cover;
      _ix = win.center.dx - _iw * _scale / 2;
      _iy = win.center.dy - _ih * _scale / 2;
    }
    _clamp(win);
    _init = true;
  }

  void _clamp(Rect win) {
    final minScale = math.max(win.width / _iw, win.height / _ih);
    _scale = _scale.clamp(minScale, minScale * 6);
    _ix = _ix.clamp(win.right - _iw * _scale, win.left);
    _iy = _iy.clamp(win.bottom - _ih * _scale, win.top);
  }

  Rect _normalizedCrop(Rect win) {
    final left = (win.left - _ix) / _scale / _iw;
    final top = (win.top - _iy) / _scale / _ih;
    final w = win.width / _scale / _iw;
    final h = win.height / _scale / _ih;
    return Rect.fromLTWH(left.clamp(0.0, 1.0), top.clamp(0.0, 1.0),
        w.clamp(0.0, 1.0), h.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Adjust framing'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(
                _lastWindow == null ? null : _normalizedCrop(_lastWindow!)),
            child: Text('Done',
                style: AppTypography.label.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(builder: (context, constraints) {
            final avail = Size(constraints.maxWidth, constraints.maxHeight);
            final win = _window(avail);
            _lastWindow = win;
            if (!_init) _initTransform(win);

            return GestureDetector(
              onScaleStart: (d) {
                _startScale = _scale;
                _startFocal = d.localFocalPoint;
                _startIx = _ix;
                _startIy = _iy;
              },
              onScaleUpdate: (d) {
                setState(() {
                  final minScale =
                      math.max(win.width / _iw, win.height / _ih);
                  final newScale = (_startScale * d.scale)
                      .clamp(minScale, minScale * 6);
                  final k = newScale / _startScale;
                  _scale = newScale;
                  _ix = d.localFocalPoint.dx - (_startFocal.dx - _startIx) * k;
                  _iy = d.localFocalPoint.dy - (_startFocal.dy - _startIy) * k;
                  _clamp(win);
                });
              },
              child: CustomPaint(
                size: avail,
                painter: _CropPainter(
                  image: widget.image,
                  dst: Rect.fromLTWH(_ix, _iy, _iw * _scale, _ih * _scale),
                  window: win,
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Text('Pinch to zoom · drag to position',
                          style: AppTypography.caption
                              .copyWith(color: Colors.white70)),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Rect? _lastWindow;
}

class _CropPainter extends CustomPainter {
  _CropPainter(
      {required this.image, required this.dst, required this.window});
  final ui.Image image;
  final Rect dst;
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Dim everything outside the crop window.
    canvas.saveLayer(full, Paint());
    canvas.drawRect(full, Paint()..color = const Color(0xAA000000));
    canvas.drawRect(window, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // Window border + rule-of-thirds grid.
    final line = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(window, line..strokeWidth = 2);
    final thin = Paint()
      ..color = const Color(0x44FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = window.left + window.width * i / 3;
      canvas.drawLine(Offset(dx, window.top), Offset(dx, window.bottom), thin);
      final dy = window.top + window.height * i / 3;
      canvas.drawLine(Offset(window.left, dy), Offset(window.right, dy), thin);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.dst != dst || old.window != window || old.image != image;
}
