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

  /// Server-chosen base-image preprocessing defaults, or null if unavailable.
  ///
  /// These decide what the matcher aims at, and the matching runs ON THIS DEVICE — so
  /// the server cannot enforce them for us, it can only tell us. Reading them here is
  /// what turns retuning mosaic quality into a config change rather than a new build
  /// and an App Store review.
  ///
  /// Null on any failure, and the caller keeps its built-in defaults: a studio that
  /// will not open because a config request timed out is far worse than one using
  /// last month's numbers.
  Future<({double colorBoost, double autoContrast})?> mosaicDefaults() async {
    final res = await _client.get<Map<String, dynamic>>('/api/features');
    if (!res.isOk || res.data == null) return null;
    final m = res.data!['mosaicDefaults'];
    if (m is! Map) return null;
    final cb = (m['colorBoost'] as num?)?.toDouble();
    final ac = (m['autoContrast'] as num?)?.toDouble();
    if (cb == null || ac == null) return null;
    // Clamped to the same bounds sanitizeSettings uses — a bad server value must not
    // be able to push the engine outside the range it was tuned in.
    return (
      colorBoost: cb.clamp(1.0, 2.0).toDouble(),
      autoContrast: ac.clamp(0.0, 1.0).toDouble(),
    );
  }
}
