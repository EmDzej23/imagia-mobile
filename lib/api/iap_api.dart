import 'api_client.dart';

class IapVerifyResult {
  IapVerifyResult({required this.creditedTokens, required this.balance});
  final int creditedTokens;
  final int balance;
}

/// Verifies Apple IAP receipts server-side (`POST /api/iap/apple/verify`), which
/// credits token packs and returns the new balance.
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
}
