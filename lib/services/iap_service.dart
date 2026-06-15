import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../api/iap_api.dart';
import '../state/auth_controller.dart';

/// Apple In-App Purchase for consumable token packs (iOS). Apple requires
/// digital content/credits consumed in-app to use IAP, not external payment —
/// so on iOS tokens are bought here (prints still use Creem, as physical goods).
///
/// Product ids MUST match App Store Connect and the server's
/// `APPLE_TOKEN_PRODUCTS` map.
class IapService {
  IapService(this._api);
  final IapApi _api;
  final InAppPurchase _iap = InAppPurchase.instance;

  /// Token-pack product ids → number of tokens (for labels/ordering).
  static const Map<String, int> productTokens = {
    'com.imagiastore.studio.tokens.single': 1,
    'com.imagiastore.studio.tokens.pack5': 5,
    'com.imagiastore.studio.tokens.pack10': 10,
  };

  static Set<String> get productIds => productTokens.keys.toSet();

  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  Future<bool> available() => _iap.isAvailable();

  Future<List<ProductDetails>> loadProducts() async {
    final resp = await _iap.queryProductDetails(productIds);
    final list = resp.productDetails
      ..sort((a, b) =>
          (productTokens[a.id] ?? 0).compareTo(productTokens[b.id] ?? 0));
    return list;
  }

  /// Starts a consumable purchase (Apple shows its payment sheet).
  Future<void> buy(ProductDetails product) {
    return _iap.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
    );
  }

  /// Verifies a purchased/restored transaction server-side, then finishes it.
  /// Returns the new token balance. Throws if verification fails — we must NOT
  /// finish an unverified transaction (so it can be retried).
  Future<int> verifyAndComplete(PurchaseDetails purchase) async {
    final receipt = purchase.verificationData.serverVerificationData;
    final res = await _api.verifyApple(receipt);
    if (!res.isOk || res.data == null) {
      throw res.error ?? 'Could not verify purchase.';
    }
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
    return res.data!.balance;
  }

  /// Finishes a transaction without crediting (e.g. a canceled/errored one that
  /// still needs to be cleared from the queue).
  Future<void> complete(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }
}

final iapApiProvider = Provider<IapApi>((ref) => IapApi(ref.watch(apiClientProvider)));
final iapServiceProvider =
    Provider<IapService>((ref) => IapService(ref.watch(iapApiProvider)));
