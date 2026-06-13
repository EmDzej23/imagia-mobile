import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../video/video_generator.dart';
import '../video/video_render.dart';
import 'studio_controller.dart';

enum VideoPhase { idle, generating, done, failed }

class VideoUiState {
  const VideoUiState({
    this.phase = VideoPhase.idle,
    this.progress = 0,
    this.path,
    this.error,
  });

  final VideoPhase phase;
  final double progress;
  final String? path;
  final String? error;

  bool get isBusy => phase == VideoPhase.generating;

  VideoUiState copyWith(
          {VideoPhase? phase, double? progress, String? path, String? error}) =>
      VideoUiState(
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        path: path ?? this.path,
        error: error,
      );
}

final videoControllerProvider =
    NotifierProvider<VideoController, VideoUiState>(VideoController.new);

class VideoController extends Notifier<VideoUiState> {
  @override
  VideoUiState build() => const VideoUiState();

  /// Renders + encodes the 9:16 video from the current studio state (free,
  /// on-device — no token).
  Future<void> generate({
    required VideoStyle style,
    required bool hd,
    String? caption,
  }) async {
    final studio = ref.read(studioControllerProvider);
    final plan = studio.plan;
    final base = studio.base;
    if (plan == null) return;

    state = const VideoUiState(phase: VideoPhase.generating, progress: 0);
    try {
      final res = await generateMosaicVideo(
        plan: plan,
        tileImages: studio.tileImages,
        morphBase: base?.thumbnail,
        overlay: base?.overlay,
        style: style,
        hd: hd,
        caption: caption,
        onProgress: (p) =>
            state = state.copyWith(phase: VideoPhase.generating, progress: p),
      );
      state = state.copyWith(phase: VideoPhase.done, path: res.path);
    } catch (e) {
      state = state.copyWith(phase: VideoPhase.failed, error: e.toString());
    }
  }

  void reset() => state = const VideoUiState();
}
