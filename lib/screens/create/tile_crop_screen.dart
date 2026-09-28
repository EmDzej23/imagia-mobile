import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../mosaic/hexagon.dart';
import '../../mosaic/shared.dart' show CropShape;
import '../../mosaic/types.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/confirm_dialog.dart';

/// Choose which part of one tile the mosaic uses.
///
/// NON-DESTRUCTIVE: nothing here rewrites the uploaded file. The result is a
/// [TileCrop] — four fractions of the tile's natural size — that the painters and the
/// server compositor read when drawing, so a crop can be changed or cleared at any
/// time and preview and export follow together.
///
/// The crop is a SQUARE IN PIXELS (`w * imageW == h * imageH`), which is what square
/// mode wants: a square cell cover-fits a square rect to itself, so what is framed
/// here is exactly what lands in the mosaic. Square mode is also the only mode that
/// offers this, mirroring the web.
///
/// Pops:
///  - `TileCropResult.crop(c)` — use this crop
///  - `TileCropResult.cleared()` — go back to the automatic crop
///  - `TileCropResult.removed()` — delete the tile (removal lives with the tile's
///    other actions, so the thumbnail strip needs no ✕ of its own)
///  - `null` — cancelled, change nothing
class TileCropResult {
  const TileCropResult._(this.crop, this.cleared, this.removed);

  const TileCropResult.crop(TileCrop c) : this._(c, false, false);
  const TileCropResult.cleared() : this._(null, true, false);
  const TileCropResult.removed() : this._(null, false, true);

  final TileCrop? crop;
  final bool cleared;
  final bool removed;
}

class TileCropScreen extends StatefulWidget {
  const TileCropScreen({
    super.key,
    required this.image,
    required this.title,
    this.initial,
    this.cropPortraitTop = true,
    this.cellAspect = 1.0,
    this.cellShape,
  });

  /// The tile's thumbnail. Crops are fractions, so editing the thumbnail and
  /// applying the result to the full-resolution file is exact.
  final ui.Image image;
  final String title;

  /// The tile's current crop, if it has one — the editor opens ON it rather than
  /// resetting, so re-opening a cropped tile shows what was chosen.
  final TileCrop? initial;

  /// Seeds an UNCROPPED tile with the automatic framing (square layout anchors a
  /// portrait tile to its top), so the editor opens showing what the mosaic is
  /// already using instead of jumping to a different crop.
  final bool cropPortraitTop;

  /// Aspect (w/h) of the CELL this tile will be drawn into.
  ///
  /// The box used to be square always, which was right when cropping only existed in
  /// square mode. It is wrong everywhere else: the renderer cover-crops the chosen
  /// rectangle to the cell, so framing a square for a 3:2 cell silently throws away a
  /// third of what the user picked. Matching the cell here means what is framed is what
  /// appears.
  final double cellAspect;

  /// Cell SHAPE, when it is not a rectangle.
  ///
  /// The box already carries the cell's aspect, but for a hexagon that is only half the
  /// story: the six corners of the box are cut off by the cell, so a plain rectangle
  /// frames a quarter of the area that will never be drawn. The editor outlines the real
  /// hexagon instead.
  final CropShape? cellShape;

  @override
  State<TileCropScreen> createState() => _TileCropScreenState();
}

class _TileCropScreenState extends State<TileCropScreen> {
  /// Zoom, where 1 = the largest square that fits the image. Higher = tighter.
  late double _zoom;

  /// Centre of the crop, in normalised image coordinates.
  late double _cx;
  late double _cy;

  double _zoomAtGestureStart = 1;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    if (c != null) {
      _zoom = _zoomForCrop(c);
      _cx = c.x + c.w / 2;
      _cy = c.y + c.h / 2;
    } else {
      // The automatic crop: centred, or anchored to the top for a portrait tile
      // in square layout — the same rule `centerCropSrc` applies when there is no
      // manual crop, so opening the editor does not move the picture.
      final portrait = widget.image.height > widget.image.width;
      _zoom = 1;
      _cx = 0.5;
      _cy = portrait && widget.cropPortraitTop ? _side().h / 2 : 0.5;
    }
    _clamp();
  }

  double get _imgW => widget.image.width.toDouble();
  double get _imgH => widget.image.height.toDouble();

  /// The largest box of the CELL'S aspect that fits the image, in pixels.
  ({double w, double h}) _maxBoxPx() {
    final ar = widget.cellAspect;
    // Fit by whichever axis binds first, so the box is always fully inside the photo.
    if (_imgW / _imgH > ar) return (w: _imgH * ar, h: _imgH);
    return (w: _imgW, h: _imgW / ar);
  }

  /// The crop's size in normalised terms at the current zoom. Kept as one zoom value so
  /// the box can only ever have the cell's aspect — a gesture cannot deform it.
  ({double w, double h}) _side() {
    final box = _maxBoxPx();
    return (w: box.w / _zoom / _imgW, h: box.h / _zoom / _imgH);
  }

  double _zoomForCrop(TileCrop c) {
    final box = _maxBoxPx();
    final wPx = c.w * _imgW;
    if (wPx <= 0) return 1;
    return (box.w / wPx).clamp(1.0, 8.0);
  }

  /// Keep the square inside the image on both axes.
  void _clamp() {
    final s = _side();
    _cx = _cx.clamp(s.w / 2, 1 - s.w / 2);
    _cy = _cy.clamp(s.h / 2, 1 - s.h / 2);
  }

  TileCrop get _crop {
    final s = _side();
    return TileCrop(_cx - s.w / 2, _cy - s.h / 2, s.w, s.h);
  }

  void _onScaleStart(ScaleStartDetails d) => _zoomAtGestureStart = _zoom;

  void _onScaleUpdate(ScaleUpdateDetails d, double viewport) {
    setState(() {
      if (d.scale != 1.0) {
        _zoom = (_zoomAtGestureStart * d.scale).clamp(1.0, 8.0);
      }
      // A drag of N screen pixels moves the picture by the fraction of the crop
      // those pixels represent — so panning tracks the finger at every zoom level.
      final s = _side();
      _cx -= d.focalPointDelta.dx / viewport * s.w;
      _cy -= d.focalPointDelta.dy / viewport * s.h;
      _clamp();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, TileCropResult.crop(_crop)),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4, vertical: AppSpacing.x2),
            child: Text(
              'Pinch to zoom, drag to choose what the mosaic uses. '
              'Your original photo is never changed.',
              style: AppTypography.caption,
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // The preview box takes the CELL'S aspect, not a square: the
                  // renderer cover-crops the chosen rectangle to the cell, so a square
                  // preview of a 3:2 cell shows something the mosaic will never draw.
                  final ar = widget.cellAspect;
                  var boxW = constraints.maxWidth;
                  var boxH = boxW / ar;
                  if (boxH > constraints.maxHeight) {
                    boxH = constraints.maxHeight;
                    boxW = boxH * ar;
                  }
                  // Pan still tracks the finger against the SHORT side.
                  final viewport = boxW < boxH ? boxW : boxH;
                  return GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: (d) => _onScaleUpdate(d, viewport),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      child: SizedBox(
                        width: boxW,
                        height: boxH,
                        child: CustomPaint(
                          painter: _CropPainter(
                              widget.image, _crop, widget.cellShape),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(
                        context, const TileCropResult.cleared()),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset'),
                  ),
                  TextButton.icon(
                    onPressed: _confirmRemove,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary),
                    label: const Text('Remove photo'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove() async {
    // Same rule as everywhere else in the app: removal always asks first.
    final ok = await confirmDestructive(
      context,
      title: 'Remove this photo?',
      message:
          'It will no longer be used in your mosaic. You can add it again later.',
    );
    if (ok && mounted) {
      Navigator.pop(context, const TileCropResult.removed());
    }
  }
}

/// Draws the chosen rectangle filling the square viewport — i.e. exactly what the
/// mosaic will draw into a square cell, at a size you can judge.
class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop, this.cellShape);

  final ui.Image image;
  final TileCrop crop;

  /// Non-rectangular cell shapes get their true outline drawn over the box — see
  /// [TileCropScreen.cellShape].
  final CropShape? cellShape;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      crop.x * image.width,
      crop.y * image.height,
      crop.w * image.width,
      crop.h * image.height,
    );
    canvas.drawImageRect(image, src, Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium);

    // Thirds, to compose by. Deliberately faint — the picture is the point.
    final guide = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), guide);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guide);
    }

    // The hexagon the cell will actually keep. The six corner triangles it greys out
    // are exactly what the renderer discards — without this the editor frames a
    // quarter more area than will ever be drawn.
    if (cellShape == CropShape.hex) {
      final pts = hexCorners(
          size.width / 2, size.height / 2, size.width, size.height);
      final hex = Path()..moveTo(pts[0][0], pts[0][1]);
      for (var i = 1; i < 6; i++) {
        hex.lineTo(pts[i][0], pts[i][1]);
      }
      hex.close();
      // Even-odd: the box MINUS the hexagon, i.e. the discarded corners.
      final corners = Path.combine(
          PathOperation.difference, Path()..addRect(Offset.zero & size), hex);
      canvas.drawPath(corners, Paint()..color = const Color(0x8C020617));
      canvas.drawPath(
          hex,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF22D3EE));
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.crop != crop || old.image != image || old.cellShape != cellShape;
}
