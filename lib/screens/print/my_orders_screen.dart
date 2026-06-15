import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/print_api.dart';
import '../../state/print_job_controller.dart';
import '../../state/print_providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_card.dart';
import 'order_processing_screen.dart';

class MyOrdersScreen extends ConsumerWidget {
  const MyOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(printOrdersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My print orders')),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.accent,
          onRefresh: () async => ref.invalidate(printOrdersProvider),
          child: orders.when(
            loading: () => const Center(
                child: CircularProgressIndicator(color: AppColors.accent)),
            error: (e, _) => Center(
              child: Text('Could not load orders.\n$e',
                  textAlign: TextAlign.center, style: AppTypography.caption),
            ),
            data: (list) => list.isEmpty
                ? Center(
                    child: Text('No print orders yet',
                        style: AppTypography.body
                            .copyWith(color: AppColors.textSecondary)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.screen),
                    itemCount: list.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.x2),
                    itemBuilder: (_, i) => _OrderTile(order: list[i]),
                  ),
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends ConsumerWidget {
  const _OrderTile({required this.order});
  final PrintOrderDto order;

  ({String label, Color color}) get _status => switch (order.status) {
        'pending_payment' => (label: 'Pending payment', color: AppColors.textMuted),
        'paid' || 'uploading' || 'submitted' =>
          (label: 'Processing', color: AppColors.textSecondary),
        'in_production' => (label: 'In production', color: AppColors.accent),
        'shipped' => (label: 'Shipped', color: AppColors.success),
        'delivered' => (label: 'Delivered', color: AppColors.success),
        'failed' => (label: 'Failed', color: AppColors.error),
        'cancelled' => (label: 'Cancelled', color: AppColors.error),
        _ => (label: order.status, color: AppColors.textSecondary),
      };

  void _resume(BuildContext context, WidgetRef ref) {
    ref.read(printJobControllerProvider.notifier).start(
          orderId: order.id,
          productName: order.productName,
        );
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const OrderProcessingScreen()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = _status;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(order.productName,
                    style: AppTypography.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                child: Text(s.label,
                    style: AppTypography.caption.copyWith(color: s.color)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(order.totalFormatted, style: AppTypography.caption),
          if (order.trackingNumber != null &&
              order.trackingNumber!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.x2),
            Text('Tracking: ${order.trackingNumber}',
                style: AppTypography.caption
                    .copyWith(color: AppColors.textSecondary)),
          ],
          if (order.isResumable) ...[
            const SizedBox(height: AppSpacing.x3),
            Text(
                order.status == 'failed'
                    ? 'Paid, but the order didn\'t go through. Retrying won\'t charge you again.'
                    : 'Paid — finish placing your order.',
                style: AppTypography.caption
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.x2),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _resume(context, ref),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(order.status == 'failed'
                    ? 'Retry order'
                    : 'Resume order'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
