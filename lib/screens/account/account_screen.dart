import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/checkout_api.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/secondary_button.dart';
import 'checkout_webview_screen.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  TokenPackage? _loading;

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
            Container(
              padding: const EdgeInsets.all(AppSpacing.x4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.border),
              ),
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
                        child: Text(
                          '${user?.tokenBalance ?? 0} token${(user?.tokenBalance ?? 0) == 1 ? '' : 's'}',
                          style: AppTypography.number(AppTypography.label)
                              .copyWith(color: AppColors.accent),
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
            const SizedBox(height: AppSpacing.x6),
            SecondaryButton(
              label: 'Sign out',
              icon: Icons.logout,
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
            ),
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
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  child: Text('\$${pkg.price.toStringAsFixed(2)}',
                      style: AppTypography.label),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
