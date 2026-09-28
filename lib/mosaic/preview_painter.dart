import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'shared.dart' show CropShape, cropForTile, saturationColorFilter;
import 'hexagon.dart';
import 'rhombille.dart' show faceShade;
import 'types.dart';

/// Deterministic pseudo-random in [0, 1) from an int — used to scatter the
/// tile-reveal order so the mosaic "assembles" rather than wiping in.
double _hash01(int n) {
  var x = (n * 2654435761) & 0xFFFFFFFF;
  x ^= x >> 15;
  x = (x * 2246822519) & 0xFFFFFFFF;
  x ^= x >> 13;
  return (x & 0xFFFFFF) / 0x1000000;
}

/// Geometry of the "contain" fit used to place the mosaic inside a canvas.
typedef MosaicFit = ({double scale, double ox, double oy, double drawW, double drawH});

MosaicFit computeMosaicFit(Size size, double baseW, double baseH) {
  final sx = size.width / baseW;
  final sy = size.height / baseH;
  final s = sx < sy ? sx : sy;
  final drawW = baseW * s;
  final drawH = baseH * s;
  return (
    scale: s,
    ox: (size.width - drawW) / 2,
    oy: (size.height - drawH) / 2,
    drawW: drawW,
    drawH: drawH,
  );
}

/// Source rect that cover-crops [img] to the target [cellAR] (w/h). When [topCrop]
/// is set (square layout), a PORTRAIT tile is cropped to its TOP (keeps faces/heads)
/// instead of its centre; landscape tiles are unaffected (still centred horizontally).
///
/// A manual [crop] overrides all of that: the chosen rectangle is cover-fitted to the
/// cell, centred WITHIN the crop. Bit-exact port of the web's `resolveTileSourceRect`,
/// so the on-device preview and the server export frame every tile identically.
Rect centerCropSrc(ui.Image img, double cellAR,
    {bool topCrop = false, TileCrop? crop}) {
  final tw = img.width.toDouble();
  final th = img.height.toDouble();

  if (crop != null) {
    // Clamp into the image: a stale crop (e.g. the tile was replaced by a
    // differently-shaped file) must never produce an out-of-bounds source rect,
    // which silently draws nothing.
    final cw = crop.w.clamp(0.01, 1.0);
    final ch = crop.h.clamp(0.01, 1.0);
    final cx = crop.x.clamp(0.0, 1.0 - cw);
    final cy = crop.y.clamp(0.0, 1.0 - ch);

    final rw = cw * tw;
    final rh = ch * th;
    final rx = cx * tw;
    final ry = cy * th;

    if (rw / rh > cellAR) {
      final sw = rh * cellAR;
      return Rect.fromLTWH(rx + (rw - sw) / 2, ry, sw, rh);
    }
    final sh = rw / cellAR;
    return Rect.fromLTWH(rx, ry + (rh - sh) / 2, rw, sh);
  }

  final tileAR = tw / th;
  if (tileAR > cellAR) {
    // Wider than the cell → crop the sides, keep full height (landscape → centre).
    final srcW = th * cellAR;
    return Rect.fromLTWH((tw - srcW) / 2, 0, srcW, th);
  }
  // Taller than the cell → crop top/bottom. Anchor to the top in square layout.
  final srcH = tw / cellAR;
  return Rect.fromLTWH(0, topCrop ? 0 : (th - srcH) / 2, tw, srcH);
}

/// Renders a [SlimMosaicPlan] on a canvas: each placement draws its matched
/// tile thumbnail, center-cropped to the cell's aspect ratio, with an optional
/// tinted overlay of the base image (the `tintStrength` setting).
/// The hexagon's bounding box from its SAMPLE rect — the inverse of `hexSampleRect`,
/// in destination pixels. The stored rect is only 59% of the drawn cell.
Rect _hexBoundsFor(Rect sample) {
  final s = sample.height / hexSampleHPerS;
  return Rect.fromCenter(
      center: sample.center, width: s * 2, height: s * math.sqrt(3));
}

/// Clip path for the flat-top hexagon inscribed in [rect].
///
/// Grown by a pixel on each side so neighbours overlap: without it the antialiased
/// edges of two adjacent cells do not sum back to full opacity and the background shows
/// through as dark hairlines along every seam. Same reason, and the same constant, as
/// the server compositor.
Path _hexClipPath(Rect rect) {
  final pts = hexCorners(rect.center.dx, rect.center.dy,
      rect.width + hexOverdraw * 2, rect.height + hexOverdraw * 2);
  final path = Path()..moveTo(pts[0][0], pts[0][1]);
  for (var i = 1; i < 6; i++) {
    path.lineTo(pts[i][0], pts[i][1]);
  }
  return path..close();
}

/// Draw ONE rhombus of a 3D cube, in `rhombille` mode.
///
/// A rhombus is a unit square under an affine map, so the photo goes on with a single
/// transform + clip. The basis vectors are the cell's own edge vectors, scaled from
/// base-image pixels into destination pixels, so the photo shears onto the facet exactly
/// as it does on the web and in the server compositor.
///
/// Per-face shading is what makes the wall read as lit solids rather than a flat pattern
/// of diamonds — see [faceShade].
void _drawRhombus(Canvas canvas, ui.Image img, SlimMosaicPlan plan,
    Map<String, TileCrop> tileCrops, SlimPlacement p, double sx, double sy,
    Offset origin, Paint paint) {
  final q = p.quad!;
  double px(int i) => q[i * 2] * sx + origin.dx;
  double py(int i) => q[i * 2 + 1] * sy + origin.dy;

  final path = Path()..moveTo(px(0), py(0));
  for (var i = 1; i < 4; i++) {
    path.lineTo(px(i), py(i));
  }
  path.close();

  canvas.save();
  canvas.clipPath(path);

  // Corner 0 is the origin; edges 0->1 and 0->3 are the basis vectors.
  final ux = px(1) - px(0), uy = py(1) - py(0);
  final vx = px(3) - px(0), vy = py(3) - py(0);
  // The shear maps a SQUARE source onto the face, so 3D cubes share the square crop
  // slot — the same decision the web makes.
  final src = centerCropSrc(img, 1, crop: cropForTile(tileCrops, p.tileId, 1));
  final side = math.min(src.width, src.height);

  // Map a `side`-sized destination, NOT a 1x1 one: a unit-square destination rasterises
  // the image at one pixel and then magnifies it, producing a smear rather than a photo.
  canvas.transform(Float64List.fromList([
    ux / side, uy / side, 0, 0, //
    vx / side, vy / side, 0, 0, //
    0, 0, 1, 0, //
    px(0), py(0), 0, 1, //
  ]));
  canvas.drawImageRect(
      img,
      Rect.fromLTWH(src.left + (src.width - side) / 2,
          src.top + (src.height - side) / 2, side, side),
      Rect.fromLTWH(0, 0, side, side),
      paint);
  canvas.restore();

  final shade = faceShade[p.face] ?? 1.0;
  if (shade < 1) {
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(
        path, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - shade));
    canvas.restore();
  }
}

/// Draw ONE mosaic cell. Shared by both painters so the hexagon handling — and the crop
/// slot it reads — cannot drift between the preview and the loupe.
void _drawCell(Canvas canvas, ui.Image img, SlimMosaicPlan plan,
    Map<String, TileCrop> tileCrops, SlimPlacement p, Rect rect, Paint paint,
    {double? rhombSx, double? rhombSy, Offset rhombOrigin = Offset.zero}) {
  // 3D cubes: the cell is a parallelogram, drawn before the rectangular path because
  // none of that applies — there is no axis-aligned destination rect.
  if (p.quad != null && rhombSx != null && rhombSy != null) {
    _drawRhombus(
        canvas, img, plan, tileCrops, p, rhombSx, rhombSy, rhombOrigin, paint);
    return;
  }
  // Hexagon mode: cover-fit the hexagon's BOUNDING BOX and clip. Fitting the sample
  // rect instead would leave the six corners empty, and a honeycomb with transparent
  // corners reads as a rendering fault rather than a style.
  final hex = plan.hexagon ? _hexBoundsFor(rect) : null;
  final dst = hex ?? rect;
  if (hex != null) {
    canvas.save();
    canvas.clipPath(_hexClipPath(hex));
  }
  canvas.drawImageRect(
      img,
      centerCropSrc(img, dst.width / dst.height,
          topCrop: plan.cropPortraitTop,
          // Crops are per CELL SHAPE — the slot must match what the cell is, or a
          // portrait cell reads back the square mode's framing.
          crop: cropForTile(tileCrops, p.tileId, p.width / p.height,
              plan.hexagon ? CropShape.hex : null)),
      dst,
      paint);
  if (hex != null) canvas.restore();
}

class MosaicPreviewPainter extends CustomPainter {
  MosaicPreviewPainter({
    required this.plan,
    required this.tileImages,
    this.baseImage,
    double? tintStrength,
    double? outputSaturation,
    this.appear = 1.0,
    Map<String, TileCrop>? tileCrops,
  })  : tintStrength = tintStrength ?? plan.tintStrength,
        outputSaturation = outputSaturation ?? plan.outputSaturation,
        tileCrops = tileCrops ?? plan.tileCrops;

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;

  /// Manual per-tile crops. Passed in rather than read off [plan] at paint time so
  /// [shouldRepaint] can actually see a change: editing a crop keeps the same plan
  /// object, so comparing `plan.tileCrops` would compare a field against itself.
  final Map<String, TileCrop> tileCrops;

  /// The tint overlay strength. Kept separate from [plan] so adjusting the tint
  /// slider repaints instantly without rebuilding the (matching) plan.
  final double tintStrength;

  /// Output saturation grade. Also kept separate from [plan] so the slider repaints
  /// without a replan.
  final double outputSaturation;

  /// Reveal progress 0→1. At 1 the steady-state fast path runs (no per-tile
  /// transform); below 1 tiles fade + scale + drift into place, staggered.
  final double appear;

  /// Fraction of the timeline a single tile's animation occupies.
  static const double _tileWindow = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (plan.baseWidth <= 0 || plan.baseHeight <= 0) return;
    final fit = computeMosaicFit(size, plan.baseWidth, plan.baseHeight);
    final s = fit.scale;
    final animating = appear < 1.0;

    canvas.save();
    canvas.translate(fit.ox, fit.oy);

    // Output-saturation grade over the FINISHED composite (tiles + tint) so it reads
    // as one photographic grade rather than a per-layer effect — the same order the
    // server compositor uses, so the export matches what is on screen. One layer for
    // the whole mosaic; skipped entirely at saturation 1.
    final grade = saturationColorFilter(outputSaturation);
    if (grade != null) {
      canvas.saveLayer(
          Rect.fromLTWH(0, 0, fit.drawW, fit.drawH), Paint()..colorFilter = grade);
    }

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;

    var i = -1;
    for (final p in plan.placements) {
      i++;
      final dst = Rect.fromLTWH(p.x * s, p.y * s, p.width * s, p.height * s);

      var drawRect = dst;
      double opacity = 1;
      if (animating) {
        final start = _hash01(i) * (1 - _tileWindow);
        final lt = ((appear - start) / _tileWindow).clamp(0.0, 1.0);
        if (lt <= 0) continue; // not yet revealed
        final e = Curves.easeOutCubic.transform(lt);
        opacity = e;
        final scale = 0.55 + 0.45 * e;
        final ang = _hash01(i * 2 + 1) * 2 * math.pi;
        final dist = (1 - e) * dst.width * 1.3;
        drawRect = Rect.fromCenter(
          center: dst.center.translate(
              math.cos(ang) * dist, math.sin(ang) * dist),
          width: dst.width * scale,
          height: dst.height * scale,
        );
      }

      final img = tileImages[p.tileId];
      if (img == null) {
        final c = p.regionAvgColor;
        if (c != null) {
          canvas.drawRect(
              drawRect,
              Paint()
                ..color = Color.fromRGBO(c[0].round(), c[1].round(),
                    c[2].round(), opacity));
        }
        continue;
      }
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
      _drawCell(canvas, img, plan, tileCrops, p, drawRect, paint,
          rhombSx: s, rhombSy: s);
    }

    if (baseImage != null && tintStrength > 0) {
      final src = Rect.fromLTWH(
          0, 0, baseImage!.width.toDouble(), baseImage!.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, fit.drawW, fit.drawH);
      // Fade the tint in alongside the reveal so the picture resolves last.
      final tintAlpha = tintStrength.toDouble() * appear;
      canvas.drawImageRect(
        baseImage!,
        src,
        dst,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, tintAlpha)
          ..filterQuality = FilterQuality.high,
      );
    }

    if (grade != null) canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MosaicPreviewPainter old) =>
      old.plan != plan ||
      old.baseImage != baseImage ||
      old.tintStrength != tintStrength ||
      old.outputSaturation != outputSaturation ||
      old.appear != appear ||
      !identical(old.tileCrops, tileCrops) ||
      old.tileImages.length != tileImages.length;
}

/// Draws a magnified window of the mosaic centered on a base-image point —
/// the "loupe" popup. [windowSize] is the side (in base px) of the square
/// region shown; smaller = more zoomed in.
class MosaicZoomPainter extends CustomPainter {
  MosaicZoomPainter({
    required this.plan,
    required this.tileImages,
    required this.focusX,
    required this.focusY,
    required this.windowSize,
    this.baseImage,
    this.tintStrength = 0,
    double? outputSaturation,
    Map<String, TileCrop>? tileCrops,
  })  : outputSaturation = outputSaturation ?? plan.outputSaturation,
        tileCrops = tileCrops ?? plan.tileCrops;

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;

  /// See [MosaicPreviewPainter.tileCrops] — the loupe must frame tiles the same way
  /// the picture under it does, or magnifying a tile would show a different crop.
  final Map<String, TileCrop> tileCrops;
  final double focusX;
  final double focusY;
  final double windowSize;
  final double tintStrength;
  final double outputSaturation;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / windowSize; // square popup
    final ox = size.width / 2 - focusX * s;
    final oy = size.height / 2 - focusY * s;

    canvas.clipRect(Offset.zero & size);
    // Same grade as the full preview, so the loupe never reads a different colour
    // from the picture behind it.
    final grade = saturationColorFilter(outputSaturation);
    if (grade != null) {
      canvas.saveLayer(Offset.zero & size, Paint()..colorFilter = grade);
    }
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = false;

    for (final p in plan.placements) {
      final dx = p.x * s + ox;
      final dy = p.y * s + oy;
      final dw = p.width * s;
      final dh = p.height * s;
      if (dx + dw < 0 || dy + dh < 0 || dx > size.width || dy > size.height) {
        continue; // cull off-window cells
      }
      final dst = Rect.fromLTWH(dx, dy, dw, dh);
      final img = tileImages[p.tileId];
      if (img == null) {
        final c = p.regionAvgColor;
        if (c != null) {
          canvas.drawRect(
              dst,
              Paint()
                ..color = Color.fromRGBO(
                    c[0].round(), c[1].round(), c[2].round(), 1));
        }
        continue;
      }
      _drawCell(canvas, img, plan, tileCrops, p, dst, paint,
          rhombSx: s, rhombSy: s, rhombOrigin: Offset(ox, oy));
    }

    if (baseImage != null && tintStrength > 0) {
      final src = Rect.fromLTWH(
          0, 0, baseImage!.width.toDouble(), baseImage!.height.toDouble());
      final dst =
          Rect.fromLTWH(ox, oy, plan.baseWidth * s, plan.baseHeight * s);
      canvas.drawImageRect(
        baseImage!,
        src,
        dst,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, tintStrength.toDouble())
          ..filterQuality = FilterQuality.high,
      );
    }

    if (grade != null) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MosaicZoomPainter old) =>
      old.plan != plan ||
      old.focusX != focusX ||
      old.focusY != focusY ||
      old.windowSize != windowSize ||
      old.tintStrength != tintStrength ||
      !identical(old.tileCrops, tileCrops) ||
      old.outputSaturation != outputSaturation;
}
