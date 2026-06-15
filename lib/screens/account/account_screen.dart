import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../api/checkout_api.dart';
import '../../core/config.dart';
import '../../services/iap_service.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_card.dart';
import '../../widgets/secondary_button.dart';
import '../../print/print_catalog.dart' show isPrintRegionAllowed;
import '../legal/help_screen.dart';
import '../legal/legal_screen.dart';
import '../print/my_orders_screen.dart';
import 'checkout_webview_screen.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  TokenPackage? _loading;
  bool _deleting = false;

  // iOS In-App Purchase state.
  final bool _useIap = Platform.isIOS;
  List<ProductDetails> _iapProducts = [];
  bool _iapLoading = false;
  bool _iapUnavailable = false;
  String? _iapBusyProductId;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  @override
  void initState() {
    super.initState();
    if (_useIap) _initIap();
  }

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }

  Future<void> _initIap() async {
    setState(() => _iapLoading = true);
    final iap = ref.read(iapServiceProvider);
    // Listen first so interrupted/pending transactions are delivered on launch.
    _purchaseSub = iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (_) {},
    );
    try {
      if (!await iap.available()) {
        if (mounted) setState(() => _iapUnavailable = true);
        return;
      }
      final products = await iap.loadProducts();
      if (mounted) setState(() => _iapProducts = products);
    } finally {
      if (mounted) setState(() => _iapLoading = false);
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    final iap = ref.read(iapServiceProvider);
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          if (mounted) setState(() => _iapBusyProductId = p.productID);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            await iap.verifyAndComplete(p);
            await ref.read(authControllerProvider.notifier).refreshUser();
            _snack('Tokens added — thank you!');
          } catch (e) {
            _snack('Purchase verification failed: $e');
          } finally {
            if (mounted) setState(() => _iapBusyProductId = null);
          }
        case PurchaseStatus.error:
          await iap.complete(p); // clear it from the queue
          _snack(p.error?.message ?? 'Purchase failed.');
          if (mounted) setState(() => _iapBusyProductId = null);
        case PurchaseStatus.canceled:
          if (mounted) setState(() => _iapBusyProductId = null);
      }
    }
  }

  Future<void> _buyIap(ProductDetails product) async {
    if (_iapBusyProductId != null) return;
    setState(() => _iapBusyProductId = product.id);
    try {
      await ref.read(iapServiceProvider).buy(product);
    } catch (e) {
      _snack('Could not start purchase: $e');
      if (mounted) setState(() => _iapBusyProductId = null);
    }
  }

  List<Widget> _buildIapTiles() {
    if (_iapLoading) {
      return const [
        Padding(
          padding: EdgeInsets.all(AppSpacing.x4),
          child: Center(
              child: CircularProgressIndicator(color: AppColors.accent)),
        ),
      ];
    }
    if (_iapUnavailable || _iapProducts.isEmpty) {
      return [
        Text(
          'Token purchases are unavailable right now. Please try again later.',
          style:
              AppTypography.caption.copyWith(color: AppColors.textSecondary),
        ),
      ];
    }
    return [
      for (final p in _iapProducts)
        _IapTile(
          product: p,
          tokens: IapService.productTokens[p.id] ?? 0,
          loading: _iapBusyProductId == p.id,
          disabled: _iapBusyProductId != null,
          onTap: () => _buyIap(p),
        ),
    ];
  }

  Future<void> _purchase(TokenPackage pkg) async {
    setState(() => _loading = pkg);
    try {
      final res = await ref.read(checkoutApiProvider).createCheckout(pkg);
      if (!res.isOk || res.data == null) {
        _snack(res.error ?? 'Could not start checkout.');
        return;
      }
      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => CheckoutWebviewScreen(checkoutUrl: res.data!),
        ),
      );
      // Refresh balance regardless — the purchase may have completed even if we
      // didn't detect the redirect.
      await ref.read(authControllerProvider.notifier).refreshUser();
      if (ok == true) _snack('Tokens added — thank you!');
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
            'This permanently deletes your account, mosaics, projects, tokens '
            'and order history. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      // On success the auth state flips to signedOut and the router redirects.
      await ref.read(authControllerProvider.notifier).deleteAccount();
    } catch (e) {
      _snack('$e');
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            // Profile + balance
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user?.name ?? '—', style: AppTypography.title),
                  Text(user?.email ?? '',
                      style: AppTypography.body
                          .copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: AppSpacing.x3),
                  if (AppConfig.freeRenders)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.x3, vertical: AppSpacing.x1),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text('Mosaics are free to create',
                          style: AppTypography.label
                              .copyWith(color: AppColors.accent)),
                    )
                  else
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.x3,
                              vertical: AppSpacing.x1),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceRaised,
                            borderRadius:
                                BorderRadius.circular(AppRadius.chip),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: TweenAnimationBuilder<int>(
                            tween: IntTween(
                                begin: 0, end: user?.tokenBalance ?? 0),
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOut,
                            builder: (_, value, _) => Text(
                              '$value token${value == 1 ? '' : 's'}',
                              style: AppTypography.number(AppTypography.label)
                                  .copyWith(color: AppColors.accent),
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => ref
                              .read(authControllerProvider.notifier)
                              .refreshUser(),
                          child: const Text('Refresh'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            // Token purchases are hidden during the free-render launch bridge.
            if (!AppConfig.freeRenders) ...[
              const SizedBox(height: AppSpacing.x6),
              Text('Buy tokens', style: AppTypography.label),
              const SizedBox(height: AppSpacing.x1),
              Text('Each token renders one high-resolution mosaic.',
                  style: AppTypography.caption),
              const SizedBox(height: AppSpacing.x3),
              if (_useIap)
                ..._buildIapTiles()
              else
                for (final pkg in TokenPackage.values)
                  _PackageTile(
                    pkg: pkg,
                    loading: _loading == pkg,
                    disabled: _loading != null,
                    onTap: () => _purchase(pkg),
                  ),
            ],
            if (isPrintRegionAllowed()) ...[
              const SizedBox(height: AppSpacing.x6),
              _LinkTile(
                icon: Icons.local_shipping_outlined,
                label: 'My print orders',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyOrdersScreen()),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.x6),
            Text('Help & legal', style: AppTypography.label),
            const SizedBox(height: AppSpacing.x2),
            _LinkTile(
              icon: Icons.help_outline,
              label: 'How it works',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HelpScreen()),
              ),
            ),
            _LinkTile(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy Policy',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LegalScreen.privacy()),
              ),
            ),
            _LinkTile(
              icon: Icons.description_outlined,
              label: 'Terms of Service',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LegalScreen.terms()),
              ),
            ),
            const SizedBox(height: AppSpacing.x6),
            SecondaryButton(
              label: 'Sign out',
              icon: Icons.logout,
              onPressed: _deleting
                  ? null
                  : () => ref.read(authControllerProvider.notifier).signOut(),
            ),
            const SizedBox(height: AppSpacing.x2),
            TextButton.icon(
              onPressed: _deleting ? null : _confirmDeleteAccount,
              icon: _deleting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.error),
                    )
                  : const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete account'),
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.x3),
            Expanded(child: Text(label, style: AppTypography.body)),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({
    required this.pkg,
    required this.loading,
    required this.disabled,
    required this.onTap,
  });

  final TokenPackage pkg;
  final bool loading;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: AppCard(
        onTap: disabled ? null : onTap,
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pkg.label, style: AppTypography.label),
                  const SizedBox(height: 2),
                  Text(
                    '\$${(pkg.price / pkg.tokens).toStringAsFixed(2)} per render',
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppGradients.brand,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
                  child: Text('\$${pkg.price.toStringAsFixed(2)}',
                      style: AppTypography.label
                          .copyWith(color: AppColors.textPrimary)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Token-pack tile backed by an Apple IAP product (Apple's localized price).
class _IapTile extends StatelessWidget {
  const _IapTile({
    required this.product,
    required this.tokens,
    required this.loading,
    required this.disabled,
    required this.onTap,
  });

  final ProductDetails product;
  final int tokens;
  final bool loading;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = '$tokens Mosaic Token${tokens == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: AppCard(
        onTap: disabled ? null : onTap,
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTypography.label),
                  const SizedBox(height: 2),
                  Text('Renders ${tokens == 1 ? 'one mosaic' : '$tokens mosaics'}',
                      style: AppTypography.caption),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppGradients.brand,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
                  child: Text(product.price,
                      style: AppTypography.label
                          .copyWith(color: AppColors.textPrimary)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
