import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Sharper copies of tile photos for deep zoom.
///
/// The preview draws every tile from a small thumbnail (~200–256 px), which is plenty
/// for the fitted picture but turns soft the moment a pinch blows a cell up past it.
/// The zoom painters ask this cache for the cells actually on screen; it fetches each
/// tile's stored photo (through the authenticated blob proxy — tiles are private),
/// decodes it at the size the zoom needs, and keeps a bounded number of them.
/// Painters repaint through [version] when copies arrive.
class HiResTiles {
  HiResTiles({required this.fetch, this.pixelBudget = 24 * 1000 * 1000});

  /// Bytes of a tile's stored photo, by tile id (null = unavailable).
  final Future<Uint8List?> Function(String tileId) fetch;

  /// Total decoded pixels kept (≈ 4 bytes each on the GPU).
  final int pixelBudget;

  /// Bumped when new copies are ready — pass as a painter's `repaint` listenable.
  final ValueNotifier<int> version = ValueNotifier(0);

  /// Largest long side decoded; the stored photos are rarely bigger.
  static const int maxLongSide = 1024;

  /// A copy drawn this recently is on screen and is never evicted for another.
  static const int _onScreenMs = 1500;

  /// A failed fetch (network blip) is retried after these delays, then given up.
  static const List<int> _retryMs = [1500, 5000, 15000];

  final Map<String, _Copy> _images = {}; // insertion order = LRU order
  final Map<String, int> _wantSize = {};
  final Set<String> _inFlight = {};
  final Map<String, int> _failures = {};
  final Map<String, int> _retryAt = {};
  final Stopwatch _clock = Stopwatch()..start();
  int _pixels = 0;
  int _active = 0;
  final List<String> _queue = [];
  bool _disposed = false;

  /// The sharp copy of [tileId] if it is at least [minLongSide] px (or as big as the
  /// photo gets), else null.
  ui.Image? get(String tileId, double minLongSide) {
    final c = _touch(tileId);
    if (c == null) return null;
    return c.complete || c.long >= minLongSide * 0.8 ? c.image : null;
  }

  /// The sharpest copy of [tileId] held, whatever its size (null = none yet).
  ui.Image? best(String tileId) => _touch(tileId)?.image;

  /// True when the copy held is the most this photo can give (asking for more is
  /// pointless), or the photo cannot be fetched at all.
  bool exhausted(String tileId) =>
      (_images[tileId]?.complete ?? false) ||
      (_failures[tileId] ?? 0) > _retryMs.length;

  _Copy? _touch(String tileId) {
    final c = _images.remove(tileId);
    if (c == null) return null;
    c.used = _clock.elapsedMilliseconds;
    _images[tileId] = c; // LRU: most recent last
    return c;
  }

  /// Ask for [tileId] at a long side of [longSide] px (clamped). Cheap to call every
  /// paint: already-held, pending and given-up tiles are skipped.
  void want(String tileId, double longSide) {
    if (_disposed) return;
    final fails = _failures[tileId] ?? 0;
    if (fails > _retryMs.length) return;
    if (fails > 0 && _clock.elapsedMilliseconds < (_retryAt[tileId] ?? 0)) {
      return;
    }
    final size = _tier(longSide);
    final have = _images[tileId];
    if (have != null && (have.complete || have.long >= size * 0.8)) return;
    final prev = _wantSize[tileId] ?? 0;
    if (size > prev) _wantSize[tileId] = size;
    if (_inFlight.contains(tileId)) return;
    // Newest requests first: what is on screen NOW beats what was on screen a pan ago.
    _queue.remove(tileId);
    _queue.add(tileId);
    scheduleMicrotask(_pump);
  }

  /// Decode sizes come in steps, so a slowly deepening zoom fetches a photo once or
  /// twice rather than at every new size.
  static int _tier(double longSide) {
    var t = 256;
    while (t < longSide && t < maxLongSide) {
      t *= 2;
    }
    return t;
  }

  void _pump() {
    while (!_disposed && _active < 4 && _queue.isNotEmpty) {
      final id = _queue.removeLast();
      _active++;
      _inFlight.add(id);
      _load(id).whenComplete(() {
        _active--;
        _inFlight.remove(id);
        _pump();
      });
    }
  }

  void _fail(String id) {
    final n = (_failures[id] ?? 0) + 1;
    _failures[id] = n;
    if (n <= _retryMs.length) {
      _retryAt[id] = _clock.elapsedMilliseconds + _retryMs[n - 1];
      // Nudge the painters once the retry is due, so a cell on screen asks again.
      Timer(Duration(milliseconds: _retryMs[n - 1]), () {
        if (!_disposed) version.value++;
      });
    }
  }

  Future<void> _load(String id) async {
    try {
      final bytes = await fetch(id);
      if (_disposed) return;
      if (bytes == null) {
        _fail(id);
        return;
      }
      final want = _wantSize[id] ?? maxLongSide;
      // Probe the size, then decode straight to the wanted long side (never upscale).
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final long = math.max(desc.width, desc.height);
      final scale = math.min(1.0, want / long);
      final codec = await desc.instantiateCodec(
        targetWidth: math.max(1, (desc.width * scale).round()),
        targetHeight: math.max(1, (desc.height * scale).round()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      desc.dispose();
      buffer.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      final img = frame.image;
      final old = _images.remove(id);
      if (old != null) _pixels -= old.pixels;
      // Not disposed: a frame being painted may still hold it (see _evict).
      _images[id] = _Copy(
        img,
        // The whole photo, or as much as is ever decoded: nothing sharper exists.
        complete: scale >= 1 || want >= maxLongSide,
        used: _clock.elapsedMilliseconds,
      );
      _pixels += img.width * img.height;
      _failures.remove(id);
      _evict();
      version.value++;
    } catch (_) {
      if (!_disposed) _fail(id);
    }
  }

  void _evict() {
    final now = _clock.elapsedMilliseconds;
    while (_pixels > pixelBudget && _images.length > 1) {
      final oldest = _images.keys.first;
      final c = _images[oldest]!;
      // Everything left was drawn just now: it is on screen, so keep it (going over
      // budget briefly beats a cell flickering back to its thumbnail).
      if (now - c.used < _onScreenMs) break;
      _images.remove(oldest);
      _pixels -= c.pixels;
      // Not disposed here: a frame being painted may still hold it. Dropping the
      // reference lets it be collected once nothing paints it.
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _images.clear();
    version.dispose();
  }
}

class _Copy {
  _Copy(this.image, {required this.complete, required this.used});
  final ui.Image image;
  final bool complete;
  int used;
  int get long => math.max(image.width, image.height);
  int get pixels => image.width * image.height;
}
