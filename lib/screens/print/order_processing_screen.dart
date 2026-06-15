import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/print_job_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';
import 'my_orders_screen.dart';

/// Shows the progress of finalising a paid print order. The work runs in a
/// global controller, so the user can safely leave and return (via the app-wide
/// indicator) — the order keeps processing regardless.
class OrderProcessingScreen extends ConsumerStatefulWidget {
  const OrderProcessingScreen({super.key});

  @override
  ConsumerState<OrderProcessingScreen> createState() =>
      _OrderProcessingScreenState();
}

class _OrderProcessingScreenState extends ConsumerState<OrderProcessingScreen> {
  ProviderContainer? _container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(onPrintProcessingScreenProvider.notifier).value = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    final container = _container;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      container?.read(onPrintProcessingScreenProvider.notifier).value = false;
    });
    super.dispose();
  }

  void _viewOrders() {
    ref.read(printJobControllerProvider.notifier).reset();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MyOrdersScreen()),
      (r) => r.isFirst,
    );
  }

  void _done() {
    ref.read(printJobControllerProvider.notifier).reset();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Leaving while the job is still running: go to My Orders (not back to the
  /// paid review/shipping screens). The job keeps running and the app-wide
  /// indicator lets the user return.
  void _leaveToOrders() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MyOrdersScreen()),
      (r) => r.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(printJobControllerProvider);

    return PopScope(
      // We never pop back to the (paid) review/shipping screens; handle back
      // ourselves → My Orders while working, or home when done.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (job.phase == PrintJobPhase.done) {
          _done();
        } else {
          _leaveToOrders();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your order'),
          automaticallyImplyLeading: false,
          leading: job.phase == PrintJobPhase.done
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _leaveToOrders,
                ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x6),
            child: Center(child: _body(job)),
          ),
        ),
      ),
    );
  }

  Widget _body(PrintJobState job) {
    switch (job.phase) {
      case PrintJobPhase.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 72, color: AppColors.success),
            const SizedBox(height: AppSpacing.x4),
            Text('Your print is on its way to production',
                textAlign: TextAlign.center, style: AppTypography.title),
            const SizedBox(height: AppSpacing.x2),
            Text(
                'We\'ll notify you when it ships. You can track it under My orders.',
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(label: 'View my orders', onPressed: _viewOrders),
            const SizedBox(height: AppSpacing.x3),
            TextButton(onPressed: _done, child: const Text('Done')),
          ],
        );
      case PrintJobPhase.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 72, color: AppColors.error),
            const SizedBox(height: AppSpacing.x4),
            Text('We couldn\'t finish your order',
                textAlign: TextAlign.center, style: AppTypography.title),
            const SizedBox(height: AppSpacing.x2),
            Text(
                job.error ??
                    'Your payment went through. Tap retry to place the order again.',
                textAlign: TextAlign.center,
                style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x2),
            Text('Your payment is safe — retrying won\'t charge you again.',
                textAlign: TextAlign.center,
                style: AppTypography.caption
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: () {
                final id = job.orderId;
                if (id == null) return;
                ref.read(printJobControllerProvider.notifier).start(
                      orderId: id,
                      productName: job.productName ?? 'Print',
                    );
              },
            ),
            const SizedBox(height: AppSpacing.x3),
            SecondaryButton(label: 'View my orders', onPressed: _viewOrders),
          ],
        );
      default:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.accent),
            const SizedBox(height: AppSpacing.x6),
            Text(job.productName ?? 'Your print',
                textAlign: TextAlign.center, style: AppTypography.title),
            const SizedBox(height: AppSpacing.x2),
            Text(job.step.isEmpty ? 'Placing your order…' : job.step,
                textAlign: TextAlign.center, style: AppTypography.body),
            const SizedBox(height: AppSpacing.x2),
            Text(
                'This can take a minute. You can leave this screen — we\'ll keep working and notify you when it ships.',
                textAlign: TextAlign.center,
                style: AppTypography.caption
                    .copyWith(color: AppColors.textSecondary)),
          ],
        );
    }
  }
}
