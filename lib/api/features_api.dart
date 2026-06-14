import 'api_client.dart';

/// Server feature flags / limits from `GET /api/features`. We mainly need the
/// in-app **max output resolution** so the render produces full-size output
/// (the regular render uses the plan's `outputWidth`, so the client must set
/// it — same as the web does at export).
class FeaturesApi {
  FeaturesApi(this._client);
  final ApiClient _client;

  /// In-app max output long side (px), or null if it can't be determined.
  Future<int?> maxResolution() async {
    final res = await _client.get<Map<String, dynamic>>('/api/features');
    if (res.isOk && res.data != null) {
      final v = (res.data!['maxResolution'] as num?)?.toInt();
      if (v != null && v >= 1000) return v;
    }
    return null;
  }
}
