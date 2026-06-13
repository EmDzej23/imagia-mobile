import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';

class SourcePickerScreen extends ConsumerWidget {
  const SourcePickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studio = ref.watch(studioControllerProvider);
    final controller = ref.read(studioControllerProvider.notifier);
    final base = studio.base;

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a photo')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screen),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: base == null
                      ? _EmptyHint(busy: studio.isUploadingBase)
                      : ClipRRect(
                          borderRadius:
                              BorderRadius.circular(AppRadius.card),
                          child: RawImage(
                            image: base.thumbnail,
                            fit: BoxFit.contain,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.x3),
              Text('Portraits and clear subjects work best.',
                  style: AppTypography.caption),
              const SizedBox(height: AppSpacing.x4),
              SecondaryButton(
                label: base == null ? 'Choose from library' : 'Choose another',
                icon: Icons.photo_library_outlined,
                onPressed: studio.isUploadingBase
                    ? null
                    : controller.pickBaseImage,
              ),
              const SizedBox(height: AppSpacing.x3),
              PrimaryButton(
                label: 'Continue',
                onPressed: base == null
                    ? null
                    : () => context.push('/create/tiles'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.busy});
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const CircularProgressIndicator(color: AppColors.accent);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.image_outlined,
            size: 64, color: AppColors.textMuted),
        const SizedBox(height: AppSpacing.x3),
        Text('No photo selected',
            style: AppTypography.body
                .copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}
