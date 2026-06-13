import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import '../mosaic/types.dart';
import 'audio_track.dart';
import 'video_render.dart';

const int _fps = 30;
const int _durationSeconds = 10;
const int _totalFrames = _fps * _durationSeconds;

/// Optional bundled music bed (WAV). Drop a royalty-free piano track here and
/// add it to pubspec assets; until then videos render silent.
const String _audioAsset = 'assets/audio/piano.wav';

class VideoResult {
  VideoResult(this.path);
  final String path;
}

/// Generates a 9:16 mosaic video on-device: renders each Flutter-Canvas frame
/// to RGBA and feeds it to the native encoder (AVAssetWriter / MediaCodec).
/// [hd] = 1080×1920, else 720×1280 ("Fast").
Future<VideoResult> generateMosaicVideo({
  required SlimMosaicPlan plan,
  required Map<String, ui.Image> tileImages,
  ui.Image? morphBase,
  ui.Image? overlay,
  required VideoStyle style,
  bool hd = true,
  String? caption,
  void Function(double progress)? onProgress,
}) async {
  final vw = hd ? 1080 : 720;
  final vh = hd ? 1920 : 1280;

  final anim = buildVideoAnim(
    plan: plan,
    style: style,
    videoW: vw.toDouble(),
    videoH: vh.toDouble(),
    caption: caption,
  );

  final dir = await getTemporaryDirectory();
  final outPath =
      '${dir.path}/imagia-mosaic-${DateTime.now().millisecondsSinceEpoch}.mp4';

  final audio = await loadAudioTrack(_audioAsset);

  await FlutterQuickVideoEncoder.setup(
    width: vw,
    height: vh,
    fps: _fps,
    videoBitrate: hd ? 9000000 : 4500000,
    profileLevel: ProfileLevel.high41,
    audioChannels: audio?.channels ?? 0,
    audioBitrate: audio != null ? 128000 : 0,
    sampleRate: audio?.sampleRate ?? 0,
    filepath: outPath,
  );

  try {
    for (var frame = 0; frame < _totalFrames; frame++) {
      final progress = frame / (_totalFrames - 1);
      final rgba = await _renderFrameRgba(
          anim, tileImages, morphBase, overlay, progress, vw, vh);
      await FlutterQuickVideoEncoder.appendVideoFrame(rgba);
      if (audio != null) {
        await FlutterQuickVideoEncoder.appendAudioFrame(
            audio.frameBytes(frame, _fps));
      }
      onProgress?.call((frame + 1) / _totalFrames);
    }
  } finally {
    await FlutterQuickVideoEncoder.finish();
  }

  return VideoResult(outPath);
}

Future<Uint8List> _renderFrameRgba(
  VideoAnim anim,
  Map<String, ui.Image> tileImages,
  ui.Image? morphBase,
  ui.Image? overlay,
  double progress,
  int vw,
  int vh,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
      recorder, ui.Rect.fromLTWH(0, 0, vw.toDouble(), vh.toDouble()));
  drawVideoFrame(canvas, anim, tileImages, morphBase, overlay, progress);
  final picture = recorder.endRecording();
  final image = await picture.toImage(vw, vh);
  picture.dispose();
  final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bd!.buffer.asUint8List();
}
