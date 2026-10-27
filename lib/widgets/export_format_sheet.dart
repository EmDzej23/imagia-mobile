import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Asks PDF / SVG / JPG before a vector-capable export (word art, stone mosaic).
/// Mirrors the web's "Choose export format" dialog. Returns null when dismissed.
Future<String?> showExportFormatSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.x4, 0, AppSpacing.x4, AppSpacing.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose export format', style: AppTypography.title),
            const SizedBox(height: AppSpacing.x1),
            Text(
              'This artwork is drawn as vector shapes, so it can export as a true '
              'vector file — sharp at any print size.',
              style: AppTypography.caption,
            ),
            const SizedBox(height: AppSpacing.x4),
            _Option(
              title: 'Print PDF',
              badge: 'Best for print',
              description:
                  'Vector, print-ready file — what print shops want. Razor-sharp at any size.',
              highlight: true,
              onTap: () => Navigator.of(ctx).pop('pdf'),
            ),
            const SizedBox(height: AppSpacing.x2),
            _Option(
              title: 'Vector SVG',
              badge: 'Web / editing',
              description:
                  'Vector too — for the web or editing in design tools (Figma, Illustrator).',
              onTap: () => Navigator.of(ctx).pop('svg'),
            ),
            const SizedBox(height: AppSpacing.x2),
            _Option(
              title: 'Image (JPG)',
              description: 'A high-resolution 10K image. Best for screens and sharing.',
              onTap: () => Navigator.of(ctx).pop('jpg'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Option extends StatelessWidget {
  const _Option({
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
    this.highlight = false,
  });

  final String title;
  final String description;
  final String? badge;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: highlight
          ? AppColors.accent.withValues(alpha: 0.08)
          : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(
                color: highlight
                    ? AppColors.accent.withValues(alpha: 0.4)
                    : AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: AppTypography.label.copyWith(
                          color: highlight ? AppColors.accent : AppColors.textPrimary)),
                  if (badge != null) ...[
                    const SizedBox(width: AppSpacing.x2),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                      child: Text(badge!, style: AppTypography.caption),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(description, style: AppTypography.caption),
            ],
          ),
        ),
      ),
    );
  }
}
