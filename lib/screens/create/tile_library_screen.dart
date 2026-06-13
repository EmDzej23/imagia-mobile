import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_progress_bar.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/sample_pack_sheet.dart';
import '../../widgets/secondary_button.dart';

class TileLibraryScreen extends ConsumerWidget {
  const TileLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Surface upload/ingest failures so they're not silently swallowed.
    ref.listen(studioControllerProvider.select((s) => s.error), (_, err) {
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 8),
        ));
      }
    });

    final studio = ref.watch(studioControllerProvider);
    final controller = ref.read(studioControllerProvider.notifier);
    final tiles = studio.tiles;

    // Count chip color: muted when low, accent when ample.
    final countColor = tiles.length >= 30
        ? AppColors.accent
        : tiles.isEmpty
            ? AppColors.textMuted
            : AppColors.textSecondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tile photos'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.x4),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3, vertical: AppSpacing.x1),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text('${tiles.length}',
                    style: AppTypography.number(AppTypography.label)
                        .copyWith(color: countColor)),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (studio.isUploadingTiles)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screen,
                    AppSpacing.x3, AppSpacing.screen, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        studio.uploadDone == 0
                            ? 'Preparing photos…'
                            : 'Adding ${studio.uploadDone}/${studio.uploadTotal}…',
                        style: AppTypography.caption),
                    const SizedBox(height: AppSpacing.x2),
                    // Indeterminate "loader" until the first tile lands, then
                    // switch to a real progress bar.
                    studio.uploadDone == 0
                        ? const AppIndeterminateBar()
                        : AppProgressBar(
                            percent:
                                studio.uploadDone / studio.uploadTotal * 100),
                  ],
                ),
              ),
            Expanded(
              child: tiles.isEmpty && !studio.isUploadingTiles
                  ? _Empty()
                  : GridView.builder(
                      padding: const EdgeInsets.all(AppSpacing.screen),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: AppSpacing.x2,
                        crossAxisSpacing: AppSpacing.x2,
                      ),
                      itemCount: tiles.length,
                      itemBuilder: (context, i) {
                        final tile = tiles[i];
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.chip),
                              child: RawImage(
                                  image: tile.thumbnail, fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: () => controller.removeTile(tile.id),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: const Icon(Icons.close,
                                      size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screen),
              child: Column(
                children: [
                  SecondaryButton(
                    label: 'Add photos',
                    icon: Icons.add_photo_alternate_outlined,
                    onPressed: studio.isUploadingTiles
                        ? null
                        : controller.pickTileImages,
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  SecondaryButton(
                    label: 'Free sample photos',
                    icon: Icons.auto_awesome_outlined,
                    onPressed: studio.isUploadingTiles
                        ? null
                        : () async {
                            final folder = await showSamplePackPicker(context);
                            if (folder != null) {
                              controller.loadSampleTiles(folder);
                            }
                          },
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  PrimaryButton(
                    label: 'Continue',
                    onPressed: tiles.isEmpty
                        ? null
                        : () => context.push('/create/studio'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.grid_view, size: 64, color: AppColors.textMuted),
          const SizedBox(height: AppSpacing.x3),
          Text('Add the photos your mosaic is built from',
              textAlign: TextAlign.center,
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.x1),
          Text('More and more varied photos give a better result',
              textAlign: TextAlign.center, style: AppTypography.caption),
        ],
      ),
    );
  }
}
