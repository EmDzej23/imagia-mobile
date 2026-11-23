import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../mosaic/types.dart';

/// On-device cache of restored tiles: the thumbnail the server sent, its analysis
/// ([TileDescriptor]) and its recolour grid.
///
/// Opening a project used to download every tile again and analyse each one on the
/// UI thread — decodes plus a GPU read-back per tile, seconds on a low-end Android
/// phone for a 150-tile library, every single time. A tile's blob never changes, so
/// a hit here needs no request and no analysis: just the thumbnail decode.
///
/// Same scheme as `ThumbCache`: one small file per tile, evicted by age.
class TileAnalysisCache {
  TileAnalysisCache._();

  /// Bump when the tile analysis changes, so old results are not reused.
  /// 2: server thumbnails now honour EXIF orientation — v1 entries of phone photos
  /// were analysed (and cached) sideways.
  static const int _version = 2;
  static const Duration _maxAge = Duration(days: 30);

  static Directory? _dir;
  static Future<Directory>? _pending;

  /// Tests: keep the cache in [d] (there is no path_provider in a unit test).
  static void debugUseDirectory(Directory d) => _dir = d;

  static Future<Directory> _cacheDir() {
    final d = _dir;
    if (d != null) return Future.value(d);
    return _pending ??= () async {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/tile-analysis');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    }();
  }

  /// Everything the analysis depends on: the photo (its URL), the size the server
  /// resized it to, and the id and name the descriptor carries.
  static String _key(String url, int maxSize, String id, String name) {
    var hash = 0xcbf29ce484222325;
    for (final c in '$_version|$maxSize|$url|$id|$name'.codeUnits) {
      hash ^= c;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  // File: [json length: 4 bytes][json: descriptor][grid length: 4][grid][thumbnail]
  static Future<CachedTile?> read(String url, int maxSize, String id, String name) async {
    try {
      final f = File('${(await _cacheDir()).path}/${_key(url, maxSize, id, name)}');
      if (!await f.exists()) return null;
      final b = await f.readAsBytes();
      final view = ByteData.sublistView(b);
      var o = 0;
      final jl = view.getUint32(o);
      o += 4;
      final json = jsonDecode(utf8.decode(Uint8List.sublistView(b, o, o + jl)));
      o += jl;
      final gl = view.getUint32(o);
      o += 4;
      final grid = Uint8List.fromList(Uint8List.sublistView(b, o, o + gl));
      o += gl;
      final thumb = Uint8List.fromList(Uint8List.sublistView(b, o));
      if (thumb.isEmpty) return null;
      final d = TileDescriptor.fromJson((json as Map).cast<String, dynamic>());
      if (d.id != id || d.name != name) return null;
      return CachedTile(d, grid.isEmpty ? null : grid, thumb);
    } catch (_) {
      return null; // unreadable → analyse again
    }
  }

  static Future<void> write(
    String url,
    int maxSize,
    TileDescriptor descriptor,
    Uint8List? grid,
    Uint8List thumbBytes,
  ) async {
    if (thumbBytes.isEmpty) return;
    try {
      final json = utf8.encode(jsonEncode(descriptor.toJson()));
      final g = grid ?? Uint8List(0);
      final out = BytesBuilder(copy: false)
        ..add((ByteData(4)..setUint32(0, json.length)).buffer.asUint8List())
        ..add(json)
        ..add((ByteData(4)..setUint32(0, g.length)).buffer.asUint8List())
        ..add(g)
        ..add(thumbBytes);
      final f = File(
        '${(await _cacheDir()).path}/${_key(url, maxSize, descriptor.id, descriptor.name)}',
      );
      await f.writeAsBytes(out.takeBytes(), flush: false);
    } catch (_) {
      // NaN in a descriptor, out of space, sandboxed: the restore works without it.
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
    } catch (_) {}
  }
}

class CachedTile {
  CachedTile(this.descriptor, this.grid, this.thumbBytes);
  final TileDescriptor descriptor;
  final Uint8List? grid;
  final Uint8List thumbBytes;
}
