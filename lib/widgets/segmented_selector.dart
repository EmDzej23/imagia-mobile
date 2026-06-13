import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class SegmentOption<T> {
  const SegmentOption(this.value, this.label);
  final T value;
  final String label;
}

/// Horizontally-scrollable segmented selector; selected segment uses `primary`
/// fill (design §4). Used for mosaic mode.
class SegmentedSelector<T> extends StatelessWidget {
  const SegmentedSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<SegmentOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final opt in options)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.x2),
              child: GestureDetector(
                onTap: () => onSelected(opt.value),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x4, vertical: AppSpacing.x2),
                  decoration: BoxDecoration(
                    color: opt.value == selected
                        ? AppColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    border: Border.all(
                        color: opt.value == selected
                            ? AppColors.primaryBright
                            : AppColors.border),
                  ),
                  child: Text(
                    opt.label,
                    style: AppTypography.label.copyWith(
                        color: opt.value == selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
