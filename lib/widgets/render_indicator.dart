import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router.dart';
import '../state/render_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// App-wide "mosaic render in progress" indicator. Wraps the whole app (via
/// `MaterialApp.builder`) and shows a tappable pill on every screen while a
/// render runs; tapping returns to the export screen.
class RenderIndicatorOverlay extends ConsumerWidget {
  const RenderIndicatorOverlay({super.key, required this.child});
  final Widget child;

  static const _renderRoute = '/create/export';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rendering = ref.watch(renderControllerProvider
        .select((s) => s.phase == RenderPhase.rendering));
    final router = ref.watch(routerProvider);

    return ListenableBuilder(
      // Rebuild on navigation so we can hide the pill on the render screen.
      listenable: router.routeInformationProvider,
      builder: (context, _) {
        final onRenderScreen =
            router.routeInformationProvider.value.uri.path == _renderRoute;
        return _build(ref, rendering && !onRenderScreen);
      },
    );
  }

  Widget _build(WidgetRef ref, bool showPill) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        child,
        if (showPill)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              minimum: const EdgeInsets.all(AppSpacing.x4),
              child: GestureDetector(
                onTap: () => ref.read(routerProvider).push('/create/export'),
                // Material gives the text a proper DefaultTextStyle (otherwise,
                // sitting above the Navigator, it shows debug yellow underlines).
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
                        child: Text('Rendering your mosaic…',
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
              ),
            ),
          ),
      ],
    );
  }
}
