import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config.dart';
import '../../state/render_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_progress_bar.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _saving = false;
  ProviderContainer? _container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(onRenderScreenProvider.notifier).value = true;
      ref.read(renderControllerProvider.notifier).start();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    // Defer past the teardown frame to avoid mutating a provider mid-dispose;
    // the overlay re-shows once we've left this screen.
    final container = _container;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      container?.read(onRenderScreenProvider.notifier).value = false;
    });
    super.dispose();
  }

  String _resolveUrl(String url) =>
      url.startsWith('http') ? url : '${AppConfig.apiBaseUrl}$url';

  Future<File> _download(String url, String fileName) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    await Dio().download(_resolveUrl(url), path);
    return File(path);
  }

  Future<void> _save(String url, String fileName) async {
    setState(() => _saving = true);
    try {
      final file = await _download(url, fileName);
      await Gal.putImage(file.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to Photos')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share(String url, String fileName) async {
    setState(() => _saving = true);
    try {
      final file = await _download(url, fileName);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final render = ref.watch(renderControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Center(child: _body(render)),
        ),
      ),
    );
  }

  Widget _body(RenderUiState render) {
    switch (render.phase) {
      case RenderPhase.completed:
        final result = render.result!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle,
                color: AppColors.success, size: 64),
            const SizedBox(height: AppSpacing.x4),
            Text('Your mosaic is ready', style: AppTypography.title),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Save to Photos',
              icon: Icons.download,
              loading: _saving,
              onPressed: _saving
                  ? null
                  : () => _save(result.downloadUrl, result.fileName),
            ),
            const SizedBox(height: AppSpacing.x3),
            SecondaryButton(
              label: 'Share',
              icon: Icons.ios_share,
              onPressed: _saving
                  ? null
                  : () => _share(result.downloadUrl, result.fileName),
            ),
            const SizedBox(height: AppSpacing.x3),
            TextButton(
              onPressed: () => context.go('/'),
              child: Text('Back to gallery',
                  style: AppTypography.label
                      .copyWith(color: AppColors.textSecondary)),
            ),
          ],
        );
      case RenderPhase.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: AppColors.error, size: 64),
            const SizedBox(height: AppSpacing.x4),
            Text(render.error ?? 'Render failed',
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Try again',
              onPressed: () =>
                  ref.read(renderControllerProvider.notifier).start(),
            ),
          ],
        );
      default:
        // Sync render: the server holds the request open for the whole render,
        // so there's no progress to poll — show an indeterminate indicator.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(render.message.isEmpty ? 'Rendering…' : render.message,
                textAlign: TextAlign.center, style: AppTypography.title),
            const SizedBox(height: AppSpacing.x2),
            Text('High-resolution mosaics can take a minute.',
                textAlign: TextAlign.center, style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x6),
            const SizedBox(
              width: double.infinity,
              child: AppIndeterminateBar(),
            ),
          ],
        );
    }
  }
}
