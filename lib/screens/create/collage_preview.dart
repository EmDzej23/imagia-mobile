import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collage/collage_renderer.dart';
import '../../mosaic/hires_tiles.dart';
import '../../state/collage_controller.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

/// Live collage preview: the same pile the export renders, pinch to zoom.
class CollagePreview extends ConsumerStatefulWidget {
  const CollagePreview({super.key});

  @override
  ConsumerState<CollagePreview> createState() => _CollagePreviewState();
}

class _CollagePreviewState extends ConsumerState<CollagePreview> {
  final _transform = TransformationController();
  late final HiResTiles _hiRes = HiResTiles(
    fetch: (id) => ref.read(collageControllerProvider.notifier).hiResBytes(id),
    pixelBudget: 32 * 1000 * 1000,
  );

  String? _laidFor;
  List<PilePlacement> _placements = const [];
  int _layoutToken = 0;
  bool _laying = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _transform.dispose();
    _hiRes.dispose();
    super.dispose();
  }

  void _maybeRelayout(List<PilePiece> pieces, PileParams params) {
    final sig =
        '${params.hashCode}#${pieces.map((p) => p.layoutSignature).join(';')}';
    if (sig == _laidFor) return;
    _laidFor = sig;
    final token = ++_layoutToken;
    _laying = true;
    layPile(pieces, params).then((placements) {
      if (!mounted || token != _layoutToken) return;
      setState(() {
        _placements = placements;
        _laying = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final studio = ref.watch(studioControllerProvider);
    ref.watch(collageControllerProvider); // rebuild as images / cuts arrive
    final collage = ref.read(collageControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) collage.ensureLoaded();
    });
    if (studio.tiles.isEmpty) {
      return Center(
        child: Text(
          'Add photos to make a collage',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final params = collageParamsFrom(studio, collage.seedNonce);
    final pieces = collage.pieces();
    // Lay out once every photo is in (a partial pile would reshuffle as the rest load).
    if (pieces.length == collage.photos.length) _maybeRelayout(pieces, params);
    final size = formatSize(params.format);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(
      builder: (context, c) {
        final k = math.min(c.maxWidth / size.w, c.maxHeight / size.h);
        final w = size.w * k, h = size.h * k;
        final zoom = _transform.value.getMaxScaleOnAxis();
        return Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 10,
              child: Center(
                child: SizedBox(
                  width: w,
                  height: h,
                  child: _placements.isEmpty
                      ? const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : CustomPaint(
                          painter: _PilePainter(
                            pieces: pieces,
                            placements: _placements,
                            params: params,
                            W: size.w,
                            H: size.h,
                            screenPxPerRef: k * zoom * dpr,
                            hiRes: _hiRes,
                          ),
                        ),
                ),
              ),
            ),
            if (_laying || collage.cutting > 0)
              const Positioned(
                top: 12,
                right: 12,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PilePainter extends CustomPainter {
  _PilePainter({
    required this.pieces,
    required this.placements,
    required this.params,
    required this.W,
    required this.H,
    required this.screenPxPerRef,
    required this.hiRes,
  }) : super(repaint: hiRes.version);

  final List<PilePiece> pieces;
  final List<PilePlacement> placements;
  final PileParams params;
  final double W, H;

  /// Device pixels per reference px at the current zoom.
  final double screenPxPerRef;
  final HiResTiles hiRes;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / W, size.height / H);
    final byId = {for (final p in pieces) p.id: p};
    final need = <String, double>{};
    for (final pl in placements) {
      need[pl.tileId] = math.max(pl.w, pl.h) * screenPxPerRef;
    }
    drawPile(
      canvas,
      pieces,
      placements,
      params,
      W,
      H,
      sharper: (id) {
        final p = byId[id];
        final img = p?.image;
        final want = need[id] ?? 0;
        if (img == null || want <= math.max(img.width, img.height) * 1.25) {
          return null;
        }
        final sharp = hiRes.get(id, want);
        if (sharp == null) hiRes.want(id, want);
        return sharp;
      },
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PilePainter old) =>
      old.placements != placements ||
      old.params != params ||
      old.screenPxPerRef != screenPxPerRef ||
      !identical(old.pieces, pieces) ||
      old.pieces.length != pieces.length;
}
