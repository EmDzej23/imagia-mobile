import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mosaic/mosaic_engine.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Pick a base photo, run it through the crop dialog, then commit the (cropped
/// or original) result as the active base. Shared by the source-picker and the
/// studio "change base" action so cropping applies to every mosaic mode.
Future<void> pickCropAndSetBase(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(studioControllerProvider.notifier);
  final picked = await controller.pickBaseBytes();
  if (picked == null) return;

  // Decode at a bounded size for the crop UI (the committed base is compressed
  // to 2000px anyway, so a ~2400px working image loses nothing).
  final image = await decodeThumbnail(picked.bytes, 2400);
  if (!context.mounted) {
    image.dispose();
    return;
  }
  final Uint8List? result = await Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => BaseCropScreen(image: image, originalBytes: picked.bytes),
    ),
  );
  image.dispose();
  if (result == null) return; // cancelled
  await controller.setBaseFromBytes(result, picked.name);
}

/// Crop aspect presets. Each is [short, long]; the orientation toggle decides
/// portrait (short×long) vs landscape (long×short).
const List<({String id, String label, int a, int b})> _ratioPresets = [
  (id: '1x1', label: '1:1', a: 1, b: 1),
  (id: '2x3', label: '2:3', a: 2, b: 3),
  (id: '3x4', label: '3:4', a: 3, b: 4),
  (id: '4x5', label: '4:5', a: 4, b: 5),
  (id: '5x7', label: '5:7', a: 5, b: 7),
  (id: '6x9', label: '6:9', a: 6, b: 9),
  (id: '7x10', label: '7:10', a: 7, b: 10),
];

const double _minCrop = 48;
const int _maxOutput = 2400;
const double _handleHit = 28;

enum _Kind { panImage, move, nw, n, ne, e, se, s, sw, w }

const _corners = [_Kind.nw, _Kind.ne, _Kind.se, _Kind.sw];
const _allHandles = [
  _Kind.nw, _Kind.n, _Kind.ne, _Kind.e, _Kind.se, _Kind.s, _Kind.sw, _Kind.w,
];

class BaseCropScreen extends StatefulWidget {
  const BaseCropScreen({
    super.key,
    required this.image,
    required this.originalBytes,
  });

  final ui.Image image;
  final Uint8List originalBytes;

  @override
  State<BaseCropScreen> createState() => _BaseCropScreenState();
}

class _BaseCropScreenState extends State<BaseCropScreen> {
  // Image displayed top-left (ix, iy) at scale (display px per image px).
  double _scale = 0;
  double _ix = 0;
  double _iy = 0;
  bool _init = false;
  Size _stage = Size.zero;

  Rect? _crop; // stage coords
  String _mode = 'free'; // 'original' | 'free' | preset id
  bool _portrait = true;
  bool _busy = false;

  // Gesture snapshot.
  _Kind _kind = _Kind.panImage;
  late Offset _startFocal;
  late double _startScale;
  late double _startIx;
  late double _startIy;
  late Rect _startCrop;

  double get _iw => widget.image.width.toDouble();
  double get _ih => widget.image.height.toDouble();

  double get _fitScale =>
      math.min(_stage.width / _iw, _stage.height / _ih);

  Rect get _imageRect => Rect.fromLTWH(_ix, _iy, _iw * _scale, _ih * _scale);

  /// Region of the image visible in the stage — the crop box is confined here.
  Rect get _bounds {
    final r = _imageRect;
    final l = math.max(r.left, 0.0);
    final t = math.max(r.top, 0.0);
    final rt = math.min(r.right, _stage.width);
    final bt = math.min(r.bottom, _stage.height);
    return Rect.fromLTRB(l, t, math.max(l, rt), math.max(t, bt));
  }

  /// Width/height ratio for the active mode, or null if unconstrained.
  double? get _ratio {
    if (_mode == 'free' || _mode == 'original') return null;
    final p = _ratioPresets.firstWhere((e) => e.id == _mode,
        orElse: () => _ratioPresets.first);
    if (p.a == p.b) return 1;
    return _portrait ? p.a / p.b : p.b / p.a;
  }

  void _initTransform() {
    _scale = _fitScale;
    _ix = (_stage.width - _iw * _scale) / 2;
    _iy = (_stage.height - _ih * _scale) / 2;
    _crop = _defaultCrop(_ratio, _bounds);
    _init = true;
  }

  Rect _defaultCrop(double? ratio, Rect b) {
    if (ratio == null) return b;
    var w = b.width;
    var h = w / ratio;
    if (h > b.height) {
      h = b.height;
      w = h * ratio;
    }
    return Rect.fromLTWH(
        b.left + (b.width - w) / 2, b.top + (b.height - h) / 2, w, h);
  }

  Rect _normalize(Rect crop, double? ratio, Rect b) {
    var w = crop.width.clamp(_minCrop, b.width);
    var h = crop.height.clamp(_minCrop, b.height);
    if (ratio != null) {
      h = w / ratio;
      if (h > b.height) {
        h = b.height;
        w = h * ratio;
      }
      if (w > b.width) {
        w = b.width;
        h = w / ratio;
      }
    }
    final x = crop.left.clamp(b.left, b.right - w);
    final y = crop.top.clamp(b.top, b.bottom - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  void _clampImage() {
    final iw = _iw * _scale, ih = _ih * _scale;
    if (iw >= _stage.width) {
      _ix = _ix.clamp(_stage.width - iw, 0.0);
    } else {
      _ix = _ix.clamp(0.0, _stage.width - iw);
    }
    if (ih >= _stage.height) {
      _iy = _iy.clamp(_stage.height - ih, 0.0);
    } else {
      _iy = _iy.clamp(0.0, _stage.height - ih);
    }
  }

  Map<_Kind, Offset> _handleCenters(Rect c) {
    return {
      _Kind.nw: c.topLeft,
      _Kind.ne: c.topRight,
      _Kind.se: c.bottomRight,
      _Kind.sw: c.bottomLeft,
      _Kind.n: Offset(c.center.dx, c.top),
      _Kind.s: Offset(c.center.dx, c.bottom),
      _Kind.e: Offset(c.right, c.center.dy),
      _Kind.w: Offset(c.left, c.center.dy),
    };
  }

  _Kind _hitTest(Offset p) {
    final crop = _crop;
    if (_mode == 'original' || crop == null) return _Kind.panImage;
    final handles = _ratio != null ? _corners : _allHandles;
    final centers = _handleCenters(crop);
    for (final h in handles) {
      if ((centers[h]! - p).distance <= _handleHit) return h;
    }
    if (crop.inflate(2).contains(p)) return _Kind.move;
    return _Kind.panImage;
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startFocal = d.localFocalPoint;
    _startScale = _scale;
    _startIx = _ix;
    _startIy = _iy;
    _startCrop = _crop ?? Rect.zero;
    _kind = d.pointerCount >= 2 ? _Kind.panImage : _hitTest(d.localFocalPoint);
  }

  void _handleUpdate(ScaleUpdateDetails d) {
    final b = _bounds;
    // Two-finger → always zoom/pan the image.
    if (d.pointerCount >= 2 || _kind == _Kind.panImage) {
      setState(() {
        if (d.scale != 1.0) {
          final newScale =
              (_startScale * d.scale).clamp(_fitScale, _fitScale * 8);
          final k = newScale / _startScale;
          _scale = newScale;
          _ix = d.localFocalPoint.dx - (_startFocal.dx - _startIx) * k;
          _iy = d.localFocalPoint.dy - (_startFocal.dy - _startIy) * k;
        } else {
          _ix = _startIx + (d.localFocalPoint.dx - _startFocal.dx);
          _iy = _startIy + (d.localFocalPoint.dy - _startFocal.dy);
        }
        _clampImage();
        if (_crop != null) _crop = _normalize(_crop!, _ratio, _bounds);
      });
      return;
    }

    final dx = d.localFocalPoint.dx - _startFocal.dx;
    final dy = d.localFocalPoint.dy - _startFocal.dy;

    if (_kind == _Kind.move) {
      setState(() {
        _crop = _normalize(_startCrop.translate(dx, dy), _ratio, b);
      });
      return;
    }

    // Resize.
    var left = _startCrop.left,
        right = _startCrop.right,
        top = _startCrop.top,
        bottom = _startCrop.bottom;
    final k = _kind.name;
    if (k.contains('w')) left = _startCrop.left + dx;
    if (k.contains('e')) right = _startCrop.right + dx;
    if (k.contains('n')) top = _startCrop.top + dy;
    if (k.contains('s')) bottom = _startCrop.bottom + dy;
    final next = Rect.fromLTRB(
      math.min(left, right - _minCrop),
      math.min(top, bottom - _minCrop),
      math.max(right, left + _minCrop),
      math.max(bottom, top + _minCrop),
    );
    setState(() => _crop = _normalize(next, _ratio, b));
  }

  void _selectMode(String id) {
    setState(() {
      _mode = id;
      if (id != 'original' && id != 'free') {
        _crop = _defaultCrop(_ratio, _bounds);
      } else {
        _crop ??= _defaultCrop(null, _bounds);
      }
    });
  }

  void _toggleOrientation() {
    setState(() {
      _portrait = !_portrait;
      if (_mode != 'original' && _mode != 'free') {
        _crop = _defaultCrop(_ratio, _bounds);
      }
    });
  }

  Future<void> _confirm() async {
    if (_mode == 'original' || _crop == null) {
      Navigator.of(context).pop(widget.originalBytes);
      return;
    }
    setState(() => _busy = true);
    try {
      final crop = _crop!;
      var sx = (crop.left - _ix) / _scale;
      var sy = (crop.top - _iy) / _scale;
      var sw = crop.width / _scale;
      var sh = crop.height / _scale;
      sx = sx.clamp(0.0, _iw);
      sy = sy.clamp(0.0, _ih);
      sw = sw.clamp(1.0, _iw - sx);
      sh = sh.clamp(1.0, _ih - sy);

      var outW = sw, outH = sh;
      final long = math.max(outW, outH);
      if (long > _maxOutput) {
        final f = _maxOutput / long;
        outW *= f;
        outH *= f;
      }
      final w = outW.round(), h = outH.round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        widget.image,
        Rect.fromLTWH(sx, sy, sw, sh),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final pic = recorder.endRecording();
      final outImg = await pic.toImage(w, h);
      pic.dispose();
      final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
      outImg.dispose();
      if (!mounted) return;
      Navigator.of(context).pop(data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) Navigator.of(context).pop(widget.originalBytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Crop your photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _confirm,
            child: Text(
              _mode == 'original' ? 'Use original' : 'Apply',
              style: AppTypography.label.copyWith(
                  color: _busy ? AppColors.textMuted : AppColors.accent),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                if (!_init || _stage != size) {
                  _stage = size;
                  _initTransform();
                }
                return GestureDetector(
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _handleUpdate,
                  child: CustomPaint(
                    size: size,
                    painter: _CropPainter(
                      image: widget.image,
                      dst: _imageRect,
                      crop: _mode == 'original' ? null : _crop,
                      handles: _crop == null
                          ? const []
                          : (_ratio != null ? _corners : _allHandles),
                    ),
                  ),
                );
              }),
            ),
            _controls(),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.x3, AppSpacing.x3, AppSpacing.x3, AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('Original', 'original'),
                _chip('Free', 'free'),
                const SizedBox(width: AppSpacing.x2),
                for (final p in _ratioPresets) _chip(p.label, p.id),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: (_mode == 'original' ||
                        _mode == 'free' ||
                        _mode == '1x1')
                    ? null
                    : _toggleOrientation,
                icon: Icon(
                    _portrait ? Icons.crop_portrait : Icons.crop_landscape,
                    size: 18),
                label: Text(_portrait ? 'Portrait' : 'Landscape'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  side: const BorderSide(color: AppColors.border),
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Text(
                  _mode == 'original'
                      ? 'The full photo will be used.'
                      : 'Drag box to move · handles to resize · pinch to zoom.',
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String id) {
    final active = _mode == id;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.x2),
      child: GestureDetector(
        onTap: () => _selectMode(id),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(
                color: active ? AppColors.accent : AppColors.border),
          ),
          child: Text(
            label,
            style: AppTypography.label.copyWith(
              color: active ? Colors.black : AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.dst,
    required this.crop,
    required this.handles,
  });
  final ui.Image image;
  final Rect dst;
  final Rect? crop;
  final List<_Kind> handles;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final c = crop;
    if (c == null) return;

    // Dim outside the crop box.
    canvas.saveLayer(full, Paint());
    canvas.drawRect(full, Paint()..color = const Color(0x99000000));
    canvas.drawRect(c, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // Border + rule-of-thirds.
    final border = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(c, border);
    final thin = Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = c.left + c.width * i / 3;
      canvas.drawLine(Offset(dx, c.top), Offset(dx, c.bottom), thin);
      final dy = c.top + c.height * i / 3;
      canvas.drawLine(Offset(c.left, dy), Offset(c.right, dy), thin);
    }

    // Handles.
    final centers = <_Kind, Offset>{
      _Kind.nw: c.topLeft,
      _Kind.ne: c.topRight,
      _Kind.se: c.bottomRight,
      _Kind.sw: c.bottomLeft,
      _Kind.n: Offset(c.center.dx, c.top),
      _Kind.s: Offset(c.center.dx, c.bottom),
      _Kind.e: Offset(c.right, c.center.dy),
      _Kind.w: Offset(c.left, c.center.dy),
    };
    final fill = Paint()..color = AppColors.accent;
    final ring = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final h in handles) {
      final p = centers[h]!;
      canvas.drawCircle(p, 7, fill);
      canvas.drawCircle(p, 7, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.dst != dst || old.crop != crop || old.handles != handles;
}
