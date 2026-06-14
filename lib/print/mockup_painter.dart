import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'print_catalog.dart';

final Float64List _identity = Float64List.fromList(
    <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

/// Renders a straight-on "wall art" mockup: the cropped mosaic shown as a
/// framed print / canvas / poster / metal print, hung on a wall.
///
/// v1 is fully procedural (no template assets) — the sandwich technique
/// (wall → art → product edge) is the same one we'll use with real photographic
/// templates later; only the layers change.
class MockupPainter extends CustomPainter {
  MockupPainter({
    required this.mosaic,
    required this.cropSrc,
    required this.type,
    required this.aspect,
    this.frameColor = const Color(0xFF1C1C1E),
    this.canvasWrap,
    this.wall,
  });

  /// The rendered mosaic image.
  final ui.Image mosaic;

  /// Region of [mosaic] (in mosaic pixels) to show — the user's crop.
  final ui.Rect cropSrc;

  final PrintType type;

  /// Art aspect ratio (width / height).
  final double aspect;

  /// Frame colour for the framed-print mockup.
  final Color frameColor;

  /// Canvas wrap (ImageWrap / Black / White) — drives the 3D edge.
  final String? canvasWrap;

  /// Wall photo for the background; falls back to a procedural wall if null.
  final ui.Image? wall;

  @override
  void paint(Canvas canvas, Size size) {
    _drawWall(canvas, size);

    // Fit the art (at [aspect]) into a centred region, leaving wall around it.
    var artH = size.height * 0.66;
    var artW = artH * aspect;
    final maxW = size.width * 0.82;
    if (artW > maxW) {
      artW = maxW;
      artH = artW / aspect;
    }
    final center = Offset(size.width / 2, size.height * 0.47);
    final art = Rect.fromCenter(center: center, width: artW, height: artH);

    switch (type) {
      case PrintType.framedPrint:
        _drawFramed(canvas, art);
      case PrintType.canvas:
        _drawCanvas(canvas, art);
      case PrintType.poster:
        _drawPoster(canvas, art);
      case PrintType.metal:
        _drawMetal(canvas, art);
    }
  }

  // ── Layers ──────────────────────────────────────────────────────────────

  void _drawWall(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = wall;
    if (w != null) {
      // Cover-fit the wall photo.
      final src = _coverSrc(w, size);
      canvas.drawImageRect(
          w, src, rect, Paint()..filterQuality = FilterQuality.medium);
    } else {
      // Procedural fallback.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(size.width / 2, 0),
            Offset(size.width / 2, size.height),
            const [Color(0xFFEDEAE3), Color(0xFFDAD5CB)],
          ),
      );
    }
    // Slightly dim + vignette so the artwork pops off the wall.
    canvas.drawRect(rect, Paint()..color = const Color(0x1A000000));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, size.height * 0.45),
          size.width * 0.85,
          const [Color(0x00000000), Color(0x30000000)],
          const [0.55, 1.0],
        ),
    );
    // Soft floor gradient grounding the product in the lower third.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(size.width / 2, size.height * 0.6),
          Offset(size.width / 2, size.height),
          const [Color(0x00000000), Color(0x3D000000)],
        ),
    );
  }

  /// Source rect that center-cover-crops [img] to fill [size]'s aspect.
  ui.Rect _coverSrc(ui.Image img, Size size) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final targetAR = size.width / size.height;
    if (iw / ih > targetAR) {
      final sw = ih * targetAR;
      return ui.Rect.fromLTWH((iw - sw) / 2, 0, sw, ih);
    }
    final sh = iw / targetAR;
    return ui.Rect.fromLTWH(0, (ih - sh) / 2, iw, sh);
  }

  void _mosaicInto(Canvas canvas, Rect dst) {
    canvas.drawImageRect(
      mosaic,
      cropSrc,
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  void _shadow(Canvas canvas, Rect rect,
      {double blur = 22, double dy = 14, double opacity = 0.32}) {
    canvas.drawRect(
      rect.shift(Offset(0, dy)),
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
  }

  void _drawFramed(Canvas canvas, Rect art) {
    // Classic frame: the print sits directly inside the frame, no mat.
    final frame = art.width * 0.05;
    final outer = art.inflate(frame);
    _shadow(canvas, outer);
    canvas.drawRect(outer, Paint()..color = frameColor); // frame
    // Thin highlight so light frames still read against the wall.
    canvas.drawRect(
        outer,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0x22000000));
    _mosaicInto(canvas, art);
    // Subtle inner shadow where the frame meets the print, for depth.
    canvas.drawRect(
        art,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = art.width * 0.006
          ..color = const Color(0x33000000));
  }

  void _drawCanvas(Canvas canvas, Rect art0) {
    // Slight 3D slab so the gallery-wrap edge is visible. Recede the depth
    // down-right; centre the slab so it doesn't drift off the wall.
    // ~3 cm of the ~100 cm print → ~3% of the width.
    final depth = art0.width * 0.03;
    final d = Offset(depth, depth * 0.5);
    final art = art0.shift(-d / 2);
    final tr = art.topRight, br = art.bottomRight, bl = art.bottomLeft;

    // The front shows the INNER region; the outer band continues onto the
    // edges (true image-wrap: tiles run seamlessly from the face onto the side).
    final c = cropSrc;
    final bx = c.width * 0.03, by = c.height * 0.03;
    final srcFront =
        Rect.fromLTRB(c.left + bx, c.top + by, c.right - bx, c.bottom - by);

    _shadow(canvas, art.shift(d * 0.6), blur: 26, dy: 6, opacity: 0.3);

    // Right edge: continues from the front's right edge (col right-bx) outward
    // to the image edge (col right).
    _wrapEdge(canvas, [tr, br, br + d, tr + d], [
      Offset(c.right - bx, c.top + by),
      Offset(c.right - bx, c.bottom - by),
      Offset(c.right, c.bottom - by),
      Offset(c.right, c.top + by),
    ], darken: 0.20);
    // Bottom edge: from row bottom-by outward to bottom.
    _wrapEdge(canvas, [bl, br, br + d, bl + d], [
      Offset(c.left + bx, c.bottom - by),
      Offset(c.right - bx, c.bottom - by),
      Offset(c.right - bx, c.bottom),
      Offset(c.left + bx, c.bottom),
    ], darken: 0.34);

    // Front face (inner region) + weave.
    canvas.drawImageRect(
        mosaic, srcFront, art, Paint()..filterQuality = FilterQuality.high);
    _weave(canvas, art);
  }

  void _wrapEdge(Canvas canvas, List<Offset> quad, List<Offset> tex,
      {required double darken}) {
    final path = Path()..addPolygon(quad, true);
    final wrap = canvasWrap;
    if (wrap == 'Black' || wrap == 'White') {
      canvas.drawPath(path,
          Paint()..color = wrap == 'Black' ? Colors.black : Colors.white);
    } else {
      // ImageWrap / MirrorWrap: map the image edge strip onto the side face.
      final verts = ui.Vertices(
        ui.VertexMode.triangleFan,
        quad,
        textureCoordinates: tex,
      );
      canvas.drawVertices(
        verts,
        BlendMode.srcOver,
        Paint()
          ..shader = ui.ImageShader(
              mosaic, TileMode.clamp, TileMode.clamp, _identity,
              filterQuality: FilterQuality.medium),
      );
    }
    // Shade the receding face.
    canvas.drawPath(path, Paint()..color = Color.fromRGBO(0, 0, 0, darken));
  }

  void _weave(Canvas canvas, Rect art) {
    canvas.save();
    canvas.clipRect(art);
    final p = Paint()
      ..color = const Color(0x0EFFFFFF)
      ..strokeWidth = 1;
    const step = 5.0;
    for (var x = art.left; x < art.right; x += step) {
      canvas.drawLine(Offset(x, art.top), Offset(x, art.bottom), p);
    }
    final p2 = Paint()
      ..color = const Color(0x0A000000)
      ..strokeWidth = 1;
    for (var y = art.top; y < art.bottom; y += step) {
      canvas.drawLine(Offset(art.left, y), Offset(art.right, y), p2);
    }
    canvas.restore();
  }

  void _drawPoster(Canvas canvas, Rect art) {
    // Thin white border, lying nearly flat (soft, low shadow).
    final border = art.width * 0.02;
    final paper = art.inflate(border);
    _shadow(canvas, paper, blur: 14, dy: 8, opacity: 0.20);
    canvas.drawRect(paper, Paint()..color = const Color(0xFFFBFAF7));
    _mosaicInto(canvas, art);
  }

  void _drawMetal(Canvas canvas, Rect art) {
    // Floats off the wall: larger, softer, more offset shadow.
    _shadow(canvas, art, blur: 30, dy: 22, opacity: 0.30);
    _mosaicInto(canvas, art);
    // Glossy diagonal sheen.
    canvas.save();
    canvas.clipRect(art);
    canvas.drawRect(
      art,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.linear(
          art.topLeft,
          art.bottomRight,
          const [Color(0x00FFFFFF), Color(0x33FFFFFF), Color(0x00FFFFFF)],
          const [0.25, 0.5, 0.62],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MockupPainter old) =>
      old.mosaic != mosaic ||
      old.cropSrc != cropSrc ||
      old.type != type ||
      old.aspect != aspect ||
      old.frameColor != frameColor ||
      old.canvasWrap != canvasWrap ||
      old.wall != wall;
}
