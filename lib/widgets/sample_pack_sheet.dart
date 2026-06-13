import 'package:flutter/material.dart';

import '../data/sample_packs.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Bottom sheet to choose a free sample tile pack. Resolves to the chosen
/// folder id, or null if dismissed. Mirrors the web "Choose Sample Pack" modal,
/// adapted to a mobile draggable sheet.
Future<String?> showSamplePackPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
    ),
    builder: (context) => const _SamplePackSheet(),
  );
}

class _SamplePackSheet extends StatelessWidget {
  const _SamplePackSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.screen, AppSpacing.x4,
            AppSpacing.screen, AppSpacing.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.x4),
            Text('Free sample packs', style: AppTypography.title),
            const SizedBox(height: AppSpacing.x1),
            Text('Build a mosaic instantly — free to use for any purpose.',
                style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x4),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: AppSpacing.x2,
                  crossAxisSpacing: AppSpacing.x2,
                  childAspectRatio: 2.4,
                ),
                itemCount: kSamplePacks.length,
                itemBuilder: (context, i) {
                  final pack = kSamplePacks[i];
                  return _PackTile(
                    pack: pack,
                    onTap: () => Navigator.of(context).pop(pack.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  const _PackTile({required this.pack, required this.onTap});
  final SamplePack pack;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Text(pack.emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pack.label,
                        style: AppTypography.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(pack.description,
                        style: AppTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
