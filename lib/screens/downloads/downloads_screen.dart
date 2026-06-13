import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/downloads_api.dart';
import '../../core/config.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  String? _busyId;

  Future<File> _download(DownloadRecord d) async {
    final token = await ref.read(tokenStorageProvider).read();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${d.fileName}';
    await Dio().download(
      '${AppConfig.apiBaseUrl}${d.downloadPath}',
      path,
      options: Options(
        headers: token != null ? {'Authorization': 'Bearer $token'} : null,
      ),
    );
    return File(path);
  }

  Future<void> _run(DownloadRecord d, Future<void> Function(File) action) async {
    setState(() => _busyId = d.id);
    try {
      final file = await _download(d);
      await action(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadsListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async => ref.invalidate(downloadsListProvider),
        child: downloads.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.accent)),
          error: (e, _) => Center(
              child: Text('Could not load downloads.\n$e',
                  textAlign: TextAlign.center, style: AppTypography.caption)),
          data: (list) => list.isEmpty
              ? Center(
                  child: Text('No mosaics yet',
                      style: AppTypography.body
                          .copyWith(color: AppColors.textSecondary)))
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.screen),
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.x2),
                  itemBuilder: (context, i) {
                    final d = list[i];
                    final busy = _busyId == d.id;
                    return Container(
                      padding: const EdgeInsets.all(AppSpacing.x3),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppRadius.chip),
                            child: Image.network(
                              '${AppConfig.apiBaseUrl}/api/mosaic-image/${d.downloadToken}?maxSize=200',
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox(
                                width: 48,
                                height: 48,
                                child: Icon(Icons.image,
                                    color: AppColors.textMuted),
                              ),
                              loadingBuilder: (_, child, progress) =>
                                  progress == null
                                      ? child
                                      : const SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: ColoredBox(
                                              color: AppColors.surfaceRaised)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.x3),
                          Expanded(
                            child: Text(d.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.label),
                          ),
                          if (busy)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.accent),
                            )
                          else ...[
                            IconButton(
                              tooltip: 'Preview',
                              icon: const Icon(Icons.zoom_in,
                                  color: AppColors.textSecondary),
                              onPressed: () =>
                                  context.push('/preview', extra: d),
                            ),
                            IconButton(
                              tooltip: 'Save to Photos',
                              icon: const Icon(Icons.download,
                                  color: AppColors.textSecondary),
                              onPressed: () => _run(d, (f) async {
                                await Gal.putImage(f.path);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Saved to Photos')));
                                }
                              }),
                            ),
                            IconButton(
                              tooltip: 'Share',
                              icon: const Icon(Icons.ios_share,
                                  color: AppColors.textSecondary),
                              onPressed: () => _run(
                                  d,
                                  (f) => SharePlus.instance.share(
                                      ShareParams(files: [XFile(f.path)]))),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
