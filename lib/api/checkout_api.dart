import 'api_client.dart';

enum TokenPackage { single, pack5, pack10 }

extension TokenPackageInfo on TokenPackage {
  /// Server package key.
  String get key => switch (this) {
        TokenPackage.single => 'single',
        TokenPackage.pack5 => '5pack',
        TokenPackage.pack10 => '10pack',
      };

  String get label => switch (this) {
        TokenPackage.single => '1 Mosaic Token',
        TokenPackage.pack5 => '5 Mosaic Tokens',
        TokenPackage.pack10 => '10 Mosaic Tokens',
      };

  double get price => switch (this) {
        TokenPackage.single => 14.99,
        TokenPackage.pack5 => 49.99,
        TokenPackage.pack10 => 85.99,
      };

  int get tokens => switch (this) {
        TokenPackage.single => 1,
        TokenPackage.pack5 => 5,
        TokenPackage.pack10 => 10,
      };
}

/// Token purchase via Creem. `POST /api/checkout` creates a hosted checkout and
/// returns its URL; the app opens it, and on the `/payment-success` redirect
/// the server credits tokens (we then refresh the balance). Mirrors the RN
/// reference `lib/api/checkout.ts`.
class CheckoutApi {
  CheckoutApi(this._client);
  final ApiClient _client;

  Future<ApiResult<String>> createCheckout(TokenPackage pkg) async {
    final res = await _client
        .post<Map<String, dynamic>>('/api/checkout', body: {'package': pkg.key});
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Could not start checkout.', res.status);
    }
    final url = res.data!['checkout_url'] as String?;
    if (url == null || url.isEmpty) {
      return ApiResult.fail('Checkout did not return a URL.', res.status);
    }
    return ApiResult.ok(url, res.status);
  }
}
