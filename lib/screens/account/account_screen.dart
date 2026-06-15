import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/checkout_api.dart';
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
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.x3, vertical: AppSpacing.x1),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceRaised,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: TweenAnimationBuilder<int>(
                          tween: IntTween(begin: 0, end: user?.tokenBalance ?? 0),
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
            const SizedBox(height: AppSpacing.x6),
            Text('Buy tokens', style: AppTypography.label),
            const SizedBox(height: AppSpacing.x1),
            Text('Each token renders one high-resolution mosaic.',
                style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x3),
            for (final pkg in TokenPackage.values)
              _PackageTile(
                pkg: pkg,
                loading: _loading == pkg,
                disabled: _loading != null,
                onTap: () => _purchase(pkg),
              ),
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
