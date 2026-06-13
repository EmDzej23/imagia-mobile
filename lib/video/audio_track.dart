import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Decoded PCM audio used as the video's music bed. The encoder consumes raw
/// 16-bit PCM, so we bundle the track as a WAV and parse it here. Optional —
/// if the asset isn't bundled, video is generated silent.
class AudioTrack {
  AudioTrack({
    required this.channels,
    required this.sampleRate,
    required this.pcm,
  });

  final int channels;
  final int sampleRate;
  final Uint8List pcm; // 16-bit little-endian interleaved

  /// PCM bytes for one video frame at [fps], looping if the track is short.
  Uint8List frameBytes(int frame, int fps) {
    final bytesPerFrame = (sampleRate ~/ fps) * channels * 2;
    final out = Uint8List(bytesPerFrame);
    if (pcm.isEmpty) return out;
    final start = (frame * bytesPerFrame) % pcm.length;
    for (var i = 0; i < bytesPerFrame; i++) {
      out[i] = pcm[(start + i) % pcm.length];
    }
    return out;
  }
}

/// Loads + parses a 16-bit PCM WAV asset. Returns null if missing/unparseable
/// (→ silent video).
Future<AudioTrack?> loadAudioTrack(String assetPath) async {
  try {
    final data = await rootBundle.load(assetPath);
    return _parseWav(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

AudioTrack? _parseWav(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final bd = ByteData.sublistView(bytes);
  // "RIFF" .... "WAVE"
  if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') return null;

  var offset = 12;
  int channels = 0, sampleRate = 0, bitsPerSample = 0;
  Uint8List? pcm;

  while (offset + 8 <= bytes.length) {
    final id = _tag(bytes, offset);
    final size = bd.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      channels = bd.getUint16(body + 2, Endian.little);
      sampleRate = bd.getUint32(body + 4, Endian.little);
      bitsPerSample = bd.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      final end = (body + size).clamp(0, bytes.length);
      pcm = Uint8List.sublistView(bytes, body, end);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (pcm == null || channels == 0 || sampleRate == 0 || bitsPerSample != 16) {
    return null;
  }
  return AudioTrack(channels: channels, sampleRate: sampleRate, pcm: pcm);
}

String _tag(Uint8List b, int o) =>
    String.fromCharCodes(b.sublist(o, o + 4));
