import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Resizes + JPEG-compresses picked images before upload, keeping payloads
/// under the server's ~4.5MB body limit. Caps mirror the RN reference:
/// base ≤ 2000px, tiles ≤ 600px.
class ImageService {
  Future<Uint8List> compressBase(Uint8List bytes) =>
      FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 2000,
        minHeight: 2000,
        quality: 85,
        format: CompressFormat.jpeg,
      );

  Future<Uint8List> compressTile(Uint8List bytes) =>
      FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 600,
        minHeight: 600,
        quality: 85,
        format: CompressFormat.jpeg,
      );
}
