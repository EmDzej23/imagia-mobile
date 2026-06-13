import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/downloads_api.dart';
import '../../core/config.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Full-screen, zoomable view of a rendered high-res mosaic, with save/share.
///
/// The displayed image comes from `/api/mosaic-image/<token>?maxSize=…` (a
/// server-resized JPEG — token-gated, no auth) so panning/zooming stays smooth;
/// Save/Share pull the full-resolution file from `/api/download/<token>`.
class MosaicPreviewScreen extends ConsumerStatefulWidget {
  const MosaicPreviewScreen({super.key, this.record});

  /// The mosaic to show. When null, the most recent download is used.
  final DownloadRecord? record;

  @override
  ConsumerState<MosaicPreviewScreen> createState() =>
      _MosaicPreviewScreenState();
}

class _MosaicPreviewScreenState extends ConsumerState<MosaicPreviewScreen> {
  bool _saving = false;

  /// Display resolution for the zoomable view — high enough to make individual
  /// tiles visible when zoomed, low enough to stay within memory on a phone.
  static const _displayMaxSize = 3000;

  String _imageUrl(String token) =>
      '${AppConfig.apiBaseUrl}/api/mosaic-image/$token?maxSize=$_displayMaxSize';

  Future<File> _downloadFull(DownloadRecord rec) async {
    final token = await ref.read(tokenStorageProvider).read();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${rec.fileName}';
    await Dio().download(
      '${AppConfig.apiBaseUrl}${rec.downloadPath}',
      path,
      options: Options(
          headers: token != null ? {'Authorization': 'Bearer $token'} : null),
    );
    return File(path);
  }

  Future<void> _run(
      DownloadRecord rec, Future<void> Function(File) action) async {
    setState(() => _saving = true);
    try {
      final file = await _downloadFull(rec);
      await action(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resolve the mosaic: explicit record, else the latest download.
    DownloadRecord? rec = widget.record;
    if (rec == null) {
      final downloads = ref.watch(downloadsListProvider);
      final list = downloads.value;
      if (list == null) {
        return _scaffold(const Center(
            child: CircularProgressIndicator(color: AppColors.accent)));
      }
      if (list.isEmpty) {
        return _scaffold(Center(
          child: Text('No mosaics yet',
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary)),
        ));
      }
      rec = list.first;
    }

    final record = rec;
    return _scaffold(
      InteractiveViewer(
        minScale: 0.8,
        maxScale: 10,
        child: Center(
          child: Image.network(
            _imageUrl(record.downloadToken),
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                  child: CircularProgressIndicator(color: AppColors.accent));
            },
            errorBuilder: (context, error, stack) => Center(
              child: Text('Could not load image',
                  style: AppTypography.caption),
            ),
          ),
        ),
      ),
      actions: _saving
          ? const [
              Padding(
                padding: EdgeInsets.only(right: AppSpacing.x4),
                child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent)),
                ),
              )
            ]
          : [
              IconButton(
                tooltip: 'Save to Photos',
                icon: const Icon(Icons.download),
                onPressed: () => _run(record, (f) async {
                  await Gal.putImage(f.path);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Saved to Photos')));
                  }
                }),
              ),
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.ios_share),
                onPressed: () => _run(
                    record,
                    (f) => SharePlus.instance
                        .share(ShareParams(files: [XFile(f.path)]))),
              ),
            ],
    );
  }

  Widget _scaffold(Widget body, {List<Widget>? actions}) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Mosaic preview'),
        actions: actions,
      ),
      body: SafeArea(child: body),
    );
  }
}
