import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Options for [generateTextTiles].
class TextTileOptions {
  const TextTileOptions({this.orientation = 'square', this.color = 0xFF000000});

  /// "square" | "portrait" | "landscape" | "original" (per-phrase aspect).
  final String orientation;

  /// ARGB text colour (darker colours keep more of the light→dark range).
  final int color;
}

/// A rasterised text tile ready to be analysed + uploaded like a photo tile.
class GeneratedTextTile {
  GeneratedTextTile({required this.id, required this.bytes, required this.filename});
  final String id;
  final Uint8List bytes;
  final String filename;
}

/// Long side of a generated tile, in px.
const double _long = 360;

/// Each phrase is drawn ONCE per darkness level — from light+thin to
/// big+bold+tight — so a single phrase spans the grayscale spectrum and the
/// matcher has a full brightness palette.
const List<({double scale, FontWeight weight, double spacing, double stroke})>
    _levels = [
  (scale: 0.32, weight: FontWeight.w400, spacing: 0.0, stroke: 0.0),
  (scale: 0.46, weight: FontWeight.w500, spacing: -0.01, stroke: 0.0),
  (scale: 0.62, weight: FontWeight.w600, spacing: -0.02, stroke: 0.0),
  (scale: 0.80, weight: FontWeight.w700, spacing: -0.03, stroke: 0.035),
  (scale: 0.95, weight: FontWeight.w800, spacing: -0.04, stroke: 0.06),
];

/// Parse a raw multi-line phrase blob into a clean, de-duplicated list.
List<String> parseTextPhrases(String raw, {bool uppercase = false}) {
  final seen = <String>{};
  final out = <String>[];
  for (var line in raw.split('\n')) {
    var s = line.trim();
    if (s.isEmpty) continue;
    if (uppercase) s = s.toUpperCase();
    final key = s.toLowerCase();
    if (seen.add(key)) out.add(s);
  }
  return out;
}

({double w, double h}) _dims(String orientation, String phrase) {
  const short = _long * 2 / 3; // 2:3 / 3:2
  switch (orientation) {
    case 'portrait':
      return (w: short, h: _long);
    case 'landscape':
      return (w: _long, h: short);
    case 'square':
      return (w: _long, h: _long);
    default: // "original" — pick a per-phrase aspect
      final words = phrase.trim().split(RegExp(r'\s+')).length;
      if (words >= 4) return (w: short, h: _long); // portrait for long phrases
      if (words <= 1 && phrase.length <= 6) return (w: _long, h: short); // landscape
      return (w: _long, h: _long);
  }
}

Future<Uint8List?> _renderTile(
  String phrase,
  ({double scale, FontWeight weight, double spacing, double stroke}) level,
  ({double w, double h}) dim,
  int color,
) async {
  final w = dim.w, h = dim.h;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFFFFFFF));

  final words =
      phrase.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  TextStyle styleAt(double fs) => TextStyle(
        color: Color(color),
        fontSize: fs,
        fontWeight: level.weight,
        letterSpacing: fs * level.spacing,
        height: 1.05,
      );

  final maxW = w * 0.9, maxH = h * 0.9;
  var fontSize = h * level.scale;
  late TextPainter tp;
  while (true) {
    // No single word may exceed the line width — otherwise the layout would
    // break a word mid-way. Shrink until the widest word fits on one line, so
    // wrapping can only ever happen between words (at spaces).
    var widest = 0.0;
    for (final word in words) {
      final wp = TextPainter(
        text: TextSpan(text: word, style: styleAt(fontSize)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (wp.width > widest) widest = wp.width;
      wp.dispose();
    }
    tp = TextPainter(
      text: TextSpan(text: phrase, style: styleAt(fontSize)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxW);
    if ((widest <= maxW && tp.height <= maxH && tp.width <= maxW) ||
        fontSize <= 6) {
      break;
    }
    fontSize *= 0.9;
  }

  final dx = (w - tp.width) / 2, dy = (h - tp.height) / 2;
  // Thicken the darker levels with a stroke underlay (more ink → darker gray).
  if (level.stroke > 0) {
    final strokeTp = TextPainter(
      text: TextSpan(
        text: phrase,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: level.weight,
          letterSpacing: fontSize * level.spacing,
          height: 1.05,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = fontSize * level.stroke
            ..color = Color(color),
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxW);
    strokeTp.paint(canvas, Offset(dx, dy));
  }
  tp.paint(canvas, Offset(dx, dy));

  final pic = recorder.endRecording();
  final img = await pic.toImage(w.round(), h.round());
  pic.dispose();
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data?.buffer.asUint8List();
}

/// Rasterise every phrase at all darkness levels into upload-ready tiles.
/// [gen] is a per-generation key so tile ids stay unique across regenerations.
Future<List<GeneratedTextTile>> generateTextTiles(
  List<String> phrases, {
  required TextTileOptions options,
  required String gen,
  void Function(int done, int total)? onProgress,
}) async {
  final out = <GeneratedTextTile>[];
  final total = phrases.length * _levels.length;
  var done = 0;
  for (var p = 0; p < phrases.length; p++) {
    final dim = _dims(options.orientation, phrases[p]);
    for (var l = 0; l < _levels.length; l++) {
      final bytes = await _renderTile(phrases[p], _levels[l], dim, options.color);
      if (bytes != null) {
        final id = 'text-$gen-$p-$l';
        out.add(GeneratedTextTile(id: id, bytes: bytes, filename: '$id.png'));
      }
      done++;
      onProgress?.call(done, total);
      await Future<void>.delayed(Duration.zero); // let the UI paint progress
    }
  }
  return out;
}
