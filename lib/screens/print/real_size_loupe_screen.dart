import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../mosaic/preview_painter.dart' show centerCropSrc;
import '../../mosaic/hires_tiles.dart';
import '../../mosaic/cell_recolor_cache.dart';
import '../../mosaic/recolor_bake.dart';
import '../../mosaic/tile_recolor.dart';
import '../../mosaic/types.dart';
import '../../print/print_catalog.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Shows the cropped mosaic at **true physical print scale** — each photo-tile
/// at the size it will be on the finished print ([printLongEdgeCm] on the long
/// edge). Drag to pan.
///
/// Renders the plan + tile images *directly* (not a flattened raster), so tiles
/// stay sharp at the magnification — limited only by the tile thumbnails.
class RealSizeLoupeScreen extends StatefulWidget {
  const RealSizeLoupeScreen({
    super.key,
    required this.plan,
    required this.tileImages,
    required this.tintStrength,
    required this.cropNormalized,
    required this.printLongEdgeCm,
    this.overlay,
    this.fetchTile,
  });

  /// A tile's stored photo by tile id, for sharp copies at real print size (the
  /// thumbnails blur there). Null = thumbnails only.
  final Future<Uint8List?> Function(String tileId)? fetchTile;

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final double tintStrength;

  /// Crop region in 0..1 of the base image.
  final Rect cropNormalized;
  final double printLongEdgeCm;
  final ui.Image? overlay;

  @override
  State<RealSizeLoupeScreen> createState() => _RealSizeLoupeScreenState();
}

class _RealSizeLoupeScreenState extends State<RealSizeLoupeScreen> {
  Offset? _center; // window centre in base pixels
  late final HiResTiles? _hiRes = widget.fetchTile == null
      ? null
      : HiResTiles(fetch: widget.fetchTile!);

  /// The whole mosaic recoloured once; dragging only moves it.
  final HrRecolorCache _hrRecolor = HrRecolorCache();

  /// Sharp recoloured copies of the cells on screen — rendered once each, so dragging
  /// only draws finished images.
  final CellRecolorCache _cellCache = CellRecolorCache();

  @override
  void initState() {
    super.initState();
    _hrRecolor.addListener(_onHr);
  }

  void _onHr() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hiRes?.dispose();
    _hrRecolor.removeListener(_onHr);
    _hrRecolor.dispose();
    _cellCache.dispose();
    super.dispose();
  }

  Rect get _cropBase {
    final c = widget.cropNormalized;
    return Rect.fromLTWH(
      c.left * widget.plan.baseWidth,
      c.top * widget.plan.baseHeight,
      c.width * widget.plan.baseWidth,
      c.height * widget.plan.baseHeight,
    );
  }

  /// Logical screen pixels per base pixel for true print scale.
  double get _scale {
    final crop = _cropBase;
    final cmPerBasePx =
        widget.printLongEdgeCm / math.max(crop.width, crop.height);
    return cmPerBasePx * kLogicalPxPerCm;
  }

  Offset _clamp(Offset c, Size windowBase) {
    final crop = _cropBase;
    final hw = windowBase.width / 2, hh = windowBase.height / 2;
    final cx = windowBase.width >= crop.width
        ? crop.center.dx
        : c.dx.clamp(crop.left + hw, crop.right - hw);
    final cy = windowBase.height >= crop.height
        ? crop.center.dy
        : c.dy.clamp(crop.top + hh, crop.bottom - hh);
    return Offset(cx, cy);
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scale;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Actual print size'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final windowBase = Size(size.width / scale, size.height / scale);
            _center = _clamp(_center ?? _cropBase.center, windowBase);
            final win = Rect.fromCenter(
              center: _center!,
              width: windowBase.width,
              height: windowBase.height,
            );

            return GestureDetector(
              onPanUpdate: (d) {
                setState(() {
                  _center = _clamp(_center! - d.delta / scale, windowBase);
                });
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The web's in-cell tile recolour over the live painter — the print
                  // is rendered with it, so the real-size view has to show it too.
                  Builder(
                    builder: (context) {
                      _hrRecolor.request(
                        plan: widget.plan,
                        tileImages: widget.tileImages,
                        tileRecolor: widget.plan.tileRecolor,
                        outputSaturation: widget.plan.outputSaturation,
                        tintStrength: widget.tintStrength,
                        overlay: widget.overlay,
                      );
                      _cellCache.configure(
                        plan: widget.plan,
                        tileImages: widget.tileImages,
                        hiRes: _hiRes,
                        tileRecolor: widget.plan.tileRecolor,
                        outputSaturation: widget.plan.outputSaturation,
                      );
                      final hr = _hrRecolor.image;
                      if (widget.plan.tileRecolor > 0 &&
                          widget.tintStrength == 0 &&
                          hr != null) {
                        return CustomPaint(
                          painter: RecoloredZoomPainter(
                            plan: widget.plan,
                            hr: hr,
                            cache: _cellCache,
                            window: win,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(
                              context,
                            ),
                          ),
                        );
                      }
                      return RecoloredMosaicView(
                        plan: widget.plan,
                        tileImages: widget.tileImages,
                        tileCrops: widget.plan.tileCrops,
                        window: win,
                        tileRecolor: widget.plan.tileRecolor,
                        outputSaturation: widget.plan.outputSaturation,
                        tintStrength: widget.tintStrength,
                        overlay: widget.overlay,
                        hiRes: _hiRes,
                        hr: (() {
                          _hrRecolor.request(
                            plan: widget.plan,
                            tileImages: widget.tileImages,
                            tileRecolor: widget.plan.tileRecolor,
                            outputSaturation: widget.plan.outputSaturation,
                            tintStrength: widget.tintStrength,
                            overlay: widget.overlay,
                          );
                          return _hrRecolor.image;
                        })(),
                        fallback: CustomPaint(
                          painter: _LoupePainter(
                            plan: widget.plan,
                            tileImages: widget.tileImages,
                            overlay: widget.overlay,
                            tintStrength: widget.tintStrength,
                            windowBase: win,
                            scale: scale,
                            hiRes: _hiRes,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(
                              context,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    left: AppSpacing.x4,
                    right: AppSpacing.x4,
                    top: AppSpacing.x3,
                    child: Text(
                      'Tiles shown at their real printed size on a '
                      '~${widget.printLongEdgeCm.round()} cm print.',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: AppSpacing.x4,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.x3,
                          vertical: AppSpacing.x2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          'Drag to explore',
                          style: AppTypography.caption.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LoupePainter extends CustomPainter {
  _LoupePainter({
    required this.plan,
    required this.tileImages,
    required this.overlay,
    required this.tintStrength,
    required this.windowBase,
    required this.scale,
    this.hiRes,
    this.devicePixelRatio = 3,
  }) : super(
         // Recolour needs the tile colour grids; sharp copies repaint as they land.
         repaint: hiRes == null
             ? tileColorGridsVersion
             : Listenable.merge([tileColorGridsVersion, hiRes.version]),
       );

  final HiResTiles? hiRes;
  final double devicePixelRatio;

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? overlay;
  final double tintStrength;
  final Rect windowBase;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-windowBase.left * scale, -windowBase.top * scale);
    canvas.scale(scale, scale);

    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = false;

    for (var i = 0; i < plan.placements.length; i++) {
      final p = plan.placements[i];
      // Cull placements outside the visible window (in base coords).
      if (p.x + p.width < windowBase.left ||
          p.x > windowBase.right ||
          p.y + p.height < windowBase.top ||
          p.y > windowBase.bottom) {
        continue;
      }
      // Overdrawn by ~half a logical px (in base units) so neighbours overlap and no
      // hairline of background shows where two cells meet on a fractional pixel.
      final dst = Rect.fromLTWH(
        p.x,
        p.y,
        p.width,
        p.height,
      ).inflate(0.5 / scale);
      final thumb = tileImages[p.tileId];
      var img = thumb;
      final hr = hiRes;
      if (thumb != null && hr != null) {
        final need = math.max(p.width, p.height) * scale * devicePixelRatio;
        if (need > math.max(thumb.width, thumb.height) * 1.25) {
          final sharp = hr.get(p.tileId, need);
          if (sharp != null) {
            img = sharp;
          } else {
            hr.want(p.tileId, need);
          }
        }
      }
      if (img == null) {
        final c = p.regionAvgColor;
        if (c != null) {
          canvas.drawRect(
            dst,
            Paint()
              ..color = Color.fromRGBO(
                c[0].round(),
                c[1].round(),
                c[2].round(),
                1,
              ),
          );
        }
        continue;
      }
      // Pulled in by half a texel so filtered sampling never reads past the crop.
      var src = centerCropSrc(
        img,
        p.width / p.height,
        topCrop: plan.cropPortraitTop,
      );
      if (src.width > 2 && src.height > 2) src = src.deflate(0.5);
      // Tile recolouring — same as the studio preview and the print render, as a colour
      // matrix on the tile's own draw (cached per cell).
      paint.colorFilter = plan.hexagon
          ? null
          : cellRecolorFilter(
              plan: plan,
              index: i,
              count: plan.placements.length,
              crops: null,
              img: img,
              src: src,
              region: p.regionAvgColor,
              strength: plan.tileRecolor,
            );
      canvas.drawImageRect(img, src, dst, paint);
      paint.colorFilter = null;
    }

    if (overlay != null && tintStrength > 0) {
      canvas.drawImageRect(
        overlay!,
        Rect.fromLTWH(
          0,
          0,
          overlay!.width.toDouble(),
          overlay!.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, plan.baseWidth, plan.baseHeight),
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, tintStrength)
          ..filterQuality = FilterQuality.high,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoupePainter old) =>
      old.hiRes != hiRes ||
      old.windowBase != windowBase ||
      old.scale != scale ||
      old.plan != plan ||
      old.tintStrength != tintStrength;
}
