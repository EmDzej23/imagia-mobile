import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../ancient/ancient_renderer.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';

/// Long side (px) the ancient preview is rasterised at.
const double _previewLong = 900;

/// Live ancient-mosaic preview. Samples the base once, then — debounced on any
/// look-setting change — rebuilds the stone geometry and RASTERISES it to a
/// single [ui.Image]. The widget then just displays that static bitmap, so
/// scrolling / compositing never re-runs the (very expensive) stone painting.
class AncientPreview extends StatefulWidget {
  const AncientPreview({super.key, required this.base, required this.params});

  final BaseImage base;
  final AncientParams params;

  @override
  State<AncientPreview> createState() => _AncientPreviewState();
}

class _AncientPreviewState extends State<AncientPreview> {
  Uint8List? _rgba;
  int _sw = 0, _sh = 0, _w = 0, _h = 0;
  AncientSprites? _sprites;
  ui.Image? _image;
  Timer? _debounce;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _load();
    AncientSprites.load().then((s) {
      if (!mounted) return;
      _sprites = s;
      _scheduleBuild(); // re-render once sprites are ready (shape modes)
    });
  }

  @override
  void didUpdateWidget(AncientPreview old) {
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
    _debounce = Timer(const Duration(milliseconds: 110), _build);
  }

  Future<void> _build() async {
    final rgba = _rgba;
    if (rgba == null || _w < 2 || _h < 2) return;
    final token = ++_token;
    final geo = buildAncientGeometry(
        rgba, _sw, _sh, _w.toDouble(), _h.toDouble(), widget.params);
    final img = await renderAncientImage(geo, _w, _h,
        baseImage: widget.base.thumbnail, sprites: _sprites);
    if (!mounted || token != _token) {
      img.dispose();
      return;
    }
    _image?.dispose();
    setState(() => _image = img);
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
    if (img == null) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    // Contain + centred, exactly like the tile-mosaic preview.
    return RepaintBoundary(
      child: SizedBox.expand(
        child: RawImage(image: img, fit: BoxFit.contain),
      ),
    );
  }
}

/// Build [AncientParams] from the studio state for the given mode.
AncientParams ancientParamsFromState(StudioState studio, {required bool curved}) {
  final s = studio.settings;
  return AncientParams(
    stoneSize: s.ancientStoneSize,
    grout: s.ancientGrout,
    irregularity: s.ancientIrregularity,
    variation: s.ancientVariation,
    bevel: s.ancientBevel,
    groutColor: s.ancientGroutColor,
    curviness: curved ? s.ancientCurviness : 0,
    shape: curved ? s.ancientShape : 'none',
    seedNonce: studio.ancientSeedNonce,
  );
}
