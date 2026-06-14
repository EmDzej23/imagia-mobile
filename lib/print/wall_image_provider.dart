import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Decoded wall photo used as the print-mockup background. Cached for the
/// session.
final wallImageProvider = FutureProvider<ui.Image>((ref) async {
  final data = await rootBundle.load('assets/wall.jpg');
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  return frame.image;
});
