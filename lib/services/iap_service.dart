import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';

import '../api/iap_api.dart';
import '../state/auth_controller.dart';

/// Store billing for consumable token packs — App Store on iOS, Google Play on
/// Android. Both stores require their own billing for digital credits consumed
/// in-app, so tokens are bought here (prints still use Creem, as physical goods).
///
/// Product ids are the SAME on both stores and MUST match App Store Connect, Play
/// Console, and the server's `APPLE_TOKEN_PRODUCTS` / `GOOGLE_TOKEN_PRODUCTS` maps.
///
/// The two platforms differ in one important way — who consumes the purchase:
///  * iOS: StoreKit consumables are consumed by finishing the transaction, which we
///    already do only after the server has verified.
///  * Android: the plugin's default `autoConsume` consumes ON THE DEVICE as soon as
///    the purchase lands — before we have verified it. A verify that then failed
///    would leave the customer charged with nothing to retry. So Android buys with
///    `autoConsume: false` and the SERVER consumes after crediting.
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
      ..sort((a, b) => (productTokens[a.id] ?? 0).compareTo(productTokens[b.id] ?? 0));
    return list;
  }

  /// Starts a consumable purchase (the store shows its payment sheet).
  Future<void> buy(ProductDetails product) {
    return _iap.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
      // iOS: must stay true (the StoreKit implementation asserts it). Android: false,
      // so the purchase survives until the server has credited it — see class docs.
      autoConsume: !Platform.isAndroid,
    );
  }

  /// Re-delivers purchases the store still considers owned (Android).
  ///
  /// Play does not push an unfinished purchase back by itself. If a verify failed
  /// mid-flight the purchase stays owned and unconsumed — this hands it back through
  /// [purchaseStream] as `restored`, where it is verified and credited like a new one
  /// (the server is idempotent per purchase token). iOS is deliberately excluded: there
  /// it can prompt for an Apple ID, and StoreKit re-queues unfinished transactions on
  /// its own.
  Future<void> recoverUnfinished() async {
    if (!Platform.isAndroid) return;
    try {
      await _iap.restorePurchases();
    } catch (_) {
      // Best-effort: nothing is lost by failing here; the next launch tries again.
    }
  }

  /// Verifies a purchased/restored transaction server-side, then finishes it.
  /// Returns the new token balance. Throws if verification fails — we must NOT
  /// finish an unverified transaction (so it can be retried).
  Future<int> verifyAndComplete(PurchaseDetails purchase) async {
    if (Platform.isAndroid) return _verifyAndCompleteGoogle(purchase);

    var receipt = purchase.verificationData.serverVerificationData;

    // On StoreKit 1 that string IS the app receipt — and a build installed outside
    // the App Store (flutter run, Xcode) can have no receipt on disk at all, so it
    // arrives empty and Apple answers 21002 ("receipt-data malformed"). Asking the
    // store to write one is the documented remedy, so do it before wasting a round
    // trip. Harmless when a receipt already exists.
    if (Platform.isIOS && receipt.isEmpty) {
      receipt = await _refreshedReceipt() ?? receipt;
    }

    var res = await _api.verifyApple(receipt);

    // Same failure, found the expensive way: retry ONCE against a freshly written
    // receipt. Bounded deliberately — a receipt that is still malformed after a
    // refresh is a real problem, and looping would only hide it.
    if (!res.isOk && Platform.isIOS && (res.error?.contains('21002') ?? false)) {
      final refreshed = await _refreshedReceipt();
      if (refreshed != null && refreshed.isNotEmpty && refreshed != receipt) {
        res = await _api.verifyApple(refreshed);
      }
    }

    if (!res.isOk || res.data == null) {
      throw res.error ?? 'Could not verify purchase.';
    }
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
    return res.data!.balance;
  }

  /// Android: `serverVerificationData` is the Play purchase token. The server
  /// verifies, credits once per token, and consumes — so all that is left here is to
  /// finish the purchase locally, and only after the server said yes.
  Future<int> _verifyAndCompleteGoogle(PurchaseDetails purchase) async {
    final res = await _api.verifyGoogle(
      purchase.productID,
      purchase.verificationData.serverVerificationData,
    );
    if (!res.isOk || res.data == null) {
      throw res.error ?? 'Could not verify purchase.';
    }
    if (purchase.pendingCompletePurchase) {
      // Acknowledges. The server already consumed it (which implies acknowledgement),
      // so Play may answer that it is no longer owned — harmless, the tokens are in.
      try {
        await _iap.completePurchase(purchase);
      } catch (_) {}
    }
    return res.data!.balance;
  }

  /// Ask StoreKit to (re)write the app receipt and hand back the new one.
  ///
  /// iOS only, and best-effort: it prompts for an Apple ID in sandbox, and any
  /// failure just means we verify with what we already had.
  Future<String?> _refreshedReceipt() async {
    try {
      final addition = InAppPurchase.instance
          .getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      final data = await addition.refreshPurchaseVerificationData();
      final v = data?.serverVerificationData;
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
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
final iapServiceProvider = Provider<IapService>(
  (ref) => IapService(ref.watch(iapApiProvider)),
);
