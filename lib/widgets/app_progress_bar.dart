import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Determinate linear progress in the `accent` color (design §4).
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({super.key, required this.percent});

  /// 0–100.
  final double percent;

  @override
  Widget build(BuildContext context) {
    final value = (percent / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              const Positioned.fill(
                  child: ColoredBox(color: AppColors.border)),
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                width: c.maxWidth * value,
                decoration: const BoxDecoration(gradient: AppGradients.brand),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Indeterminate accent progress bar (for sync renders with no known percent).
class AppIndeterminateBar extends StatelessWidget {
  const AppIndeterminateBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: const LinearProgressIndicator(
        minHeight: 6,
        backgroundColor: AppColors.border,
        valueColor: AlwaysStoppedAnimation(AppColors.accent),
      ),
    );
  }
}
