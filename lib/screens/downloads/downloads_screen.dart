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
import '../../widgets/app_card.dart';
import '../../widgets/shimmer.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  String? _busyId;

  /// 0..1 while the busy row's file is downloading (null = size not known yet).
  /// Full-resolution mosaics are 60–100 MB, so a bare spinner looked stuck.
  double? _progress;

  Future<File> _download(DownloadRecord d) async {
    final token = await ref.read(tokenStorageProvider).read();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${d.fileName}';
    // Fail fast on a dead connection (otherwise the spinner never ends); the
    // receive timeout is per chunk, so a slow but moving download is fine.
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 1),
    ));
    await dio.download(
      '${AppConfig.apiBaseUrl}${d.downloadPath}',
      path,
      options: Options(
        headers: token != null ? {'Authorization': 'Bearer $token'} : null,
      ),
      onReceiveProgress: (got, total) {
        final known = total > 0 ? total : (d.fileSizeBytes ?? 0);
        if (known <= 0 || !mounted) return;
        final p = (got / known).clamp(0.0, 1.0);
        // Repaint only on whole-percent steps.
        if (_progress == null || (p * 100).floor() != (_progress! * 100).floor()) {
          setState(() => _progress = p);
        }
      },
    );
    return File(path);
  }

  Future<void> _run(DownloadRecord d, Future<void> Function(File) action) async {
    setState(() {
      _busyId = d.id;
      _progress = null;
    });
    try {
      final file = await _download(d);
      await action(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _progress = null;
        });
      }
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
          loading: () => const DownloadsListSkeleton(),
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
                    return AppCard(
                      padding: const EdgeInsets.all(AppSpacing.x3),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppRadius.chip),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: ShimmerNetworkImage(
                                url:
                                    '${AppConfig.apiBaseUrl}/api/mosaic-image/${d.downloadToken}?maxSize=200',
                              ),
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
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        value: _progress,
                                        strokeWidth: 2,
                                        color: AppColors.accent),
                                  ),
                                  if (_progress != null) ...[
                                    const SizedBox(width: 8),
                                    Text('${(_progress! * 100).round()}%',
                                        style: AppTypography.caption),
                                  ],
                                ],
                              ),
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
