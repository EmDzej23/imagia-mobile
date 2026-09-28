import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// On-disk cache for list thumbnails (project covers, download covers, order
/// thumbnails).
///
/// Flutter's `Image.network` caches decoded frames in memory but keeps NOTHING on
/// disk and ignores HTTP cache headers, so every cold start re-fetched every cover.
/// That is expensive well beyond the download: `/api/mosaic-image` pulls the full
/// rendered mosaic out of blob storage and resizes it with Sharp per request, so a
/// 200 px cover can cost a multi-megapixel decode server-side.
///
/// Deliberately tiny and dependency-free — these are a few KB each, so there is no
/// need for a cache package, an index, or an LRU. Eviction is by age on startup.
class ThumbCache {
  ThumbCache._();

  static Directory? _dir;
  static Future<Directory>? _pending;

  /// Covers change when a mosaic is re-rendered, so entries are not kept forever.
  static const Duration _maxAge = Duration(days: 14);

  static Future<Directory> _cacheDir() {
    final d = _dir;
    if (d != null) return Future.value(d);
    return _pending ??= () async {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/thumbs');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    }();
  }

  /// FNV-1a over the URL. Not cryptographic — it only has to be stable and
  /// filename-safe, and the URLs it keys contain tokens and slashes that are not.
  static String _key(String url) {
    var hash = 0xcbf29ce484222325;
    for (final c in url.codeUnits) {
      hash ^= c;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static Future<Uint8List?> read(String url) async {
    try {
      final f = File('${(await _cacheDir()).path}/${_key(url)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null; // a cache miss is never worth surfacing
    }
  }

  static Future<void> write(String url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final f = File('${(await _cacheDir()).path}/${_key(url)}');
      await f.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // Out of space or sandboxed: the app works fine without the cache.
    }
  }

  /// Drop entries older than [_maxAge]. Call once at startup; failures are ignored.
  static Future<void> evictStale() async {
    try {
      final dir = await _cacheDir();
      final cutoff = DateTime.now().subtract(_maxAge);
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (stat.modified.isBefore(cutoff)) await e.delete();
      }
    } catch (_) {
      // Best-effort housekeeping.
    }
  }
}
