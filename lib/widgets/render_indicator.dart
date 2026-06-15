import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router.dart';
import '../screens/print/order_processing_screen.dart';
import '../state/print_job_controller.dart';
import '../state/render_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// App-wide progress indicators. Wraps the whole app (via `MaterialApp.builder`)
/// and shows a tappable pill on every screen while long-running work runs —
/// a mosaic render or a print-order finalisation — letting the user return to
/// the screen even if they navigated away. Each pill hides on its own screen.
class RenderIndicatorOverlay extends ConsumerWidget {
  const RenderIndicatorOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rendering = ref.watch(renderControllerProvider
        .select((s) => s.phase == RenderPhase.rendering));
    final onRenderScreen = ref.watch(onRenderScreenProvider);
    final printing = ref.watch(
        printJobControllerProvider.select((s) => s.isProcessing));
    final onPrintScreen = ref.watch(onPrintProcessingScreenProvider);

    final pills = <Widget>[
      if (printing && !onPrintScreen)
        _Pill(
          label: 'Finishing your order…',
          onTap: () => rootNavigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const OrderProcessingScreen()),
          ),
        ),
      if (rendering && !onRenderScreen)
        _Pill(
          label: 'Rendering your mosaic…',
          onTap: () => ref.read(routerProvider).push('/create/export'),
        ),
    ];

    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        child,
        if (pills.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              minimum: const EdgeInsets.all(AppSpacing.x4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pills.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.x2),
                    pills[i],
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Material gives the text a proper DefaultTextStyle (otherwise, sitting
      // above the Navigator, it shows debug yellow underlines).
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
          decoration: BoxDecoration(
            gradient: AppGradients.brand,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: AppGradients.glow(AppColors.gradientEnd),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.textPrimary),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Text(label,
                    style: AppTypography.label
                        .copyWith(color: AppColors.textPrimary)),
              ),
              Text('Tap to view',
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textPrimary)),
              const Icon(Icons.chevron_right,
                  color: AppColors.textPrimary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
