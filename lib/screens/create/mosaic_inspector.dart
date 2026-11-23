import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

/// Bakes the part [win] of the mosaic (base-image px) into an [outW]×[outH] image —
/// tiles, recolour and grade exactly as the studio draws them.
typedef MosaicWindowBaker = Future<ui.Image?> Function(Rect win, int outW, int outH);

enum _Mode { whole, print, pixels }

/// The paywall's "look before you buy" view of a photo mosaic (same as the web popup's
/// inspector): the whole picture on a wall, a real-size patch of a [printCm] print, and
/// 100% pixels of the paid file — draggable, with sharper copies of the photos baked in
/// as they arrive ([sharperTiles] ticks).
class MosaicInspector extends StatefulWidget {
  const MosaicInspector({
    super.key,
    required this.planSize,
    required this.fileSize,
    required this.whole,
    required this.bake,
    required this.sharperTiles,
    required this.cmPerLogicalPx,
    this.printCm = 80,
  });

  /// The plan's base size (the coordinate space [bake] takes).
  final Size planSize;

  /// The paid file's exact size; "100%" = one pixel of it per logical pixel.
  final Size? fileSize;

  /// The whole mosaic, small (the wall view and the overview map).
  final ui.Image? whole;
  final MosaicWindowBaker bake;
  final Listenable sharperTiles;
  final double cmPerLogicalPx;
  final double printCm;

  @override
  State<MosaicInspector> createState() => _MosaicInspectorState();
}

class _MosaicInspectorState extends State<MosaicInspector> {
  _Mode _mode = _Mode.whole;
  late Offset _centre = Offset(widget.planSize.width / 2, widget.planSize.height * 0.42);
  Size _view = Size.zero; // logical
  ui.Image? _buf;
  Rect? _bufWin; // base px
  _Mode? _bufMode;
  bool _baking = false, _again = false, _dragged = false;
  Timer? _settle;

  /// How much more than the view the baked buffer covers (per axis).
  static const double _buffer = 1.8;
  static const int _maxBufferPx = 8 * 1000 * 1000;

  @override
  void initState() {
    super.initState();
    widget.sharperTiles.addListener(_onSharper);
  }

  @override
  void dispose() {
    widget.sharperTiles.removeListener(_onSharper);
    _settle?.cancel();
    _buf?.dispose();
    super.dispose();
  }

  double get _fileLong {
    final f = widget.fileSize;
    return f == null ? 20000 : math.max(f.width, f.height);
  }

  double get _planLong => math.max(widget.planSize.width, widget.planSize.height);

  /// Base px per logical px in the zoomed modes.
  double get _bpl => _mode == _Mode.pixels ? _planLong / _fileLong : _planLong / widget.printCm * widget.cmPerLogicalPx;

  Rect get _viewWin => Rect.fromCenter(center: _centre, width: _view.width * _bpl, height: _view.height * _bpl);

  void _clampCentre() {
    final w = widget.planSize.width, h = widget.planSize.height;
    final hw = _view.width * _bpl / 2, hh = _view.height * _bpl / 2;
    _centre = Offset(
      hw * 2 >= w ? w / 2 : _centre.dx.clamp(hw, w - hw),
      hh * 2 >= h ? h / 2 : _centre.dy.clamp(hh, h - hh),
    );
  }

  void _onSharper() {
    if (_mode == _Mode.whole) return;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 150), _bakeBuffer);
  }

  Future<void> _bakeBuffer() async {
    if (_mode == _Mode.whole || _view.isEmpty || !mounted) return;
    if (_baking) {
      _again = true;
      return;
    }
    _baking = true;
    final mode = _mode;
    try {
      final w = widget.planSize.width, h = widget.planSize.height;
      final bw = math.min(w, _view.width * _bpl * _buffer), bh = math.min(h, _view.height * _bpl * _buffer);
      final cx = _centre.dx.clamp(bw / 2, w - bw / 2), cy = _centre.dy.clamp(bh / 2, h - bh / 2);
      final win = Rect.fromCenter(center: Offset(cx, cy), width: bw, height: bh);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      var ow = bw / _bpl * dpr, oh = bh / _bpl * dpr;
      if (ow * oh > _maxBufferPx) {
        final s = math.sqrt(_maxBufferPx / (ow * oh));
        ow *= s;
        oh *= s;
      }
      final img = await widget.bake(win, math.max(1, ow.round()), math.max(1, oh.round()));
      if (!mounted || img == null) return;
      if (mode != _mode) {
        img.dispose();
        return;
      }
      final old = _buf;
      setState(() {
        _buf = img;
        _bufWin = win;
        _bufMode = mode;
      });
      old?.dispose();
    } catch (_) {
      /* keep what is shown */
    } finally {
      _baking = false;
      if (_again && mounted) {
        _again = false;
        unawaited(_bakeBuffer());
      }
    }
  }

  void _setMode(_Mode m) {
    if (m == _mode) return;
    setState(() => _mode = m);
    if (m != _Mode.whole) {
      _clampCentre();
      unawaited(_bakeBuffer());
    }
  }

  void _pan(Offset delta) {
    setState(() {
      _centre -= delta * _bpl;
      _clampCentre();
      _dragged = true;
    });
    final b = _bufWin;
    // Dragged past what the buffer covers: bake around the new centre now.
    if (b == null || !b.inflate(1).contains(_viewWin.topLeft) || !b.inflate(1).contains(_viewWin.bottomRight)) {
      unawaited(_bakeBuffer());
    }
  }

  void _panEnd() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 150), _bakeBuffer);
  }

  static String _fmt(double v) => v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  @override
  Widget build(BuildContext context) {
    final f = widget.fileSize;
    final dims = f == null ? 'full-resolution' : '${_fmt(f.width)} × ${_fmt(f.height)} px';
    final dpi = (_fileLong / (widget.printCm / 2.54)).round();
    final info = switch (_mode) {
      _Mode.whole => 'Your file: $dims. Every tile is one of your photos.',
      _Mode.print =>
        'Real size on a ${widget.printCm.round()} cm print (roughly; it depends on your screen) — $dpi dpi, so it stays sharp even up close.',
      _Mode.pixels => '100%: one pixel of your $dims file on each screen pixel — the deepest zoom the file has.',
    };
    final height = math.min(440.0, math.max(240.0, MediaQuery.sizeOf(context).height * 0.42));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Segments(
          labels: ['Whole picture', '${widget.printCm.round()} cm print', '100% pixels'],
          selected: _mode.index,
          onSelect: (i) => _setMode(_Mode.values[i]),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (ctx, c) {
              final size = Size(c.maxWidth, c.maxHeight);
              if (size != _view) {
                _view = size;
                if (_mode != _Mode.whole) {
                  _clampCentre();
                  scheduleMicrotask(_bakeBuffer);
                }
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _mode == _Mode.whole ? _wholeView() : _zoomView(),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(info, style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
      ],
    );
  }

  Widget _wholeView() {
    final img = widget.whole;
    final ar = img == null ? widget.planSize.width / widget.planSize.height : img.width / img.height;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFEFE6DA), Color(0xFFD9CDBD)],
        ),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 44),
            child: Center(
              child: AspectRatio(
                aspectRatio: ar,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2B2118),
                    boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 8))],
                  ),
                  child: LayoutBuilder(
                    builder: (ctx, c) => GestureDetector(
                      // Tap the picture → real print size, centred where tapped.
                      onTapUp: (d) {
                        _centre = Offset(
                          d.localPosition.dx / c.maxWidth * widget.planSize.width,
                          d.localPosition.dy / c.maxHeight * widget.planSize.height,
                        );
                        _setMode(_Mode.print);
                      },
                      child: img == null
                          ? Container(color: AppColors.surfaceRaised)
                          : RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Positioned(
            left: 8,
            right: 8,
            bottom: 10,
            child: Center(
              child: _Pill(icon: Icons.zoom_in, text: 'Tap the picture to see it at real print size'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoomView() {
    final buf = _bufMode == _mode ? _buf : null;
    final b = _bufWin;
    final v = _viewWin;
    final bpl = _bpl;
    final pannable = v.width < widget.planSize.width - 1 || v.height < widget.planSize.height - 1;
    return RawGestureDetector(
      // Claims the drag at once, so the sheet's scroll and swipe-down don't take it.
      gestures: {
        ImmediateMultiDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
          () => ImmediateMultiDragGestureRecognizer(),
          (r) => r.onStart = (_) => _PanDrag(onUpdate: _pan, onEnd: _panEnd),
        ),
      },
      child: Container(
        color: const Color(0xFF0B0F19),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (buf != null && b != null)
              Positioned(
                left: (b.left - v.left) / bpl,
                top: (b.top - v.top) / bpl,
                width: b.width / bpl,
                height: b.height / bpl,
                child: RawImage(image: buf, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              )
            else
              const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                ),
              ),
            if (pannable && !_dragged)
              const Center(
                child: IgnorePointer(
                  child: _Pill(icon: Icons.pan_tool_outlined, text: 'Drag to look around'),
                ),
              ),
            if (_mode == _Mode.print)
              Positioned(
                right: 8,
                bottom: 8,
                child: IgnorePointer(child: _CmRuler(cmPerLogicalPx: widget.cmPerLogicalPx)),
              ),
            if (pannable && widget.whole != null)
              Positioned(
                left: 8,
                bottom: 8,
                child: IgnorePointer(
                  child: _MiniMap(
                    image: widget.whole!,
                    view: Rect.fromLTRB(
                      v.left / widget.planSize.width,
                      v.top / widget.planSize.height,
                      v.right / widget.planSize.width,
                      v.bottom / widget.planSize.height,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PanDrag extends Drag {
  _PanDrag({required this.onUpdate, required this.onEnd});
  final void Function(Offset delta) onUpdate;
  final VoidCallback onEnd;

  @override
  void update(DragUpdateDetails details) => onUpdate(details.delta);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onEnd();
}

class _Segments extends StatelessWidget {
  const _Segments({required this.labels, required this.selected, required this.onSelect});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
    ),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: i == selected ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(
                    fontWeight: FontWeight.w600,
                    color: i == selected ? const Color(0xFF0B0F19) : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: const Color(0xA6000000), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            style: AppTypography.caption.copyWith(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// A 1 cm scale bar: proof the view is life size.
class _CmRuler extends StatelessWidget {
  const _CmRuler({required this.cmPerLogicalPx});
  final double cmPerLogicalPx;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 3, 6, 4),
    decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(8)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('1 cm', style: AppTypography.caption.copyWith(color: Colors.white, fontSize: 10)),
        const SizedBox(height: 2),
        Container(
          width: 1 / cmPerLogicalPx,
          height: 6,
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Colors.white, width: 1.5),
              right: BorderSide(color: Colors.white, width: 1.5),
              bottom: BorderSide(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The whole picture, small, with the part on screen outlined.
class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.image, required this.view});
  final ui.Image image;
  final Rect view; // normalised

  @override
  Widget build(BuildContext context) {
    final ar = image.width / image.height;
    final w = ar >= 1 ? 72.0 : 72.0 * ar, h = ar >= 1 ? 72.0 / ar : 72.0;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: RawImage(image: image, fit: BoxFit.fill),
          ),
          Positioned(
            left: view.left * w,
            top: view.top * h,
            width: math.max(4, view.width * w),
            height: math.max(4, view.height * h),
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: AppColors.accent, width: 2)),
            ),
          ),
        ],
      ),
    );
  }
}
