import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../ancient/ancient_renderer.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';

/// Long side (logical px) the on-screen ancient preview renders at.
const double _previewLong = 860;

/// Live ancient-mosaic preview: samples the base once, rebuilds the stone
/// geometry (debounced) when the look settings change, and paints it scaled to
/// fit. Self-contained — no tiles / matching / server.
class AncientPreview extends StatefulWidget {
  const AncientPreview({super.key, required this.base, required this.params});

  final BaseImage base;
  final AncientParams params;

  @override
  State<AncientPreview> createState() => _AncientPreviewState();
}

class _AncientPreviewState extends State<AncientPreview> {
  Uint8List? _rgba;
  int _sw = 0, _sh = 0;
  double _w = 0, _h = 0;
  AncientGeometry? _geo;
  AncientSprites? _sprites;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    AncientSprites.load().then((s) {
      if (mounted) setState(() => _sprites = s);
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
    _w = _sw * scale;
    _h = _sh * scale;
    _build();
  }

  void _scheduleBuild() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 90), _build);
  }

  void _build() {
    final rgba = _rgba;
    if (rgba == null) return;
    final geo = buildAncientGeometry(rgba, _sw, _sh, _w, _h, widget.params);
    if (mounted) setState(() => _geo = geo);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final geo = _geo;
    if (geo == null) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _w,
          height: _h,
          child: CustomPaint(
          size: Size(_w, _h),
          painter: AncientPainter(geo,
              baseImage: widget.base.thumbnail, sprites: _sprites),
        ),
        ),
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
