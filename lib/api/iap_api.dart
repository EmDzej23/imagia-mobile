import 'api_client.dart';

class IapVerifyResult {
  IapVerifyResult({required this.creditedTokens, required this.balance});
  final int creditedTokens;
  final int balance;
}

/// Verifies store purchases server-side — Apple receipts (`/api/iap/apple/verify`)
/// and Google Play purchase tokens (`/api/iap/google/verify`) — which credits token
/// packs and returns the new balance.
class IapApi {
  IapApi(this._client);
  final ApiClient _client;

  Future<ApiResult<IapVerifyResult>> verifyApple(String receipt) async {
    final res = await _client.post<Map<String, dynamic>>(
      '/api/iap/apple/verify',
      body: {'receipt': receipt},
    );
    if (!res.isOk || res.data == null || res.data!['success'] != true) {
      return ApiResult.fail(
        res.error ?? (res.data?['error'] as String?) ?? 'Verification failed.',
        res.status,
      );
    }
    return ApiResult.ok(
      IapVerifyResult(
        creditedTokens: (res.data!['creditedTokens'] as num?)?.toInt() ?? 0,
        balance: (res.data!['balance'] as num?)?.toInt() ?? 0,
      ),
      res.status,
    );
  }

  /// Verifies a Google Play purchase (`POST /api/iap/google/verify`). The server
  /// credits it once AND consumes it — see foto-mozaik/lib/iap-google.ts for why
  /// consuming is the server's job, not the device's.
  Future<ApiResult<IapVerifyResult>> verifyGoogle(
    String productId,
    String purchaseToken,
  ) async {
    final res = await _client.post<Map<String, dynamic>>(
      '/api/iap/google/verify',
      body: {'productId': productId, 'purchaseToken': purchaseToken},
    );
    if (!res.isOk || res.data == null || res.data!['success'] != true) {
      return ApiResult.fail(
        res.error ?? (res.data?['error'] as String?) ?? 'Verification failed.',
        res.status,
      );
    }
    return ApiResult.ok(
      IapVerifyResult(
        creditedTokens: (res.data!['creditedTokens'] as num?)?.toInt() ?? 0,
        balance: (res.data!['balance'] as num?)?.toInt() ?? 0,
      ),
      res.status,
    );
  }
}
