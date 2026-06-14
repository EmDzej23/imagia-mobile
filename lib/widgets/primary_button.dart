import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'pressable.dart';

/// Filled primary action with the brand gradient + soft glow. Full-width on
/// action screens; shows a spinner while [loading]. Design §4.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.icon,
    this.fullWidth = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    return PressableScale(
      onPressed: enabled ? onPressed : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.45,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: fullWidth ? double.infinity : null,
          height: AppSpacing.touchTarget,
          decoration: BoxDecoration(
            gradient: AppGradients.brand,
            borderRadius: BorderRadius.circular(AppRadius.control),
            boxShadow: enabled
                ? AppGradients.glow(AppColors.gradientEnd, opacity: 0.35)
                : null,
          ),
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textPrimary,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20, color: AppColors.textPrimary),
                      const SizedBox(width: AppSpacing.x2),
                    ],
                    Text(label,
                        style: AppTypography.label
                            .copyWith(color: AppColors.textPrimary)),
                  ],
                ),
        ),
      ),
    );
  }
}
