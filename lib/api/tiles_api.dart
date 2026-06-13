import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';

class TileUploadResult {
  TileUploadResult(this.tileId, this.blobUrl, this.pathname);
  final String tileId;
  final String blobUrl;
  final String pathname;
}

/// A free sample tile already hosted on the server — imported by reusing its
/// existing [blobUrl] (no upload needed), like a project restore.
class SampleTile {
  SampleTile(this.blobUrl, this.pathname);
  final String blobUrl;
  final String pathname;
}

/// Tile + base image uploads (multipart) to Vercel Blob via the server.
/// Mirrors the RN reference `lib/api/tiles.ts`.
class TilesApi {
  TilesApi(this._client);
  final ApiClient _client;

  Future<ApiResult<TileUploadResult>> uploadTile(
    Uint8List bytes,
    String tileId,
    String filename, {
    String mimeType = 'image/jpeg',
  }) async {
    final form = FormData.fromMap({
      'tileId': tileId,
      'file': MultipartFile.fromBytes(bytes,
          filename: filename, contentType: DioMediaType.parse(mimeType)),
    });
    final res =
        await _client.post<Map<String, dynamic>>('/api/tiles/upload', body: form);
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Tile upload failed.', res.status);
    }
    final d = res.data!;
    return ApiResult.ok(
      TileUploadResult(
          d['tileId'] as String, d['blobUrl'] as String, d['pathname'] as String),
      res.status,
    );
  }

  /// Lists a free sample tile pack (server-hosted blobs, up to 500). The blobs
  /// already exist, so callers reuse [SampleTile.blobUrl] directly at render
  /// time — no per-tile upload.
  Future<ApiResult<List<SampleTile>>> sampleTiles(String folder) async {
    final res = await _client.get<Map<String, dynamic>>('/api/sample-tiles',
        query: {'folder': folder});
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Could not load samples.', res.status);
    }
    final tiles = (res.data!['tiles'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .map((m) => SampleTile(m['blobUrl'] as String, m['pathname'] as String))
        .toList();
    return ApiResult.ok(tiles, res.status);
  }

  /// Max URLs the server accepts per `/api/tile-thumb-batch` request.
  static const int thumbBatchMax = 60;

  /// Fetches many tile blobs in ONE request — the server pulls them (fast,
  /// server-side) and returns each resized to [maxSize] as base64 JPEG. Far
  /// fewer round-trips than per-tile fetches; used to speed up project restore.
  /// Returns a map of blobUrl → decoded JPEG bytes (missing entries omitted).
  Future<Map<String, Uint8List>> tileThumbBatch(List<String> urls,
      {int maxSize = 256}) async {
    final res = await _client.post<Map<String, dynamic>>('/api/tile-thumb-batch',
        body: {'urls': urls, 'maxSize': maxSize});
    final out = <String, Uint8List>{};
    if (res.isOk && res.data != null) {
      for (final r in (res.data!['results'] as List? ?? const [])) {
        final m = (r as Map).cast<String, dynamic>();
        final data = m['data'];
        final url = m['url'] as String?;
        if (url != null && data is String) {
          out[url] = base64Decode(data);
        }
      }
    }
    return out;
  }

  Future<ApiResult<({String blobUrl, String pathname})>> uploadBase(
    Uint8List bytes,
    String filename, {
    String mimeType = 'image/jpeg',
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes,
          filename: filename, contentType: DioMediaType.parse(mimeType)),
    });
    final res =
        await _client.post<Map<String, dynamic>>('/api/base/upload', body: form);
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Base upload failed.', res.status);
    }
    final d = res.data!;
    return ApiResult.ok(
        (blobUrl: d['blobUrl'] as String, pathname: d['pathname'] as String),
        res.status);
  }
}
