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

  final Map<String, ui.Image> _images = {}; // insertion order = LRU order
  final Map<String, int> _wantSize = {};
  final Set<String> _inFlight = {};
  final Set<String> _failed = {};
  int _pixels = 0;
  int _active = 0;
  final List<String> _queue = [];
  bool _disposed = false;

  /// The sharp copy of [tileId] if it is at least [minLongSide] px, else null.
  ui.Image? get(String tileId, double minLongSide) {
    final img = _images[tileId];
    if (img == null) return null;
    // Touch for LRU.
    _images.remove(tileId);
    _images[tileId] = img;
    return math.max(img.width, img.height) >= minLongSide * 0.8 ? img : null;
  }

  /// Ask for [tileId] at a long side of [longSide] px (clamped). Cheap to call every
  /// paint: already-held, pending and failed tiles are skipped.
  void want(String tileId, double longSide) {
    if (_disposed || _failed.contains(tileId)) return;
    final size = longSide.clamp(64, maxLongSide.toDouble()).round();
    final have = _images[tileId];
    if (have != null && math.max(have.width, have.height) >= size * 0.8) return;
    final prev = _wantSize[tileId] ?? 0;
    if (size > prev) _wantSize[tileId] = size;
    if (_inFlight.contains(tileId) || _queue.contains(tileId)) return;
    _queue.add(tileId);
    // Newest requests first: what is on screen NOW beats what was on screen a pan ago.
    scheduleMicrotask(_pump);
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

  Future<void> _load(String id) async {
    try {
      final bytes = await fetch(id);
      if (bytes == null || _disposed) {
        _failed.add(id);
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
      final old = _images.remove(id);
      if (old != null) {
        _pixels -= old.width * old.height;
        old.dispose();
      }
      _images[id] = frame.image;
      _pixels += frame.image.width * frame.image.height;
      _evict();
      version.value++;
    } catch (_) {
      _failed.add(id);
    }
  }

  void _evict() {
    while (_pixels > pixelBudget && _images.length > 1) {
      final oldest = _images.keys.first;
      final img = _images.remove(oldest)!;
      _pixels -= img.width * img.height;
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
