import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
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

  // Built once and reused for every frame.
  final wall = await _buildWall(vw, vh);
  final logo = await _loadAssetImage('assets/logo.png');

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
          anim, tileImages, morphBase, overlay, wall, logo, progress, vw, vh);
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
  ui.Image wall,
  ui.Image? logo,
  double progress,
  int vw,
  int vh,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
      recorder, ui.Rect.fromLTWH(0, 0, vw.toDouble(), vh.toDouble()));
  drawVideoFrame(
      canvas, anim, tileImages, morphBase, overlay, wall, logo, progress);
  final picture = recorder.endRecording();
  final image = await picture.toImage(vw, vh);
  picture.dispose();
  final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bd!.buffer.asUint8List();
}

/// Loads a bundled asset as a decoded [ui.Image] (e.g. the logo). Null on error.
Future<ui.Image?> _loadAssetImage(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

double Function() _wallRng(int seed) {
  var s = seed;
  return () {
    s = (s * 16807) % 2147483647;
    return (s - 1) / 2147483646;
  };
}

/// Procedurally builds a realistic interior wall (once, reused every frame):
/// warm dark concrete with a soft spotlight, plaster mottling, fine grain and a
/// vignette. Makes the colourful mosaic pop like a framed print on a wall.
Future<ui.Image> _buildWall(int vw, int vh) async {
  final w = vw.toDouble(), h = vh.toDouble();
  final full = ui.Rect.fromLTWH(0, 0, w, h);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, full);

  // Base vertical gradient.
  canvas.drawRect(
    full,
    ui.Paint()
      ..shader = ui.Gradient.linear(const ui.Offset(0, 0), ui.Offset(0, h),
          const [ui.Color(0xFF2B2832), ui.Color(0xFF1A1820)]),
  );

  // Soft spotlight behind the poster (upper-centre).
  canvas.drawRect(
    full,
    ui.Paint()
      ..shader = ui.Gradient.radial(
          ui.Offset(w / 2, h * 0.44), math.max(w, h) * 0.62,
          const [ui.Color(0x22FFFFFF), ui.Color(0x00FFFFFF)]),
  );

  // Plaster mottling: large soft blobs, alternating lighter / darker.
  final rng = _wallRng(7);
  for (var i = 0; i < 42; i++) {
    final r = w * (0.06 + rng() * 0.14);
    final light = rng() > 0.5;
    canvas.drawCircle(
      ui.Offset(rng() * w, rng() * h),
      r,
      ui.Paint()
        ..color = light ? const ui.Color(0x0EFFFFFF) : const ui.Color(0x12000000)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.8),
    );
  }

  // Fine grain.
  for (var i = 0; i < 460; i++) {
    final light = rng() > 0.5;
    canvas.drawCircle(
      ui.Offset(rng() * w, rng() * h),
      1.0 + rng() * 1.3,
      ui.Paint()
        ..color = light ? const ui.Color(0x0AFFFFFF) : const ui.Color(0x0E000000),
    );
  }

  // Vignette.
  canvas.drawRect(
    full,
    ui.Paint()
      ..shader = ui.Gradient.radial(
          ui.Offset(w / 2, h * 0.5), math.max(w, h) * 0.72,
          const [ui.Color(0x00000000), ui.Color(0x66000000)], const [0.55, 1.0]),
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(vw, vh);
  picture.dispose();
  return image;
}
