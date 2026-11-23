import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'hires_tiles.dart';
import 'looks.dart';
import 'local_recolor.dart';
import 'preview_painter.dart' show drawPlanWindow, sharperTile;
import 'shared.dart' show saturationColorFilter;
import 'types.dart';

/// The in-cell tile recolour, applied the way the WEB applies it: the tiles are drawn,
/// then the finished pixels are recoloured ([applyLocalRecolor], a byte-exact port of
/// the web), then the tint overlay, then the saturation grade. A colour filter per tile
/// cannot do this — the correction varies across the tile (the photo's 5×5 under it)
/// and darkening must SHIFT the tile, not scale it to black.
///
/// [win] = the window of the mosaic to render, in base px; [outW]×[outH] its pixels.
/// [imageFor] picks each tile's image (a sharp copy when zoomed). Returns null when
/// there is nothing to draw.
Future<ui.Image?> bakeMosaicWindow({
  required SlimMosaicPlan plan,
  required Map<String, TileCrop> tileCrops,
  required ui.Image? Function(SlimPlacement p, double needPx) imageFor,
  required Rect win,
  required int outW,
  required int outH,
  required double tileRecolor,
  required double outputSaturation,
  double tintStrength = 0,
  ui.Image? overlay,

  /// Checked between the steps: once true the bake stops and returns null (a newer
  /// setting has replaced it, so finishing would only delay the one that matters).
  bool Function()? cancelled,
}) async {
  if (outW < 1 || outH < 1 || win.width <= 0) return null;
  final k = outW / win.width;
  final size = Size(outW.toDouble(), outH.toDouble());

  // 1. The tiles, as drawn.
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Offset.zero & size);
  final cells = drawPlanWindow(
    canvas,
    plan,
    tileCrops,
    k,
    win.topLeft,
    size,
    imageFor: imageFor,
  );
  final pic = rec.endRecording();
  final raw = await pic.toImage(outW, outH);
  pic.dispose();
  final bd = await raw.toByteData(format: ui.ImageByteFormat.rawRgba);
  raw.dispose();
  if (bd == null || (cancelled?.call() ?? false)) return null;

  // 2. Recolour (+ the grade when nothing is drawn in between), off the UI thread.
  final tinted = tintStrength > 0 && overlay != null;
  final strength = tileRecolor, sat = tinted ? 1.0 : outputSaturation;
  // The look (looks.dart) goes over the finished, graded picture — right here when
  // nothing is drawn after the grade, else after the tint below. Web order.
  final look = tinted ? 'none' : plan.look;
  final input = bd.buffer.asUint8List();
  final Uint8List out;
  if (cells.length < 64 && outW * outH < 600 * 600) {
    applyLocalRecolor(
      input,
      outW,
      outH,
      cells,
      strength,
      outputSaturation: sat,
    );
    applyLookToPixels(input, 4, look);
    out = input;
  } else {
    out = await Isolate.run(() {
      applyLocalRecolor(
        input,
        outW,
        outH,
        cells,
        strength,
        outputSaturation: sat,
      );
      applyLookToPixels(input, 4, look);
      return input;
    });
  }
  if (cancelled?.call() ?? false) return null;
  final recolored = await _imageFromRgba(out, outW, outH);
  if (!tinted) return recolored;

  // 3. Tint overlay over the recoloured tiles, then the grade over everything — the
  //    web's order (renderPreviewToCanvas).
  final rec2 = ui.PictureRecorder();
  final c2 = Canvas(rec2, Offset.zero & size);
  final grade = saturationColorFilter(outputSaturation);
  if (grade != null)
    c2.saveLayer(Offset.zero & size, Paint()..colorFilter = grade);
  c2.drawImage(recolored, Offset.zero, Paint());
  c2.drawImageRect(
    overlay,
    Rect.fromLTWH(0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
    Rect.fromLTWH(
      -win.left * k,
      -win.top * k,
      plan.baseWidth * k,
      plan.baseHeight * k,
    ),
    Paint()
      ..color = Color.fromRGBO(255, 255, 255, tintStrength)
      ..filterQuality = FilterQuality.high,
  );
  if (grade != null) c2.restore();
  final pic2 = rec2.endRecording();
  final img = await pic2.toImage(outW, outH);
  pic2.dispose();
  recolored.dispose();
  if (!hasLook(plan.look)) return img;
  // 4. The look over everything (after the tint and the grade).
  final bd2 = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  if (bd2 == null || (cancelled?.call() ?? false)) return null;
  final px = bd2.buffer.asUint8List();
  final look2 = plan.look;
  final graded = await Isolate.run(() {
    applyLookToPixels(px, 4, look2);
    return px;
  });
  return _imageFromRgba(graded, outW, outH);
}

Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final desc = ui.ImageDescriptor.raw(
    buffer,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await desc.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  desc.dispose();
  buffer.dispose();
  return frame.image;
}

/// The whole mosaic, recoloured once — what every view shows, so zooming and dragging
/// only MOVE a finished picture (nothing is re-coloured under your finger). Rebuilt
/// only when the plan or a look setting changes; until the new one is ready the old
/// one stays (a different plan clears it at once — its tiles would be wrong).
class HrRecolorCache extends ChangeNotifier {
  HrRecolorCache({this.longSide = 4096});
  final int longSide;

  ui.Image? image;
  SlimMosaicPlan? _plan;
  Object? _key, _pending;
  Timer? _debounce;
  bool _running = false, _disposed = false;

  /// Ask for the picture of [plan] with these settings (cheap when unchanged).
  void request({
    required SlimMosaicPlan plan,
    required Map<String, ui.Image> tileImages,
    required double tileRecolor,
    required double outputSaturation,
    required double tintStrength,
    ui.Image? overlay,
  }) {
    // A look needs the baked picture too (it is a per-pixel grade).
    if (!(tileRecolor > 0) && !hasLook(plan.look)) {
      if (image != null || _key != null) {
        image = null;
        _key = null;
        _plan = null;
        notifyListeners();
      }
      return;
    }
    final key = Object.hash(
      plan,
      tileRecolor,
      outputSaturation,
      tintStrength,
      overlay,
      tileImages.length,
      Object.hashAll(plan.tileCrops.values),
    );
    if (key == _key || key == _pending) return;
    if (!identical(plan, _plan) && image != null) {
      image = null;
      notifyListeners();
    }
    _pending = key;
    _debounce?.cancel();
    _fullTimer?.cancel();
    _debounce = Timer(const Duration(milliseconds: 60), () {
      _bake(
        key,
        plan,
        tileImages,
        tileRecolor,
        outputSaturation,
        tintStrength,
        overlay,
        full: false,
      );
    });
  }

  /// Long side of the quick first picture: 1/16 of the pixels of [longSide], so a
  /// setting change shows within a fraction of a second even on an old phone, and the
  /// full-size one follows once the setting has been still for [_settle].
  static const int quickSide = 1024;
  static const Duration _settle = Duration(milliseconds: 450);
  Timer? _fullTimer;
  Object? _quickKey;

  Future<void> _bake(
    Object key,
    SlimMosaicPlan plan,
    Map<String, ui.Image> tileImages,
    double tileRecolor,
    double outputSaturation,
    double tintStrength,
    ui.Image? overlay, {
    required bool full,
  }) async {
    void again() => _bake(
      key,
      plan,
      tileImages,
      tileRecolor,
      outputSaturation,
      tintStrength,
      overlay,
      full: full,
    );
    if (_disposed || _pending != key) return;
    if (_running) {
      // One bake at a time; this one retries when the running one has had a moment.
      Timer(const Duration(milliseconds: 80), again);
      return;
    }
    _running = true;
    var done = false;
    try {
      final long = math.max(plan.baseWidth, plan.baseHeight);
      final side = full ? longSide : math.min(quickSide, longSide);
      final k = side / long;
      final img = await bakeMosaicWindow(
        plan: plan,
        tileCrops: plan.tileCrops,
        imageFor: (p, _) => tileImages[p.tileId],
        win: Rect.fromLTWH(0, 0, plan.baseWidth, plan.baseHeight),
        outW: math.max(1, (plan.baseWidth * k).round()),
        outH: math.max(1, (plan.baseHeight * k).round()),
        tileRecolor: tileRecolor,
        outputSaturation: outputSaturation,
        tintStrength: tintStrength,
        overlay: overlay,
        cancelled: () => _disposed || _pending != key,
      );
      if (img == null || _disposed || _pending != key) {
        img?.dispose();
        return;
      }
      image = img;
      _plan = plan;
      if (full) {
        _key = key;
        _pending = null;
      } else {
        _quickKey = key;
      }
      done = true;
      notifyListeners();
    } finally {
      _running = false;
    }
    if (done && !full && _quickKey == key) {
      // The sharp one, once the slider has stopped moving.
      _fullTimer?.cancel();
      _fullTimer = Timer(_settle, () {
        _bake(
          key,
          plan,
          tileImages,
          tileRecolor,
          outputSaturation,
          tintStrength,
          overlay,
          full: true,
        );
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _fullTimer?.cancel();
    super.dispose();
  }
}

/// A view of (a window of) the mosaic with the web's in-cell tile recolour.
///
/// Draws [hr] — the whole mosaic, recoloured once ([HrRecolorCache]) — mapped to the
/// current [window], so zoom and drag just move it. When the zoom asks for more detail
/// than [hr] has, a sharper picture of the visible window is rendered once the window
/// has stopped moving (same maths, so only sharpness changes). [fallback] shows only
/// until [hr] exists.
class RecoloredMosaicView extends StatefulWidget {
  const RecoloredMosaicView({
    super.key,
    required this.plan,
    required this.tileImages,
    required this.tileCrops,
    required this.window,
    required this.tileRecolor,
    required this.outputSaturation,
    required this.fallback,
    required this.hr,
    this.tintStrength = 0,
    this.overlay,
    this.hiRes,
    this.maxLongSide = 4096,
  });

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final Map<String, TileCrop> tileCrops;

  /// The part of the mosaic this view shows, in base px (its aspect = the view's).
  final Rect window;
  final double tileRecolor;
  final double outputSaturation;
  final double tintStrength;
  final ui.Image? overlay;

  /// The whole mosaic, recoloured (null until it is ready).
  final ui.Image? hr;

  /// Sharp tile copies for deep zoom (optional).
  final HiResTiles? hiRes;

  /// Cap on the sharper window picture's long side (device px).
  final int maxLongSide;

  /// The live painter, shown only until [hr] is ready.
  final Widget fallback;

  @override
  State<RecoloredMosaicView> createState() => _RecoloredMosaicViewState();
}

class _RecoloredMosaicViewState extends State<RecoloredMosaicView> {
  ui.Image? _sharp;
  Rect? _sharpWindow;
  Object? _sharpContent;
  Timer? _idle;
  bool _running = false;
  Size _size = Size.zero;
  double _dpr = 3;

  @override
  void didUpdateWidget(covariant RecoloredMosaicView old) {
    super.didUpdateWidget(old);
    if (!identical(old.plan, widget.plan)) {
      _sharp = null;
      _sharpWindow = null;
    }
    // Only once the window has STOPPED moving.
    if (old.window != widget.window || old.hr != widget.hr) _scheduleSharp();
  }

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }

  Object get _content => Object.hash(
    widget.plan,
    widget.tileRecolor,
    widget.outputSaturation,
    widget.tintStrength,
    widget.overlay,
    Object.hashAll(widget.tileCrops.values),
  );

  /// Device px per base px the view needs, vs what [hr] has.
  bool get _needsSharper {
    final hr = widget.hr;
    if (hr == null || _size.isEmpty) return false;
    final need = _size.width * _dpr / widget.window.width;
    final have = hr.width / widget.plan.baseWidth;
    return need > have * 1.15;
  }

  void _scheduleSharp() {
    _idle?.cancel();
    if (!(widget.tileRecolor > 0) && !hasLook(widget.plan.look)) return;
    _idle = Timer(const Duration(milliseconds: 280), _bakeSharp);
  }

  /// A request that came in while a bake was running (e.g. sharp photos arriving):
  /// served by one more bake when it finishes, instead of being dropped.
  bool _again = false;

  Future<void> _bakeSharp() async {
    if (!mounted || !_needsSharper) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _again = false;
    final win = widget.window;
    final content = _content;
    var outW = (_size.width * _dpr).round(),
        outH = (_size.height * _dpr).round();
    final long = math.max(outW, outH);
    if (long > widget.maxLongSide) {
      final s = widget.maxLongSide / long;
      outW = (outW * s).round();
      outH = (outH * s).round();
    }
    final hr = widget.hiRes;
    final tiles = widget.tileImages;
    try {
      final img = await bakeMosaicWindow(
        plan: widget.plan,
        tileCrops: widget.tileCrops,
        imageFor: (p, needPx) {
          final thumb = tiles[p.tileId];
          if (thumb == null || hr == null) return thumb;
          final shapeK = p.quad != null
              ? 2.0
              : (widget.plan.hexagon ? 1.6 : 1.0);
          return sharperTile(hr, p.tileId, thumb, needPx * shapeK);
        },
        win: win,
        outW: outW,
        outH: outH,
        tileRecolor: widget.tileRecolor,
        outputSaturation: widget.outputSaturation,
        tintStrength: widget.tintStrength,
        overlay: widget.overlay,
      );
      if (!mounted || img == null) return;
      setState(() {
        _sharp = img;
        _sharpWindow = win;
        _sharpContent = content;
      });
      // Sharp tile copies arriving later: one more pass once they are in.
      if (hr != null) {
        void again() {
          hr.version.removeListener(again);
          if (mounted && widget.window == win) _scheduleSharp();
        }

        hr.version.addListener(again);
      }
    } finally {
      _running = false;
      if (_again && mounted) _scheduleSharp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.tileRecolor > 0 || hasLook(widget.plan.look);
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        if (size != _size || dpr != _dpr) {
          _size = size;
          _dpr = dpr;
          if (on)
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _scheduleSharp(),
            );
        }
        final hr = widget.hr;
        if (!on || hr == null) return widget.fallback;
        final sharp = _sharp, sw = _sharpWindow;
        final full = Rect.fromLTWH(
          0,
          0,
          widget.plan.baseWidth,
          widget.plan.baseHeight,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _MovedImagePainter(hr, full, widget.window)),
            if (sharp != null &&
                sw != null &&
                _sharpContent == _content &&
                _needsSharper)
              CustomPaint(
                painter: _MovedImagePainter(sharp, sw, widget.window),
              ),
          ],
        );
      },
    );
  }
}

/// Draws a picture rendered for window [from] where it falls in window [to].
class _MovedImagePainter extends CustomPainter {
  _MovedImagePainter(this.image, this.from, this.to);
  final ui.Image image;
  final Rect from, to;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / to.width, sy = size.height / to.height;
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        (from.left - to.left) * sx,
        (from.top - to.top) * sy,
        from.width * sx,
        from.height * sy,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _MovedImagePainter old) =>
      old.image != image || old.from != from || old.to != to;
}
