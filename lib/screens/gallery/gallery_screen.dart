import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/projects_api.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/render_controller.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final projects = ref.watch(projectsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Imagia'),
        actions: [
          if (user != null)
            GestureDetector(
              onTap: () => context.push('/account'),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.only(right: AppSpacing.x2),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3, vertical: AppSpacing.x1),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text('${user.tokenBalance} ◆',
                      style: AppTypography.number(AppTypography.caption)
                          .copyWith(color: AppColors.accent)),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Downloads',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => context.push('/downloads'),
          ),
          IconButton(
            tooltip: 'Account',
            icon: const Icon(Icons.person_outline),
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textPrimary,
        onPressed: () {
          ref.read(studioControllerProvider.notifier).reset();
          ref.read(renderControllerProvider.notifier).reset();
          context.push('/create/source');
        },
        icon: const Icon(Icons.add),
        label: const Text('New Mosaic'),
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async => ref.invalidate(projectsListProvider),
        child: projects.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.accent)),
          error: (e, _) => _Message(
              icon: Icons.cloud_off,
              text: 'Could not load your mosaics.\n$e'),
          data: (list) => list.isEmpty
              ? _EmptyGallery()
              : GridView.builder(
                  padding: const EdgeInsets.all(AppSpacing.screen),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: AppSpacing.x3,
                    crossAxisSpacing: AppSpacing.x3,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) =>
                      _ProjectCard(project: list[i]),
                ),
        ),
      ),
    );
  }
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project});
  final ProjectSummary project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        final studio = ref.read(studioControllerProvider);
        ref.read(renderControllerProvider.notifier).reset();
        // If this project is already open in the studio, jump straight back in
        // without re-restoring (re-fetching + re-analyzing all its tiles).
        final alreadyOpen =
            studio.currentProjectId == project.id && studio.base != null;
        if (!alreadyOpen) {
          ref.read(studioControllerProvider.notifier).loadProject(project.id);
        }
        context.push('/create/studio');
      },
      onLongPress: () => _confirmDelete(context, ref),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _CardImage(project: project)),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.label),
                  const SizedBox(height: AppSpacing.x1),
                  Text('${project.tileCount} tiles',
                      style: AppTypography.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('Delete project?', style: AppTypography.title),
        content: Text('"${project.name}" will be removed.',
            style: AppTypography.body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete',
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(projectsApiProvider).delete(project.id);
      ref.invalidate(projectsListProvider);
    }
  }
}

/// Project card preview: the base photo (fetched via the authenticated
/// thumbnail batch) when available, else a placeholder icon.
class _CardImage extends ConsumerWidget {
  const _CardImage({required this.project});
  final ProjectSummary project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget placeholder() => Center(
          child: Icon(
            project.hasBase ? Icons.grid_on : Icons.image_outlined,
            size: 40,
            color: AppColors.textMuted,
          ),
        );

    final url = project.baseImageUrl;
    Widget child;
    if (url == null) {
      child = placeholder();
    } else {
      final thumbs = ref.watch(projectThumbnailsProvider);
      final bytes = thumbs.asData?.value[url];
      if (bytes != null) {
        child = Image.memory(bytes,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            gaplessPlayback: true);
      } else if (thumbs.isLoading) {
        child = const ColoredBox(color: AppColors.surfaceRaised);
      } else {
        child = placeholder();
      }
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.card)),
      child: SizedBox.expand(child: child),
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.auto_awesome_mosaic,
            size: 72, color: AppColors.textMuted),
        const SizedBox(height: AppSpacing.x4),
        Center(
            child: Text('Make your first mosaic',
                style: AppTypography.display)),
        const SizedBox(height: AppSpacing.x2),
        Center(
          child: Text('Tap “New Mosaic” to begin',
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 140),
        Icon(icon, size: 56, color: AppColors.textMuted),
        const SizedBox(height: AppSpacing.x3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
          child: Text(text,
              textAlign: TextAlign.center,
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}
