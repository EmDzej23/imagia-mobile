import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A [CustomPaint] for still pictures that are expensive to draw: the painter runs
/// once, into an image, and every later frame just draws that image.
///
/// The settled mosaic is thousands of tile draws, each with its own recolour matrix.
/// The renderer keeps no raster cache, so without this the GPU re-draws all of them on
/// EVERY frame anything on screen moves — the planning spinner, the settings list
/// scrolling, a slider. On low-end Android GPUs that was ~110 ms a frame (≈8 fps, the
/// whole studio feeling frozen). Repainted only when the painter says so
/// ([CustomPainter.shouldRepaint] or its repaint listenable), or the size changes.
///
/// It can also play a reveal from that same image: with [pieces] (the cells, in this
/// widget's coordinates) and [place] (where cell i is, and how opaque, at [appear]),
/// each cell's slice of the finished picture is drawn where it is in the animation —
/// all of them in one atlas draw, and ending exactly on the finished picture.
class SnapshotPaint extends LeafRenderObjectWidget {
  const SnapshotPaint({
    super.key,
    required this.painter,
    this.appear = 1,
    this.pieces,
    this.place,
  });

  final CustomPainter painter;
  final double appear;
  final List<Rect> Function(Size size)? pieces;
  final ({Rect rect, double opacity})? Function(int i, Rect cell, double appear)?
  place;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSnapshotPaint(painter, MediaQuery.devicePixelRatioOf(context))
        ..reveal = (appear, pieces, place);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSnapshotPaint)
      ..painter = painter
      ..dpr = MediaQuery.devicePixelRatioOf(context)
      ..reveal = (appear, pieces, place);
  }
}

typedef _Reveal = (
  double appear,
  List<Rect> Function(Size size)? pieces,
  ({Rect rect, double opacity})? Function(int i, Rect cell, double appear)? place,
);

class _RenderSnapshotPaint extends RenderBox {
  _RenderSnapshotPaint(this._painter, this._dpr);

  CustomPainter _painter;
  double _dpr;
  ui.Image? _image;
  Size? _imageSize;
  _Reveal _reveal = (1, null, null);
  List<Rect>? _pieces;
  Size? _piecesSize;

  set reveal(_Reveal r) {
    final was = _reveal.$1;
    _reveal = r;
    if (r.$1 != was) markNeedsPaint();
  }

  set painter(CustomPainter p) {
    if (identical(p, _painter)) return;
    final old = _painter;
    _painter = p;
    if (attached) {
      old.removeListener(_invalidate);
      p.addListener(_invalidate);
    }
    if (p.runtimeType != old.runtimeType || p.shouldRepaint(old)) _invalidate();
  }

  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    _invalidate();
  }

  void _invalidate() {
    _drop();
    markNeedsPaint();
  }

  void _drop() {
    _image?.dispose();
    _image = null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _painter.addListener(_invalidate);
  }

  @override
  void detach() {
    _painter.removeListener(_invalidate);
    super.detach();
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    if (_image == null || _imageSize != size) {
      _drop();
      final w = math.max(1, (size.width * _dpr).ceil());
      final h = math.max(1, (size.height * _dpr).ceil());
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(w / size.width, h / size.height);
      _painter.paint(canvas, size);
      final pic = rec.endRecording();
      // Rasterised once, on the GPU, the first time it is drawn.
      _image = pic.toImageSync(w, h);
      pic.dispose();
      _imageSize = size;
    }
    final img = _image!;
    final (appear, pieces, place) = _reveal;
    if (appear < 1 && pieces != null && place != null) {
      _paintReveal(context.canvas, offset, img, appear, pieces, place);
      return;
    }
    context.canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      offset & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _paintReveal(
    Canvas canvas,
    Offset offset,
    ui.Image img,
    double appear,
    List<Rect> Function(Size size) pieces,
    ({Rect rect, double opacity})? Function(int i, Rect cell, double appear) place,
  ) {
    if (_piecesSize != size) {
      _pieces = pieces(size);
      _piecesSize = size;
    }
    final cells = _pieces!;
    final kx = img.width / size.width, ky = img.height / size.height;
    final xf = Float32List(cells.length * 4);
    final src = Float32List(cells.length * 4);
    final colors = Int32List(cells.length);
    var n = 0;
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      final at = place(i, c, appear);
      if (at == null || at.opacity <= 0 || c.width <= 0) continue;
      final k = at.rect.width / c.width; // the slice's scale on screen
      xf[n * 4] = k / kx;
      xf[n * 4 + 1] = 0;
      xf[n * 4 + 2] = offset.dx + at.rect.left;
      xf[n * 4 + 3] = offset.dy + at.rect.top;
      src[n * 4] = c.left * kx;
      src[n * 4 + 1] = c.top * ky;
      src[n * 4 + 2] = c.right * kx;
      src[n * 4 + 3] = c.bottom * ky;
      colors[n] = (((at.opacity * 255).round().clamp(0, 255)) << 24) | 0xFFFFFF;
      n++;
    }
    if (n == 0) return;
    canvas.drawRawAtlas(
      img,
      Float32List.sublistView(xf, 0, n * 4),
      Float32List.sublistView(src, 0, n * 4),
      Int32List.sublistView(colors, 0, n),
      BlendMode.modulate,
      null,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
}
