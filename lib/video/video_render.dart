import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../mosaic/shared.dart' show getBaseTileId, isTileFlipped;
import '../mosaic/types.dart';

/// Curated mobile animation styles. All output a 9:16 branded "poster": the
/// mosaic sits in a centre band on a real-looking wall, with an animated
/// caption above and the Imagia branding lockup below.
enum VideoStyle { reelPoster, photoWall, burst, deepZoom, morph }

extension VideoStyleInfo on VideoStyle {
  String get label => switch (this) {
        VideoStyle.reelPoster => 'Reel poster',
        VideoStyle.photoWall => 'Photo wall',
        VideoStyle.burst => 'Burst',
        VideoStyle.deepZoom => 'Deep zoom-out',
        VideoStyle.morph => 'Photo morph',
      };

  bool get isZoomout => this == VideoStyle.deepZoom;
  bool get isInPlace => this == VideoStyle.morph;
}

// Layout of the 9:16 frame: top strip = caption, centre band = mosaic, bottom
// strip = branding. Fractions of the video height/width.
const double _topBand = 0.135;
const double _bottomBand = 0.20;
const double _sidePad = 0.05;

const String _brandTitle = 'Imagia';
const String _brandSlogan = 'Made of moments';

double _cubicEaseInOut(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;

double _easeOutCubic(double t) => 1 - math.pow(1 - t.clamp(0, 1), 3).toDouble();

/// Eased 0→1 ramp over [span] starting at [start].
double _appearSeg(double progress, double start, double span) =>
    _easeOutCubic(((progress - start) / span).clamp(0.0, 1.0));

/// Deterministic RNG matching the web (`seededRandom`).
double Function() _seededRandom(int seed) {
  var s = seed;
  return () {
    s = (s * 16807) % 2147483647;
    return (s - 1) / 2147483646;
  };
}

/// Contain-fit of the mosaic inside an arbitrary [band] rect, centred.
typedef ContentLayout = ({double scale, double ox, double oy});

ContentLayout _containIn(double baseW, double baseH, Rect band) {
  final scale = math.min(band.width / baseW, band.height / baseH);
  return (
    scale: scale,
    ox: band.left + (band.width - baseW * scale) / 2,
    oy: band.top + (band.height - baseH * scale) / 2,
  );
}

/// A placement mapped into the 9:16 frame (final on-screen rect).
class VideoTile {
  VideoTile(this.x, this.y, this.w, this.h, this.tileId);
  double x, y, w, h;
  final String tileId;
}

List<VideoTile> _scaleInto(List<SlimPlacement> placements, ContentLayout fit) {
  return placements
      .map((p) => VideoTile(fit.ox + p.x * fit.scale, fit.oy + p.y * fit.scale,
          p.width * fit.scale, p.height * fit.scale, p.tileId))
      .toList();
}

/// Per-tile animation state: a start rect/rotation/scale easing into the final
/// placement rect.
class TileAnimState {
  TileAnimState({
    required this.startX,
    required this.startY,
    required this.startW,
    required this.startH,
    required this.startRotation,
    required this.startScale,
    required this.endX,
    required this.endY,
    required this.endW,
    required this.endH,
    required this.stagger,
    required this.tileId,
  });
  double startX, startY, startW, startH, startRotation, startScale;
  double endX, endY, endW, endH, stagger;
  String tileId;
}

/// Pre-computed animation plan for a video.
class VideoAnim {
  VideoAnim({
    required this.style,
    required this.videoW,
    required this.videoH,
    required this.tiles,
    required this.states,
    required this.tintStrength,
    required this.contentRect,
    this.focusX,
    this.focusY,
    this.caption,
  });
  final VideoStyle style;
  final double videoW;
  final double videoH;
  final List<VideoTile> tiles;
  final List<TileAnimState> states;
  final double tintStrength;

  /// Where the mosaic sits within the centre band (for the tint overlay + frame).
  final Rect contentRect;
  final double? focusX;
  final double? focusY;
  final String? caption;
}

VideoAnim buildVideoAnim({
  required SlimMosaicPlan plan,
  required VideoStyle style,
  required double videoW,
  required double videoH,
  String? caption,
}) {
  // The mosaic lives in the centre band; the top/bottom strips hold caption +
  // branding.
  final band = Rect.fromLTRB(
    videoW * _sidePad,
    videoH * _topBand,
    videoW * (1 - _sidePad),
    videoH * (1 - _bottomBand),
  );
  final fit = _containIn(plan.baseWidth, plan.baseHeight, band);
  final tiles = _scaleInto(plan.placements, fit);

  double? fx, fy;
  List<TileAnimState> states;
  if (style == VideoStyle.deepZoom) {
    // Focus on the tile nearest the content's upper-centre (typical subject).
    final targetX = videoW * 0.5;
    final targetY = fit.oy + plan.baseHeight * fit.scale * 0.35;
    var minDist = double.infinity;
    var best = 0;
    for (var i = 0; i < tiles.length; i++) {
      final cx = tiles[i].x + tiles[i].w / 2;
      final cy = tiles[i].y + tiles[i].h / 2;
      final d =
          (cx - targetX) * (cx - targetX) + (cy - targetY) * (cy - targetY);
      if (d < minDist) {
        minDist = d;
        best = i;
      }
    }
    fx = tiles[best].x + tiles[best].w / 2;
    fy = tiles[best].y + tiles[best].h / 2;
    states = _buildStaticStates(tiles);
  } else if (style == VideoStyle.reelPoster) {
    states = _buildStaticStates(tiles);
  } else if (style == VideoStyle.photoWall) {
    states = _buildGridStates(tiles, videoW, videoH);
  } else {
    states = _buildStates(tiles, videoW, videoH, style);
  }

  return VideoAnim(
    style: style,
    videoW: videoW,
    videoH: videoH,
    tiles: tiles,
    states: states,
    tintStrength: plan.tintStrength,
    contentRect: Rect.fromLTWH(
        fit.ox, fit.oy, plan.baseWidth * fit.scale, plan.baseHeight * fit.scale),
    focusX: fx,
    focusY: fy,
    caption: caption,
  );
}

List<TileAnimState> _buildStaticStates(List<VideoTile> tiles) => tiles
    .map((t) => TileAnimState(
          startX: t.x,
          startY: t.y,
          startW: t.w,
          startH: t.h,
          startRotation: 0,
          startScale: 1,
          endX: t.x,
          endY: t.y,
          endW: t.w,
          endH: t.h,
          stagger: 0,
          tileId: t.tileId,
        ))
    .toList();

List<TileAnimState> _buildStates(
    List<VideoTile> tiles, double videoW, double videoH, VideoStyle style) {
  final rng = _seededRandom(42);
  final n = tiles.length;
  final cx = videoW / 2, cy = videoH / 2;
  final diagonal = math.sqrt(videoW * videoW + videoH * videoH);
  final maxDist = diagonal / 2;

  return List.generate(n, (i) {
    final sp = tiles[i];
    final tileCX = sp.x + sp.w / 2, tileCY = sp.y + sp.h / 2;
    final distFromCenter = math.sqrt(
        (tileCX - cx) * (tileCX - cx) + (tileCY - cy) * (tileCY - cy));

    switch (style) {
      case VideoStyle.morph:
        return TileAnimState(
          startX: sp.x, startY: sp.y, startW: sp.w, startH: sp.h,
          startRotation: 0, startScale: 0,
          endX: sp.x, endY: sp.y, endW: sp.w, endH: sp.h,
          stagger: distFromCenter / maxDist, tileId: sp.tileId,
        );
      case VideoStyle.burst:
        final ang = rng() * math.pi * 2;
        final rad = (0.20 + rng() * 0.35) * diagonal;
        return TileAnimState(
          startX: cx + math.cos(ang) * rad - sp.w / 2,
          startY: cy + math.sin(ang) * rad - sp.h / 2,
          startW: sp.w, startH: sp.h,
          startRotation: (rng() - 0.5) * math.pi * 0.8, startScale: 1,
          endX: sp.x, endY: sp.y, endW: sp.w, endH: sp.h,
          stagger: distFromCenter / maxDist, tileId: sp.tileId,
        );
      default:
        return TileAnimState(
          startX: sp.x, startY: sp.y, startW: sp.w, startH: sp.h,
          startRotation: 0, startScale: 0,
          endX: sp.x, endY: sp.y, endW: sp.w, endH: sp.h,
          stagger: distFromCenter / maxDist, tileId: sp.tileId,
        );
    }
  });
}

List<TileAnimState> _buildGridStates(
    List<VideoTile> tiles, double videoW, double videoH) {
  final rng = _seededRandom(42);
  final n = tiles.length;
  final cx = videoW / 2, cy = videoH / 2;
  final diagonal = math.sqrt(videoW * videoW + videoH * videoH);
  final maxDist = diagonal / 2;

  final cols = (math.sqrt(n * (videoW / videoH))).ceil();
  final rows = (n / cols).ceil();
  final pad = 0.02 * videoW;
  final gap = 0.006 * videoW;
  final cellW = (videoW - 2 * pad - gap * (cols - 1)) / cols;
  final cellH = (videoH - 2 * pad - gap * (rows - 1)) / rows;

  // Shuffle slots (Fisher–Yates with the seeded RNG).
  final slots = List<int>.generate(n, (i) => i);
  for (var i = slots.length - 1; i > 0; i--) {
    final j = (rng() * (i + 1)).floor();
    final tmp = slots[i];
    slots[i] = slots[j];
    slots[j] = tmp;
  }
  final gridSlot = List<int>.filled(n, 0);
  for (var slot = 0; slot < slots.length; slot++) {
    gridSlot[slots[slot]] = slot;
  }

  return List.generate(n, (i) {
    final sp = tiles[i];
    final slot = gridSlot[i];
    final col = slot % cols;
    final row = slot ~/ cols;
    final tileCX = sp.x + sp.w / 2, tileCY = sp.y + sp.h / 2;
    final dist = math.sqrt(
        (tileCX - cx) * (tileCX - cx) + (tileCY - cy) * (tileCY - cy));
    return TileAnimState(
      startX: pad + col * (cellW + gap),
      startY: pad + row * (cellH + gap),
      startW: cellW, startH: cellH,
      startRotation: 0, startScale: 1,
      endX: sp.x, endY: sp.y, endW: sp.w, endH: sp.h,
      stagger: dist / maxDist, tileId: sp.tileId,
    );
  });
}

double _cameraZoom(double progress, VideoStyle style) {
  if (style.isInPlace) return 1.0;
  if (style.isZoomout) {
    // Settle earlier (0.66) than the web so the branded outro has room.
    const hold = 0.03, easeEnd = 0.66, initial = 10.0;
    if (progress <= hold) return initial;
    if (progress >= easeEnd) return 1.0;
    return initial +
        (1.0 - initial) * _cubicEaseInOut((progress - hold) / (easeEnd - hold));
  }
  const hold = 0.05, easeEnd = 0.62, initial = 4.0;
  if (progress <= hold) return initial;
  if (progress >= easeEnd) return 1.0;
  return initial +
      (1.0 - initial) * _cubicEaseInOut((progress - hold) / (easeEnd - hold));
}

double _tileEased(double progress, double stagger, VideoStyle style) {
  if (style.isZoomout || style == VideoStyle.reelPoster) return 1;
  double moveStart, moveEndBase, staggerRange;
  switch (style) {
    case VideoStyle.morph:
      moveStart = 0.05;
      moveEndBase = 0.52;
      staggerRange = 0.22;
    case VideoStyle.photoWall:
      moveStart = 0.01;
      moveEndBase = 0.58;
      staggerRange = 0.08;
    case VideoStyle.burst:
      moveStart = 0.01;
      moveEndBase = 0.52;
      staggerRange = 0.12;
    default:
      moveStart = 0.01;
      moveEndBase = 0.58;
      staggerRange = 0.08;
  }
  final start = moveStart + stagger * staggerRange;
  final end = moveEndBase + stagger * staggerRange;
  if (progress <= start) return 0;
  if (progress >= end) return 1;
  return _cubicEaseInOut((progress - start) / (end - start));
}

/// When the mosaic is settled in the band, so caption + branding can come in.
({double cap, double brand}) _overlayTiming(VideoStyle s) => switch (s) {
      VideoStyle.reelPoster => (cap: 0.10, brand: 0.32),
      VideoStyle.morph => (cap: 0.58, brand: 0.70),
      VideoStyle.photoWall => (cap: 0.64, brand: 0.76),
      VideoStyle.burst => (cap: 0.58, brand: 0.70),
      VideoStyle.deepZoom => (cap: 0.68, brand: 0.80),
    };

// ── Drawing ──────────────────────────────────────────────────────────────────

final ui.Paint _tilePaint = ui.Paint()
  ..filterQuality = ui.FilterQuality.medium
  ..isAntiAlias = false;

ui.Rect _centerCrop(ui.Image img, double cellAR) {
  final tw = img.width.toDouble(), th = img.height.toDouble();
  final tileAR = tw / th;
  if (tileAR > cellAR) {
    final sw = th * cellAR;
    return ui.Rect.fromLTWH((tw - sw) / 2, 0, sw, th);
  }
  final sh = tw / cellAR;
  return ui.Rect.fromLTWH(0, (th - sh) / 2, tw, sh);
}

void _drawTile(
  ui.Canvas canvas,
  ui.Image img,
  bool flipped,
  double x,
  double y,
  double w,
  double h,
  double rotation,
  double scale, {
  ui.Image? overlay,
  ui.Rect? overlaySrc,
  double overlayAlpha = 0,
}) {
  final src = _centerCrop(img, w / h);
  final dst = ui.Rect.fromLTWH(-w / 2, -h / 2, w, h);
  canvas.save();
  canvas.translate(x + w / 2, y + h / 2);
  if (rotation != 0) canvas.rotate(rotation);
  if (scale != 1) canvas.scale(scale, scale);
  // Tile photo (mirrored for variety when flipped).
  if (flipped) {
    canvas.save();
    canvas.scale(-1, 1);
    canvas.drawImageRect(img, src, dst, _tilePaint);
    canvas.restore();
  } else {
    canvas.drawImageRect(img, src, dst, _tilePaint);
  }
  // This tile's slice of the base overlay — glued to the tile (follows its
  // position/rotation/scale) but never mirrored, so when all tiles meet at the
  // end the overlay reconstructs exactly like the mosaic preview.
  if (overlay != null && overlaySrc != null && overlayAlpha > 0) {
    canvas.drawImageRect(
      overlay,
      overlaySrc,
      dst,
      ui.Paint()
        ..color = Color.fromRGBO(255, 255, 255, overlayAlpha)
        ..filterQuality = ui.FilterQuality.high,
    );
  }
  canvas.restore();
}

void _drawTint(ui.Canvas canvas, ui.Image overlay, Rect content, double alpha) {
  canvas.drawImageRect(
    overlay,
    ui.Rect.fromLTWH(
        0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
    content,
    ui.Paint()
      ..color = Color.fromRGBO(255, 255, 255, alpha)
      ..filterQuality = ui.FilterQuality.high,
  );
}

void _drawCaption(
    ui.Canvas canvas, double vw, double vh, String text, double appear) {
  if (appear <= 0 || text.isEmpty) return;
  final a = appear.clamp(0.0, 1.0);
  final slide = (1 - a) * vh * 0.03; // ease down from above
  final size = vw * 0.055;
  final para = (ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.center,
    fontFamily: 'Inter',
    fontSize: size,
    fontWeight: FontWeight.w600,
  ))
        ..pushStyle(ui.TextStyle(
          color: Color.fromRGBO(244, 245, 247, a),
          height: 1.15,
          shadows: [
            ui.Shadow(
                color: Color.fromRGBO(0, 0, 0, 0.55 * a),
                blurRadius: 16,
                offset: const Offset(0, 3)),
          ],
        ))
        ..addText(text))
      .build()
    ..layout(ui.ParagraphConstraints(width: vw * 0.86));
  final centerY = vh * _topBand * 0.52;
  canvas.drawParagraph(
      para, ui.Offset(vw * 0.07, centerY - para.height / 2 - slide));
}

void _drawBranding(
    ui.Canvas canvas, double vw, double vh, ui.Image? logo, double appear) {
  if (appear <= 0) return;
  final a = appear.clamp(0.0, 1.0);
  final slide = (1 - a) * vh * 0.035; // ease up from below

  final shadow = [
    ui.Shadow(
        color: Color.fromRGBO(0, 0, 0, 0.5 * a),
        blurRadius: 12,
        offset: const Offset(0, 3)),
  ];

  // Stacked lockup: logo on top, wordmark, then slogan — all centred.
  final logoH = logo != null ? vw * 0.125 : 0.0;
  final logoAR = logo != null ? logo.width / logo.height : 1.0;
  final logoW = logoH * logoAR;

  final titleSize = vw * 0.062;
  final titlePara = (ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.center,
    fontFamily: 'Inter',
    fontSize: titleSize,
    fontWeight: FontWeight.w700,
  ))
        ..pushStyle(ui.TextStyle(
            color: Color.fromRGBO(244, 245, 247, a),
            letterSpacing: titleSize * 0.01,
            shadows: shadow))
        ..addText(_brandTitle))
      .build()
    ..layout(ui.ParagraphConstraints(width: vw));

  final sloganSize = vw * 0.030;
  final sloganPara = (ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.center,
    fontFamily: 'Inter',
    fontSize: sloganSize,
    fontWeight: FontWeight.w500,
  ))
        ..pushStyle(ui.TextStyle(
            color: Color.fromRGBO(232, 220, 192, 0.92 * a),
            letterSpacing: sloganSize * 0.12,
            shadows: shadow))
        ..addText(_brandSlogan))
      .build()
    ..layout(ui.ParagraphConstraints(width: vw));

  final gapLogo = vh * 0.008;
  final gapSlogan = vh * 0.006;
  final blockH = logoH +
      gapLogo +
      titlePara.height +
      gapSlogan +
      sloganPara.height;
  final top = vh * 0.885 - blockH / 2 + slide;

  if (logo != null) {
    canvas.drawImageRect(
      logo,
      ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      ui.Rect.fromLTWH((vw - logoW) / 2, top, logoW, logoH),
      ui.Paint()
        ..color = Color.fromRGBO(255, 255, 255, a)
        ..filterQuality = ui.FilterQuality.high,
    );
  }
  final titleY = top + logoH + gapLogo;
  canvas.drawParagraph(titlePara, ui.Offset(0, titleY));
  canvas.drawParagraph(
      sloganPara, ui.Offset(0, titleY + titlePara.height + gapSlogan));
}

/// Renders the framed "poster" (cream mat + drop shadow + mosaic) for the
/// reelPoster style and as the settled look. [intro] fades/scales it in.
void _drawPoster(
  ui.Canvas canvas,
  VideoAnim anim,
  Map<String, ui.Image> tileImages,
  ui.Image? overlay,
  double progress,
) {
  final c = anim.contentRect;
  final intro = _easeOutCubic((progress / 0.22).clamp(0.0, 1.0));
  final ken = 1 + 0.05 * _easeOutCubic(progress);
  final s = ken * (0.97 + 0.03 * intro);

  canvas.saveLayer(
      null, ui.Paint()..color = Color.fromRGBO(255, 255, 255, intro));
  canvas.translate(c.center.dx, c.center.dy);
  canvas.scale(s, s);
  canvas.translate(-c.center.dx, -c.center.dy);

  final matInset = c.width * 0.035;
  final mat = RRect.fromRectAndRadius(
      c.inflate(matInset), Radius.circular(c.width * 0.02));
  // Drop shadow on the wall.
  canvas.drawRRect(
    mat.shift(Offset(0, c.height * 0.018)),
    ui.Paint()
      ..color = const Color(0xAA000000)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, c.width * 0.05),
  );
  // Cream mat board.
  canvas.drawRRect(mat, ui.Paint()..color = const Color(0xFFEDE8DE));

  canvas.save();
  canvas.clipRRect(
      RRect.fromRectAndRadius(c, Radius.circular(c.width * 0.012)));
  for (final t in anim.tiles) {
    final img = tileImages[getBaseTileId(t.tileId)];
    if (img == null) continue;
    _drawTile(canvas, img, isTileFlipped(t.tileId), t.x, t.y, t.w, t.h, 0, 1);
  }
  if (anim.tintStrength > 0 && overlay != null) {
    _drawTint(canvas, overlay, c, anim.tintStrength);
  }
  canvas.restore();
  canvas.restore(); // saveLayer
}

/// Renders one frame at [progress] in [0,1] onto [canvas].
void drawVideoFrame(
  ui.Canvas canvas,
  VideoAnim anim,
  Map<String, ui.Image> tileImages,
  ui.Image? morphBase,
  ui.Image? overlay,
  ui.Image wall,
  ui.Image? logo,
  double progress,
) {
  final vw = anim.videoW, vh = anim.videoH;

  // Wall backdrop.
  canvas.drawImageRect(
    wall,
    ui.Rect.fromLTWH(0, 0, wall.width.toDouble(), wall.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, vw, vh),
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );

  if (anim.style == VideoStyle.reelPoster) {
    _drawPoster(canvas, anim, tileImages, overlay, progress);
  } else {
    _drawAnimatedTiles(canvas, anim, tileImages, morphBase, overlay, progress);
  }

  // Animated overlays: caption above, branding below.
  final timing = _overlayTiming(anim.style);
  if (anim.caption != null && anim.caption!.isNotEmpty) {
    _drawCaption(canvas, vw, vh, anim.caption!,
        _appearSeg(progress, timing.cap, 0.14));
  }
  _drawBranding(
      canvas, vw, vh, logo, _appearSeg(progress, timing.brand, 0.16));

  _drawFadeOut(canvas, vw, vh, progress);
}

void _drawAnimatedTiles(
  ui.Canvas canvas,
  VideoAnim anim,
  Map<String, ui.Image> tileImages,
  ui.Image? morphBase,
  ui.Image? overlay,
  double progress,
) {
  final vw = anim.videoW, vh = anim.videoH;
  var zoom = _cameraZoom(progress, anim.style);
  final screenCX = vw / 2, screenCY = vh / 2;
  var fx = anim.focusX ?? screenCX;
  var fy = anim.focusY ?? screenCY;

  // Zoom-out: pan the focus from the subject back to the frame centre as the
  // camera pulls out, so the mosaic ends perfectly centred in its band.
  if (anim.style.isZoomout) {
    const initial = 10.0;
    final blend = ((initial - zoom) / (initial - 1.0)).clamp(0.0, 1.0);
    fx = fx + (screenCX - fx) * blend;
    fy = fy + (screenCY - fy) * blend;
  }

  const driftStart = 0.80;
  if (!anim.style.isZoomout && zoom <= 1.01 && progress > driftStart) {
    final dt = (progress - driftStart) / (1.0 - driftStart);
    zoom = 1.0 + 0.12 * math.sin(dt * math.pi);
    fx = screenCX + math.sin(dt * math.pi * 2.0) * vw * 0.05;
    fy = screenCY + math.sin(dt * math.pi * 1.3) * vh * 0.035;
  }

  final invZoom = 1 / zoom;
  final visL = fx - (vw / 2) * invZoom;
  final visT = fy - (vh / 2) * invZoom;
  final visR = fx + (vw / 2) * invZoom;
  final visB = fy + (vh / 2) * invZoom;

  canvas.save();
  canvas.translate(screenCX, screenCY);
  canvas.scale(zoom, zoom);
  canvas.translate(-fx, -fy);

  if (anim.style == VideoStyle.morph && morphBase != null) {
    final a = math.max(0, 1.0 - progress * 2.2).toDouble();
    if (a > 0) {
      canvas.drawImageRect(
        morphBase,
        ui.Rect.fromLTWH(
            0, 0, morphBase.width.toDouble(), morphBase.height.toDouble()),
        anim.contentRect,
        ui.Paint()
          ..color = Color.fromRGBO(255, 255, 255, a)
          ..filterQuality = ui.FilterQuality.medium,
      );
    }
  }

  // Styles where tiles fly in from non-final positions would briefly show the
  // full base overlay floating in the empty band. Instead, give each tile its
  // own slice of the overlay so it's carried in — the overlay only "completes"
  // as the tiles settle, matching the mosaic preview.
  final perTileOverlay = (anim.style == VideoStyle.burst ||
          anim.style == VideoStyle.photoWall) &&
      overlay != null &&
      anim.tintStrength > 0;
  final c = anim.contentRect;
  final ow = overlay?.width.toDouble() ?? 0;
  final oh = overlay?.height.toDouble() ?? 0;

  const scaleOvershoot = 0.15;
  for (final st in anim.states) {
    final t = _tileEased(progress, st.stagger, anim.style);
    var scale = 1.0;
    if (st.startScale < 1) {
      final raw = st.startScale + (1 - st.startScale) * t;
      scale = t < 1 ? raw + math.sin(t * math.pi) * scaleOvershoot : 1;
    }
    if (scale < 0.01) continue;
    final x = st.startX + (st.endX - st.startX) * t;
    final y = st.startY + (st.endY - st.startY) * t;
    final dw = st.startW + (st.endW - st.startW) * t;
    final dh = st.startH + (st.endH - st.startH) * t;
    if (x + dw < visL || x > visR || y + dh < visT || y > visB) continue;
    final img = tileImages[getBaseTileId(st.tileId)];
    if (img == null) continue;

    ui.Rect? overlaySrc;
    if (perTileOverlay) {
      // The overlay region for this tile's FINAL cell (relative to contentRect).
      overlaySrc = ui.Rect.fromLTWH(
        (st.endX - c.left) / c.width * ow,
        (st.endY - c.top) / c.height * oh,
        st.endW / c.width * ow,
        st.endH / c.height * oh,
      );
    }

    _drawTile(canvas, img, isTileFlipped(st.tileId), x, y, dw, dh,
        st.startRotation * (1 - t), scale,
        overlay: perTileOverlay ? overlay : null,
        overlaySrc: overlaySrc,
        overlayAlpha: perTileOverlay ? anim.tintStrength : 0);
  }

  // Full-band overlay for the styles that don't carry it per-tile (deepZoom &
  // morph keep all tiles present, so no premature base photo shows).
  if (!perTileOverlay && anim.tintStrength > 0 && overlay != null) {
    _drawTint(canvas, overlay, anim.contentRect, anim.tintStrength);
  }

  canvas.restore();
}

void _drawFadeOut(ui.Canvas canvas, double vw, double vh, double progress) {
  const fadeStart = 0.95;
  if (progress > fadeStart) {
    final a = ((progress - fadeStart) / (1.0 - fadeStart)).clamp(0.0, 1.0);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, vw, vh),
        ui.Paint()..color = Color.fromRGBO(0, 0, 0, a));
  }
}
