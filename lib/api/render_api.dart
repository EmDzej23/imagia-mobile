import '../mosaic/types.dart';
import 'api_client.dart';

class RenderResult {
  RenderResult({
    required this.downloadUrl,
    required this.downloadToken,
    required this.expiresAt,
    required this.fileName,
    required this.renderTimeMs,
  });
  final String downloadUrl;
  final String downloadToken;
  final String expiresAt;
  final String fileName;
  final int renderTimeMs;

  factory RenderResult.fromJson(Map<String, dynamic> j) => RenderResult(
        downloadUrl: j['downloadUrl'] as String? ?? '',
        downloadToken: j['downloadToken'] as String? ?? '',
        expiresAt: j['expiresAt'] as String? ?? '',
        fileName: j['fileName'] as String? ?? 'mosaic.jpg',
        renderTimeMs: (j['renderTimeMs'] as num?)?.toInt() ?? 0,
      );
}

/// Final high-res render via `POST /api/render`.
///
/// IMPORTANT: uses **`mode: "sync"`**, mirroring the web client. The route's
/// render-service (Cloud Run) branch runs first and returns the result directly
/// — it never issues a `jobId`, so an async/poll flow breaks in production. The
/// HTTP request therefore stays open for the whole render; we use a long
/// receive timeout.
class RenderApi {
  RenderApi(this._client);
  final ApiClient _client;

  static const _renderTimeout = Duration(minutes: 6);

  Future<ApiResult<RenderResult>> render({
    required SlimMosaicPlan plan,
    required Map<String, String> tileUrls,
    String? baseUrl,
    String? fileName,
  }) async {
    final res = await _client.post<Map<String, dynamic>>(
      '/api/render',
      body: {
        'mode': 'sync',
        'plan': plan.toJson(),
        'tileUrls': tileUrls,
        if (baseUrl != null) 'baseUrl': baseUrl,
        if (fileName != null) 'fileName': fileName,
      },
      receiveTimeout: _renderTimeout,
      sendTimeout: const Duration(minutes: 2),
    );
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Render failed.', res.status);
    }
    final data = res.data!;
    if (data['success'] != true || data['downloadUrl'] == null) {
      return ApiResult.fail(
          data['error'] as String? ?? 'Render failed.', res.status);
    }
    return ApiResult.ok(RenderResult.fromJson(data), res.status);
  }
}
