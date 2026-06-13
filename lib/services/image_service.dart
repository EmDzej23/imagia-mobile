import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Resizes + JPEG-compresses picked images before upload, keeping payloads
/// under the server's ~4.5MB body limit. Caps mirror the RN reference:
/// base ≤ 2000px, tiles ≤ 600px.
///
/// `flutter_image_compress` is NOT safe to call concurrently (concurrent calls
/// can fail or return empty), but tile ingest runs many uploads in parallel —
/// so all compression is funnelled through a serialization lock here while the
/// network uploads still fan out.
class ImageService {
  Future<void> _lock = Future<void>.value();

  Future<Uint8List> _serialized(Future<Uint8List> Function() task) {
    final result = _lock.then((_) => task());
    // Track completion (ignoring errors) so the next call waits its turn.
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> compressBase(Uint8List bytes) => _serialized(
        () => FlutterImageCompress.compressWithList(
          bytes,
          minWidth: 2000,
          minHeight: 2000,
          quality: 85,
          format: CompressFormat.jpeg,
        ),
      );

  Future<Uint8List> compressTile(Uint8List bytes) => _serialized(
        () => FlutterImageCompress.compressWithList(
          bytes,
          minWidth: 600,
          minHeight: 600,
          quality: 85,
          format: CompressFormat.jpeg,
        ),
      );
}
