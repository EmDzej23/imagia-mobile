import 'package:flutter/material.dart';

import '../api/notifications_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Compact "Tips from the Imagia team" card for the top of the studio controls.
/// Tapping it opens the full text ([showProjectTipsSheet]).
class ProjectTipsCard extends StatelessWidget {
  const ProjectTipsCard({
    super.key,
    required this.tip,
    required this.onOpen,
    required this.onDismiss,
  });

  final ProjectTip tip;
  final VoidCallback onOpen;

  /// Hides these tips for good; new tips from the team show again.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lightbulb_outline, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Tips from the Imagia team',
                            style: AppTypography.label.copyWith(color: AppColors.accent)),
                        if (!tip.read) ...[
                          const SizedBox(width: AppSpacing.x2),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                                color: AppColors.accent, shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tip.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: 'Dismiss tips',
                  color: AppColors.textSecondary,
                  icon: const Icon(Icons.close),
                  onPressed: onDismiss,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full tips, in a bottom sheet. Line breaks are kept and the text can be
/// selected/copied, like on the web.
Future<void> showProjectTipsSheet(BuildContext context, ProjectTip tip) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4, 0, AppSpacing.x4, AppSpacing.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.lightbulb_outline, color: AppColors.accent),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(child: Text('Tips for your project', style: AppTypography.title)),
                ],
              ),
              const SizedBox(height: AppSpacing.x1),
              Text('From the Imagia team', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.x3),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(tip.body, style: AppTypography.body),
                ),
              ),
              const SizedBox(height: AppSpacing.x4),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Got it'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
