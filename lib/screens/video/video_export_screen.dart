
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../state/video_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../video/video_render.dart';
import '../../widgets/app_progress_bar.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';
import '../../widgets/segmented_selector.dart';

class VideoExportScreen extends ConsumerStatefulWidget {
  const VideoExportScreen({super.key});

  @override
  ConsumerState<VideoExportScreen> createState() => _VideoExportScreenState();
}

class _VideoExportScreenState extends ConsumerState<VideoExportScreen> {
  VideoStyle _style = VideoStyle.reelPoster;
  bool _hd = true;
  final _caption = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _saveToGallery(String path) async {
    setState(() => _saving = true);
    try {
      await Gal.putVideo(path);
      _snack('Saved to Photos');
    } catch (e) {
      _snack('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = ref.watch(videoControllerProvider);
    final controller = ref.read(videoControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Create video')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.x4),
          children: [
            Text('Make a 9:16 video to share. Free — no token needed.',
                style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x4),

            Text('Style', style: AppTypography.label),
            const SizedBox(height: AppSpacing.x2),
            SegmentedSelector<VideoStyle>(
              selected: _style,
              onSelected: video.isBusy
                  ? (_) {}
                  : (s) {
                      setState(() => _style = s);
                      // Drop any generated video — it no longer matches the
                      // selected style; the user can regenerate freely.
                      controller.reset();
                    },
              options: [
                for (final s in VideoStyle.values)
                  SegmentOption(s, s.label),
              ],
            ),
            const SizedBox(height: AppSpacing.x4),

            Text('Caption (optional)', style: AppTypography.label),
            const SizedBox(height: AppSpacing.x2),
            TextField(
              controller: _caption,
              enabled: !video.isBusy,
              style: AppTypography.body,
              decoration: const InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
              ),
            ),
            const SizedBox(height: AppSpacing.x4),

            Row(
              children: [
                Text('Quality', style: AppTypography.label),
                const Spacer(),
                SegmentedSelector<bool>(
                  selected: _hd,
                  onSelected: video.isBusy
                      ? (_) {}
                      : (v) {
                          setState(() => _hd = v);
                          controller.reset();
                        },
                  options: const [
                    SegmentOption(true, 'HD 1080'),
                    SegmentOption(false, 'Fast 720'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x6),

            _body(video, controller),
          ],
        ),
      ),
    );
  }

  Widget _body(VideoUiState video, VideoController controller) {
    switch (video.phase) {
      case VideoPhase.generating:
        return Column(
          children: [
            Text('Rendering… ${(video.progress * 100).round()}%',
                style: AppTypography.title),
            const SizedBox(height: AppSpacing.x4),
            AppProgressBar(percent: video.progress * 100),
            const SizedBox(height: AppSpacing.x2),
            Text('Encoding ${_hd ? '1080×1920' : '720×1280'}, 10s.',
                style: AppTypography.caption),
          ],
        );
      case VideoPhase.done:
        final path = video.path!;
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: _VideoPreviewPlayer(key: ValueKey(path), path: path),
              ),
            ),
            const SizedBox(height: AppSpacing.x4),
            Text('Your video is ready', style: AppTypography.title),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Save to Photos',
              icon: Icons.download,
              loading: _saving,
              onPressed: _saving ? null : () => _saveToGallery(path),
            ),
            const SizedBox(height: AppSpacing.x3),
            SecondaryButton(
              label: 'Share',
              icon: Icons.ios_share,
              onPressed: _saving
                  ? null
                  : () => SharePlus.instance
                      .share(ShareParams(files: [XFile(path)])),
            ),
            const SizedBox(height: AppSpacing.x3),
            TextButton(
              onPressed: () => controller.reset(),
              child: const Text('Make another'),
            ),
          ],
        );
      case VideoPhase.failed:
        return Column(
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 56),
            const SizedBox(height: AppSpacing.x3),
            Text(video.error ?? 'Video failed',
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Try again',
              onPressed: () => controller.generate(
                  style: _style, hd: _hd, caption: _caption.text.trim()),
            ),
          ],
        );
      case VideoPhase.idle:
        return PrimaryButton(
          label: 'Generate video',
          icon: Icons.movie_creation_outlined,
          onPressed: () => controller.generate(
              style: _style, hd: _hd, caption: _caption.text.trim()),
        );
    }
  }
}

/// Auto-playing, looping preview of the generated video.
class _VideoPreviewPlayer extends StatefulWidget {
  const _VideoPreviewPlayer({super.key, required this.path});
  final String path;

  @override
  State<_VideoPreviewPlayer> createState() => _VideoPreviewPlayerState();
}

class _VideoPreviewPlayerState extends State<_VideoPreviewPlayer> {
  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..setLooping(true)
      ..setVolume(1)
      ..initialize().then((_) {
        if (mounted) {
          _controller.play();
          setState(() {});
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const AspectRatio(
        aspectRatio: 9 / 16,
        child: ColoredBox(
          color: AppColors.surface,
          child: Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        if (_controller.value.isPlaying) {
          _controller.pause();
        } else {
          _controller.play();
        }
        setState(() {});
      },
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
