import 'api_client.dart';

class DownloadRecord {
  DownloadRecord({
    required this.id,
    required this.downloadToken,
    required this.fileName,
    required this.expiresAt,
    required this.createdAt,
    this.fileSizeBytes,
  });

  final String id;
  final String downloadToken;
  final String fileName;
  final String expiresAt;
  final String createdAt;
  final int? fileSizeBytes;

  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
        id: j['id'] as String,
        downloadToken: j['downloadToken'] as String? ?? '',
        fileName: j['fileName'] as String? ?? 'mosaic.jpg',
        expiresAt: j['expiresAt']?.toString() ?? '',
        createdAt: j['createdAt']?.toString() ?? '',
        fileSizeBytes: (j['fileSizeBytes'] as num?)?.toInt(),
      );

  /// Public download endpoint resolving the signed blob (relative to base URL).
  String get downloadPath => '/api/download/$downloadToken';
}

/// Rendered mosaic download history. Mirrors RN `lib/api/downloads.ts`.
class DownloadsApi {
  DownloadsApi(this._client);
  final ApiClient _client;

  Future<ApiResult<List<DownloadRecord>>> list({int page = 1}) async {
    final res = await _client
        .get<Map<String, dynamic>>('/api/downloads', query: {'page': '$page'});
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Failed to load downloads.', res.status);
    }
    final list = (res.data!['downloads'] as List? ?? [])
        .map((e) => DownloadRecord.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return ApiResult.ok(list, res.status);
  }
}
