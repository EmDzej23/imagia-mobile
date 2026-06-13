import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../mosaic/shared.dart' show getBaseTileId, isTileFlipped;
import '../mosaic/types.dart';

/// Curated mobile animation styles (a subset of the web's 20). All output 9:16.
enum VideoStyle { photoWall, burst, deepZoom, morph, reelPoster }

extension VideoStyleInfo on VideoStyle {
  String get label => switch (this) {
        VideoStyle.photoWall => 'Photo wall',
        VideoStyle.burst => 'Burst',
        VideoStyle.deepZoom => 'Deep zoom-out',
        VideoStyle.morph => 'Photo morph',
        VideoStyle.reelPoster => 'Reel poster',
      };

  bool get isZoomout => this == VideoStyle.deepZoom;
  bool get isInPlace => this == VideoStyle.morph;
}

double _cubicEaseInOut(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;

/// Deterministic RNG matching the web (`seededRandom`).
double Function() _seededRandom(int seed) {
  var s = seed;
  return () {
    s = (s * 16807) % 2147483647;
    return (s - 1) / 2147483646;
  };
}

/// Contain-fit of the mosaic inside the 9:16 frame, centered.
typedef ContentLayout = ({double scale, double ox, double oy});

ContentLayout contentLayout(
    double baseW, double baseH, double videoW, double videoH) {
  final scale = math.min(videoW / baseW, videoH / baseH);
  return (
    scale: scale,
    ox: (videoW - baseW * scale) / 2,
    oy: (videoH - baseH * scale) / 2,
  );
}

/// A placement mapped into the 9:16 frame (final on-screen rect).
class VideoTile {
  VideoTile(this.x, this.y, this.w, this.h, this.tileId);
  double x, y, w, h;
  final String tileId;
}

List<VideoTile> _scaleInto(
    List<SlimPlacement> placements, ContentLayout fit) {
  return placements
      .map((p) => VideoTile(fit.ox + p.x * fit.scale, fit.oy + p.y * fit.scale,
          p.width * fit.scale, p.height * fit.scale, p.tileId))
      .toList();
}

/// Per-tile animation state: a start rect/rotation/scale easing into the final
/// placement rect. Ported from `video.ts` `TileAnimState`.
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

/// Pre-computed animation plan for a video (states + layout + focus).
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

  /// Where the mosaic sits in the 9:16 frame (for the tint overlay).
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
  final fit = contentLayout(plan.baseWidth, plan.baseHeight, videoW, videoH);
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
      final d = (cx - targetX) * (cx - targetX) + (cy - targetY) * (cy - targetY);
      if (d < minDist) {
        minDist = d;
        best = i;
      }
    }
    fx = tiles[best].x + tiles[best].w / 2;
    fy = tiles[best].y + tiles[best].h / 2;
    states = _buildZoomoutStates(tiles);
  } else if (style == VideoStyle.photoWall) {
    states = _buildGridStates(tiles, videoW, videoH);
  } else if (style == VideoStyle.reelPoster) {
    states = _buildZoomoutStates(tiles); // static; camera handled separately
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
    contentRect: Rect.fromLTWH(fit.ox, fit.oy, plan.baseWidth * fit.scale,
        plan.baseHeight * fit.scale),
    focusX: fx,
    focusY: fy,
    caption: caption,
  );
}

List<TileAnimState> _buildZoomoutStates(List<VideoTile> tiles) {
  return tiles
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
}

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
    final distFromCenter =
        math.sqrt((tileCX - cx) * (tileCX - cx) + (tileCY - cy) * (tileCY - cy));

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
    final dist =
        math.sqrt((tileCX - cx) * (tileCX - cx) + (tileCY - cy) * (tileCY - cy));
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
    const hold = 0.03, easeEnd = 0.92, initial = 10.0;
    if (progress <= hold) return initial;
    if (progress >= easeEnd) return 1.0;
    return initial +
        (1.0 - initial) * _cubicEaseInOut((progress - hold) / (easeEnd - hold));
  }
  const hold = 0.05, easeEnd = 0.75, initial = 4.0;
  if (progress <= hold) return initial;
  if (progress >= easeEnd) return 1.0;
  return initial +
      (1.0 - initial) * _cubicEaseInOut((progress - hold) / (easeEnd - hold));
}

double _tileEased(double progress, double stagger, VideoStyle style) {
  if (style.isZoomout) return 1;
  double moveStart, moveEndBase, staggerRange;
  switch (style) {
    case VideoStyle.morph:
      moveStart = 0.05;
      moveEndBase = 0.60;
      staggerRange = 0.25;
    case VideoStyle.photoWall:
      moveStart = 0.01;
      moveEndBase = 0.68;
      staggerRange = 0.08;
    case VideoStyle.burst:
      moveStart = 0.01;
      moveEndBase = 0.60;
      staggerRange = 0.12;
    default:
      moveStart = 0.01;
      moveEndBase = 0.68;
      staggerRange = 0.08;
  }
  final start = moveStart + stagger * staggerRange;
  final end = moveEndBase + stagger * staggerRange;
  if (progress <= start) return 0;
  if (progress >= end) return 1;
  return _cubicEaseInOut((progress - start) / (end - start));
}

// ── Per-frame painter ───────────────────────────────────────────────────────

double _easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

final ui.Paint _tilePaint = ui.Paint()
  ..filterQuality = ui.FilterQuality.medium
  ..isAntiAlias = false;

/// Source rect center-cropping [img] to aspect ratio [cellAR] (w/h).
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

void _drawGradientBackground(ui.Canvas canvas, double vw, double vh) {
  final shader = ui.Gradient.radial(
    ui.Offset(vw / 2, vh * 0.42),
    math.max(vw, vh) * 0.8,
    const [Color(0xFF1E2233), Color(0xFF0A0B0F)],
    const [0.0, 1.0],
  );
  canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, vw, vh), ui.Paint()..shader = shader);
}

void _drawTile(ui.Canvas canvas, ui.Image img, bool flipped, double x, double y,
    double w, double h, double rotation, double scale) {
  final src = _centerCrop(img, w / h);
  final dst = ui.Rect.fromLTWH(-w / 2, -h / 2, w, h);
  canvas.save();
  canvas.translate(x + w / 2, y + h / 2);
  if (rotation != 0) canvas.rotate(rotation);
  if (scale != 1) canvas.scale(scale, scale);
  if (flipped) {
    canvas.save();
    canvas.scale(-1, 1);
    canvas.drawImageRect(img, src, dst, _tilePaint);
    canvas.restore();
  } else {
    canvas.drawImageRect(img, src, dst, _tilePaint);
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

void _drawCaption(ui.Canvas canvas, double vw, double vh, String text) {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.center,
    fontSize: vw * 0.052,
    fontWeight: FontWeight.w600,
  ))
    ..pushStyle(ui.TextStyle(color: const Color(0xFFF4F5F7)))
    ..addText(text);
  final para = builder.build()
    ..layout(ui.ParagraphConstraints(width: vw * 0.86));
  canvas.drawParagraph(para, ui.Offset(vw * 0.07, vh * 0.86));
}

/// Renders one frame at [progress] in [0,1] onto [canvas].
void drawVideoFrame(
  ui.Canvas canvas,
  VideoAnim anim,
  Map<String, ui.Image> tileImages,
  ui.Image? morphBase,
  ui.Image? overlay,
  double progress,
) {
  final vw = anim.videoW, vh = anim.videoH;
  _drawGradientBackground(canvas, vw, vh);

  if (anim.style == VideoStyle.reelPoster) {
    // Static poster with a slow Ken-Burns zoom + caption.
    final z = 1.0 + 0.08 * _easeOutCubic(progress.clamp(0, 1).toDouble());
    canvas.save();
    canvas.translate(vw / 2, vh / 2);
    canvas.scale(z, z);
    canvas.translate(-vw / 2, -vh / 2);
    // Drop shadow + subtle border around the poster.
    final c = anim.contentRect;
    canvas.drawRRect(
      RRect.fromRectAndRadius(c.inflate(2), const Radius.circular(8)),
      ui.Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 24),
    );
    canvas.save();
    canvas.clipRRect(
        RRect.fromRectAndRadius(c, const Radius.circular(6)));
    for (final t in anim.tiles) {
      final img = tileImages[getBaseTileId(t.tileId)];
      if (img == null) continue;
      _drawTile(canvas, img, isTileFlipped(t.tileId), t.x, t.y, t.w, t.h, 0, 1);
    }
    if (anim.tintStrength > 0 && overlay != null) {
      _drawTint(canvas, overlay, c, anim.tintStrength);
    }
    canvas.restore();
    canvas.restore();
    if (anim.caption != null && anim.caption!.isNotEmpty) {
      _drawCaption(canvas, vw, vh, anim.caption!);
    }
    _drawFadeOut(canvas, vw, vh, progress);
    return;
  }

  var zoom = _cameraZoom(progress, anim.style);
  final screenCX = vw / 2, screenCY = vh / 2;
  var fx = anim.focusX ?? screenCX;
  var fy = anim.focusY ?? screenCY;

  const driftStart = 0.82;
  if (!anim.style.isZoomout && zoom <= 1.01 && progress > driftStart) {
    final dt = (progress - driftStart) / (1.0 - driftStart);
    zoom = 1.0 + 0.18 * math.sin(dt * math.pi);
    fx = screenCX + math.sin(dt * math.pi * 2.0) * vw * 0.07;
    fy = screenCY + math.sin(dt * math.pi * 1.3) * vh * 0.05;
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
    _drawTile(canvas, img, isTileFlipped(st.tileId), x, y, dw, dh,
        st.startRotation * (1 - t), scale);
  }

  if (anim.tintStrength > 0 && overlay != null) {
    _drawTint(canvas, overlay, anim.contentRect, anim.tintStrength);
  }

  canvas.restore();
  _drawFadeOut(canvas, vw, vh, progress);
}

void _drawFadeOut(ui.Canvas canvas, double vw, double vh, double progress) {
  const fadeStart = 0.93;
  if (progress > fadeStart) {
    final a = ((progress - fadeStart) / (1.0 - fadeStart)).clamp(0.0, 1.0);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, vw, vh),
        ui.Paint()..color = Color.fromRGBO(0, 0, 0, a));
  }
}
