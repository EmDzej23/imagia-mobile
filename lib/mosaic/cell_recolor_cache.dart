import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'hexagon.dart' show hexFromRect;
import 'hires_tiles.dart';
import 'local_recolor.dart';
import 'preview_painter.dart' show drawPlanWindow;
import 'types.dart';

/// Sharp, recoloured copies of individual cells for the zoomed preview.
///
/// The zoomed view draws the whole mosaic from one recoloured picture
/// ([HrRecolorCache], recolor_bake.dart). Past that picture's resolution, each cell on
/// screen gets its own recoloured copy at the size the zoom needs — rendered once, in
/// the background, a batch of cells per texture — and the painter draws those copies
/// every frame. So pinching and dragging only DRAW finished images (no re-rendering
/// under the finger), and a cell that has become sharp stays sharp: copies only ever
/// get replaced by sharper ones, and the cells being looked at are never evicted.
///
/// The recolour is per cell (the photo under it, the tile's own pixels), so a cell's
/// copy matches the whole-mosaic picture's colours exactly.
class CellRecolorCache extends ChangeNotifier {
  CellRecolorCache({this.pixelBudget = 40 * 1000 * 1000});

  /// Total cell pixels kept (≈ 4 bytes each on the GPU).
  final int pixelBudget;

  SlimMosaicPlan? _plan;
  Object? _key;
  Map<String, ui.Image> _thumbs = const {};
  HiResTiles? _hiRes;
  double _strength = 0, _saturation = 1;

  final Map<int, _Entry> _entries = {};
  final Map<int, int> _pending = {}; // index → tier requested
  final List<int> _queue = [];
  bool _running = false, _disposed = false;
  int _clock = 0;

  /// Point the cache at the current plan and look. A change of plan or look drops
  /// every copy (their colours would be wrong).
  void configure({
    required SlimMosaicPlan plan,
    required Map<String, ui.Image> tileImages,
    required HiResTiles? hiRes,
    required double tileRecolor,
    required double outputSaturation,
  }) {
    _thumbs = tileImages;
    _hiRes = hiRes;
    final key = Object.hash(
      plan,
      tileRecolor,
      outputSaturation,
      Object.hashAll(plan.tileCrops.values),
      tileImages.length,
    );
    if (key == _key) return;
    _key = key;
    _plan = plan;
    _strength = tileRecolor;
    _saturation = outputSaturation;
    _entries.clear();
    _pending.clear();
    _queue.clear();
  }

  /// The cell's bounding box in base px (honeycomb / cube cells reach past their
  /// sample rect).
  static Rect cellBox(SlimMosaicPlan plan, SlimPlacement p) {
    final q = p.quad;
    if (q != null) {
      final xs = [q[0], q[2], q[4], q[6]], ys = [q[1], q[3], q[5], q[7]];
      return Rect.fromLTRB(
        xs.reduce(math.min),
        ys.reduce(math.min),
        xs.reduce(math.max),
        ys.reduce(math.max),
      );
    }
    if (plan.hexagon) {
      final hc = hexFromRect(p.x, p.y, p.width, p.height);
      return Rect.fromCenter(
        center: Offset(hc.cx, hc.cy),
        width: hc.s * 2,
        height: hc.s * math.sqrt(3),
      );
    }
    return Rect.fromLTWH(p.x, p.y, p.width, p.height);
  }

  /// The sharpest copy of cell [index] so far (image + source rect), or null.
  (ui.Image, Rect)? get(int index) {
    final e = _entries[index];
    if (e == null) return null;
    e.used = ++_clock;
    return (e.atlas.image, e.rect);
  }

  /// Ask for cell [index] at [needPx] (its long side on screen, device px). Cheap to
  /// call every frame: already-good, pending and out-of-range cells are skipped.
  void want(int index, double needPx) {
    final plan = _plan;
    if (_disposed ||
        plan == null ||
        index < 0 ||
        index >= plan.placements.length)
      return;
    final p = plan.placements[index];
    final src = _sourceFor(p, needPx);
    if (src == null) return;
    final tier = _tierFor(needPx, math.max(src.width, src.height).toDouble());
    final have = _entries[index]?.tier ?? 0;
    if (tier <= have) return;
    final asked = _pending[index] ?? 0;
    if (tier <= asked) return;
    _pending[index] = tier;
    _queue.remove(index);
    _queue.add(index);
    scheduleMicrotask(_pump);
  }

  ui.Image? _sourceFor(SlimPlacement p, double needPx) {
    final thumb = _thumbs[p.tileId];
    final hr = _hiRes;
    if (hr == null || thumb == null) return thumb;
    if (needPx > math.max(thumb.width, thumb.height)) {
      final sharp = hr.get(p.tileId, needPx);
      if (sharp == null) hr.want(p.tileId, needPx);
      return sharp ?? thumb;
    }
    return thumb;
  }

  /// Power-of-two long side for a need, no larger than the source can show.
  static int _tierFor(double need, double srcLong) {
    var t = 64;
    while (t < need && t < 512) {
      t *= 2;
    }
    var cap = 64;
    while (cap < srcLong && cap < 512) {
      cap *= 2;
    }
    return math.min(t, cap);
  }

  Future<void> _pump() async {
    if (_running || _disposed || _queue.isEmpty) return;
    _running = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        // Newest requests first: what is on screen NOW.
        final batch = <int>[];
        while (_queue.isNotEmpty && batch.length < 24) {
          batch.add(_queue.removeLast());
        }
        await _bake(batch);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _bake(List<int> indices) async {
    final plan = _plan, key = _key;
    if (plan == null) return;
    // Shelf-pack the cells into one atlas.
    const atlasW = 2048, gap = 2;
    var x = 0, y = 0, rowH = 0;
    final slots =
        <
          (int, int, Rect, Rect)
        >[]; // index, tier, slot (atlas px), box (base px)
    for (final i in indices) {
      final tier = _pending[i];
      if (tier == null) continue;
      final p = plan.placements[i];
      final box = cellBox(plan, p);
      if (box.width <= 0 || box.height <= 0) continue;
      final a = box.width / box.height;
      final w = (a >= 1 ? tier : tier * a).ceil(),
          h = (a >= 1 ? tier / a : tier).ceil();
      if (x + w > atlasW) {
        x = 0;
        y += rowH + gap;
        rowH = 0;
      }
      slots.add((
        i,
        tier,
        Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()),
        box,
      ));
      x += w + gap;
      rowH = math.max(rowH, h);
    }
    if (slots.isEmpty) return;
    final atlasH = y + rowH;

    // Draw each cell alone into its slot (a one-cell plan, so no neighbour can paint
    // into its box), collecting the cells to recolour.
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final cells = <RecolorCell>[];
    for (final (i, tier, slot, box) in slots) {
      final p = plan.placements[i];
      final single = SlimMosaicPlan(
        baseWidth: plan.baseWidth,
        baseHeight: plan.baseHeight,
        outputWidth: plan.outputWidth,
        outputHeight: plan.outputHeight,
        tintStrength: 0,
        baseBlur: plan.baseBlur,
        placements: [p],
        cropPortraitTop: plan.cropPortraitTop,
        hexagon: plan.hexagon,
        tileCrops: plan.tileCrops,
      );
      final k = slot.width / box.width;
      canvas.save();
      canvas.clipRect(slot);
      canvas.translate(slot.left, slot.top);
      final drawn = drawPlanWindow(
        canvas,
        single,
        plan.tileCrops,
        k,
        box.topLeft,
        slot.size,
        imageFor: (q, needPx) => _sourceFor(q, needPx) ?? _thumbs[q.tileId],
      );
      canvas.restore();
      for (final c in drawn) {
        cells.add(offsetRecolorCell(c, slot.left, slot.top));
      }
      assert(tier > 0);
    }
    final pic = rec.endRecording();
    final raw = await pic.toImage(atlasW, atlasH);
    pic.dispose();
    final bd = await raw.toByteData(format: ui.ImageByteFormat.rawRgba);
    raw.dispose();
    if (bd == null || _disposed || key != _key) return;
    final data = bd.buffer.asUint8List();
    final strength = _strength, sat = _saturation;
    final out = await _recolorOffThread(
      data,
      atlasW,
      atlasH,
      cells,
      strength,
      sat,
    );
    if (_disposed || key != _key) return;
    final buffer = await ui.ImmutableBuffer.fromUint8List(out);
    final desc = ui.ImageDescriptor.raw(
      buffer,
      width: atlasW,
      height: atlasH,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    desc.dispose();
    buffer.dispose();
    if (_disposed || key != _key) {
      frame.image.dispose();
      return;
    }
    final atlas = _Atlas(frame.image);
    for (final (i, tier, slot, _) in slots) {
      if ((_pending[i] ?? 0) == tier) _pending.remove(i);
      final old = _entries[i];
      if (old != null && old.tier >= tier) continue; // never trade down
      old?.atlas.release();
      atlas.retain();
      // Inset half a pixel so filtered sampling never reads the next slot.
      _entries[i] = _Entry(atlas, slot.deflate(0.5), tier, ++_clock);
    }
    if (atlas.refs == 0) atlas.image.dispose();
    _evict();
    notifyListeners();
  }

  void _evict() {
    var px = 0.0;
    for (final e in _entries.values) {
      px += e.rect.width * e.rect.height;
    }
    if (px <= pixelBudget) return;
    // Least recently drawn first; the cells drawn in the last frames are the newest.
    final order = _entries.entries.toList()
      ..sort((a, b) => a.value.used - b.value.used);
    for (final kv in order) {
      if (px <= pixelBudget * 0.85) break;
      if (_clock - kv.value.used < 400) break; // drawn just now — on screen
      px -= kv.value.rect.width * kv.value.rect.height;
      _entries.remove(kv.key);
      kv.value.atlas.release();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final e in _entries.values) {
      e.atlas.release();
    }
    _entries.clear();
    super.dispose();
  }
}

/// The recolour in a background isolate. Top-level on purpose: a closure made inside
/// a method would carry that method's whole context — the cache, and its images,
/// which cannot be sent to an isolate.
Future<Uint8List> _recolorOffThread(
  Uint8List data,
  int w,
  int h,
  List<RecolorCell> cells,
  double strength,
  double sat,
) {
  return Isolate.run(() {
    applyLocalRecolor(data, w, h, cells, strength, outputSaturation: sat);
    return data;
  });
}

class _Atlas {
  _Atlas(this.image);
  final ui.Image image;
  int refs = 0;
  void retain() => refs++;
  void release() {
    if (--refs == 0) image.dispose();
  }
}

class _Entry {
  _Entry(this.atlas, this.rect, this.tier, this.used);
  final _Atlas atlas;
  final Rect rect;
  final int tier;
  int used;
}

/// The zoomed, recoloured preview: the whole-mosaic picture ([hr]) under, and each
/// on-screen cell's sharp copy ([cache]) over it once the zoom needs more detail than
/// [hr] has. Only draws finished images — smooth while pinching and dragging.
class RecoloredZoomPainter extends CustomPainter {
  RecoloredZoomPainter({
    required this.plan,
    required this.hr,
    required this.cache,
    required this.window,
    required this.devicePixelRatio,
  }) : super(repaint: cache);

  final SlimMosaicPlan plan;
  final ui.Image hr;
  final CellRecolorCache cache;

  /// The part of the mosaic on screen, in base px.
  final Rect window;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final s = size.width / window.width;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    // 1. The whole mosaic.
    canvas.drawImageRect(
      hr,
      Rect.fromLTWH(0, 0, hr.width.toDouble(), hr.height.toDouble()),
      Rect.fromLTWH(
        -window.left * s,
        -window.top * s,
        plan.baseWidth * s,
        plan.baseHeight * s,
      ),
      paint,
    );
    // 2. Sharp copies of the cells that need more detail than that.
    final hrPerBase = hr.width / plan.baseWidth;
    final screenPerBase = s * devicePixelRatio;
    if (screenPerBase <= hrPerBase * 1.15) return;
    for (var i = 0; i < plan.placements.length; i++) {
      final p = plan.placements[i];
      // Quick cull on the sample rect, generous for shaped cells.
      final reach = (p.quad != null || plan.hexagon)
          ? math.max(p.width, p.height)
          : 0;
      if (p.x + p.width + reach < window.left ||
          p.y + p.height + reach < window.top ||
          p.x - reach > window.right ||
          p.y - reach > window.bottom) {
        continue;
      }
      final box = CellRecolorCache.cellBox(plan, p);
      final dst = Rect.fromLTWH(
        (box.left - window.left) * s,
        (box.top - window.top) * s,
        box.width * s,
        box.height * s,
      );
      if (!dst.overlaps(Offset.zero & size)) continue;
      cache.want(i, math.max(dst.width, dst.height) * devicePixelRatio);
      final copy = cache.get(i);
      if (copy != null) canvas.drawImageRect(copy.$1, copy.$2, dst, paint);
    }
  }

  @override
  bool shouldRepaint(covariant RecoloredZoomPainter old) =>
      old.plan != plan ||
      old.hr != hr ||
      old.window != window ||
      old.cache != cache ||
      old.devicePixelRatio != devicePixelRatio;
}
