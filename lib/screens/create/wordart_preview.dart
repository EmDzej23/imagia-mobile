import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../wordart/wordart_renderer.dart';
import '../../state/studio_controller.dart';
import '../../wordart/parse_texts.dart';
import '../../theme/app_colors.dart';
import 'loupe_preview.dart';

/// Long side (px) the word-art preview is rasterised at. The packing cost is
/// ~flat in resolution (min word size scales with the long side), so this is a
/// legibility/quality choice — kept high so the tap-to-zoom loupe stays crisp.
const double _previewLong = 1400;

/// Live word-art preview. Samples the base once, then — debounced on any
/// look-setting change — packs the words and RASTERISES to a single [ui.Image].
/// The widget then just displays that static bitmap (like [AncientPreview]).
class WordArtPreview extends StatefulWidget {
  const WordArtPreview({super.key, required this.base, required this.params});

  final BaseImage base;
  final WordArtParams params;

  @override
  State<WordArtPreview> createState() => _WordArtPreviewState();
}

class _WordArtPreviewState extends State<WordArtPreview> {
  Uint8List? _rgba;
  int _sw = 0, _sh = 0, _w = 0, _h = 0;
  ui.Image? _image;
  Timer? _debounce;
  int _token = 0;
  bool _building = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WordArtPreview old) {
    super.didUpdateWidget(old);
    if (old.base != widget.base) {
      _rgba = null;
      _load();
    } else if (old.params != widget.params) {
      _scheduleBuild();
    }
  }

  Future<void> _load() async {
    final img = widget.base.thumbnail;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted || data == null) return;
    _rgba = data.buffer.asUint8List();
    _sw = img.width;
    _sh = img.height;
    final scale = _previewLong / math.max(_sw, _sh);
    _w = (_sw * scale).round();
    _h = (_sh * scale).round();
    _build();
  }

  void _scheduleBuild() {
    _debounce?.cancel();
    if (!_building) setState(() => _building = true);
    _debounce = Timer(const Duration(milliseconds: 140), _build);
  }

  Future<void> _build() async {
    final rgba = _rgba;
    if (rgba == null || _w < 2 || _h < 2) return;
    if (!_building) setState(() => _building = true);
    final token = ++_token;
    final geo = buildWordArtGeometry(
        rgba, _sw, _sh, _w.toDouble(), _h.toDouble(), widget.params);
    final img = await renderWordArtImage(geo, _w, _h);
    if (!mounted || token != _token) {
      img.dispose();
      return;
    }
    _image?.dispose();
    setState(() {
      _image = img;
      _building = false;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return RepaintBoundary(
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (img != null) LoupePreviewImage(image: img),
            if (img == null || _building)
              Container(
                color: img == null ? null : Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.accent),
                      SizedBox(height: 12),
                      Text('Arranging words…',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Build [WordArtParams] from the studio state (phrases come from the shared
/// [StudioState.textInput] / [StudioState.textUppercase], parsed the same way
/// the old text mode did).
WordArtParams wordartParamsFromState(StudioState studio) {
  final s = studio.settings;
  final phrases =
      parseTextPhrases(studio.textInput, uppercase: studio.textUppercase);
  return WordArtParams(
    phrases: phrases.isEmpty ? const ['WORD'] : phrases,
    palette: s.wordartPalette.round(),
    density: s.wordartDensity,
    rotation: s.wordartRotation,
    contrast: s.wordartContrast,
    ground: s.wordartGround,
    vivid: s.wordartVivid,
    empty: s.wordartEmpty,
    seedNonce: studio.wordartSeedNonce,
  );
}
