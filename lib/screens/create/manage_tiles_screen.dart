import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mosaic/preview_painter.dart' show centerCropSrc;
import '../../mosaic/types.dart';
import '../../services/haptics.dart';
import '../../state/collage_controller.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/confirm_dialog.dart';

import 'dart:ui' as ui;

/// Full-screen tile library: large thumbnails, tap to open a photo in the crop
/// editor, long-press to start selecting, then delete the selection in one go.
///
/// Removing only takes photos out of this project (the uploads stay in storage),
/// and the mosaic is re-planned ONCE for the whole selection.
class ManageTilesScreen extends ConsumerStatefulWidget {
  const ManageTilesScreen({super.key, this.onOpenTile});

  /// Opens one tile in the crop editor. Null in modes without per-tile crops —
  /// there a tap selects instead.
  final Future<void> Function(BuildContext context, TileAsset tile)? onOpenTile;

  @override
  ConsumerState<ManageTilesScreen> createState() => _ManageTilesScreenState();
}

class _ManageTilesScreenState extends ConsumerState<ManageTilesScreen> {
  final Set<String> _selected = {};
  bool _selecting = false;

  void _toggle(String id) {
    Haptics.selection();
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _startSelecting(String id) {
    Haptics.impact();
    setState(() {
      _selecting = true;
      _selected.add(id);
    });
  }

  void _stopSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await confirmDestructive(
      context,
      title: n == 1 ? 'Remove 1 photo?' : 'Remove $n photos?',
      message:
          'They will no longer be used in your mosaic. You can add them again later.',
    );
    if (!ok || !mounted) return;
    final controller = ref.read(studioControllerProvider.notifier);
    controller.removeTiles(Set.of(_selected));
    controller.buildPlan();
    Haptics.success();
    _stopSelecting();
  }

  /// Collage: cut the selection out of its background, or use it whole again.
  void _setCut(bool cutOut) {
    ref
        .read(collageControllerProvider.notifier)
        .setCut(Set.of(_selected), cutOut);
    Haptics.success();
    _stopSelecting();
  }

  void _setHero() {
    final id = _selected.length == 1 ? _selected.first : null;
    final collage = ref.read(collageControllerProvider.notifier);
    final current = ref.read(studioControllerProvider).settings.collageHero;
    collage.setHero(id == current ? null : id);
    Haptics.success();
    _stopSelecting();
  }

  @override
  Widget build(BuildContext context) {
    final studio = ref.watch(studioControllerProvider);
    final tiles = studio.tiles;
    final isCollage = studio.settings.mosaicMode == 'collage';
    if (isCollage) ref.watch(collageControllerProvider);
    final collage = ref.read(collageControllerProvider.notifier);
    // A tile removed elsewhere (e.g. from the crop editor) leaves the selection.
    if (_selected.isNotEmpty) {
      final ids = {for (final t in tiles) t.id};
      _selected.removeWhere((id) => !ids.contains(id));
    }
    final allSelected = tiles.isNotEmpty && _selected.length == tiles.length;

    return PopScope(
      // Back leaves selection first, then the screen — like the system gallery.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _stopSelecting();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          leading: _selecting
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel selection',
                  onPressed: _stopSelecting,
                )
              : null,
          title: Text(
            _selecting
                ? '${_selected.length} selected'
                : 'Your tiles (${tiles.length})',
            style: AppTypography.title,
          ),
          actions: [
            if (_selecting) ...[
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected.addAll(tiles.map((t) => t.id));
                  }
                }),
                child: Text(allSelected ? 'None' : 'All'),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove selected',
                color: AppColors.error,
                onPressed: _selected.isEmpty ? null : _deleteSelected,
              ),
            ] else if (tiles.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _selecting = true),
                child: const Text('Select'),
              ),
          ],
        ),
        bottomNavigationBar: isCollage && _selecting && _selected.isNotEmpty
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.x3,
                    AppSpacing.x2,
                    AppSpacing.x3,
                    AppSpacing.x3,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _setCut(true),
                          icon: const Icon(Icons.content_cut, size: 18),
                          label: const Text('Cut out'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x2),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _setCut(false),
                          child: const Text('Use whole'),
                        ),
                      ),
                      if (_selected.length == 1) ...[
                        const SizedBox(width: AppSpacing.x2),
                        IconButton(
                          tooltip: 'Centre piece',
                          onPressed: _setHero,
                          icon: Icon(
                            studio.settings.collageHero == _selected.first
                                ? Icons.star
                                : Icons.star_border,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : null,
        body: tiles.isEmpty
            ? Center(child: Text('No tiles yet', style: AppTypography.caption))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.x4,
                      0,
                      AppSpacing.x4,
                      AppSpacing.x2,
                    ),
                    child: Text(
                      isCollage
                          ? (_selecting
                                ? 'Select photos, then cut them out or use them whole.'
                                : 'Tap photos to select them — then cut the subject out of '
                                      'its background, or make one the centre piece.')
                          : _selecting
                          ? 'Tap photos to select them.'
                          : widget.onOpenTile != null
                          ? 'Tap a photo to crop or remove it. Long-press to select several.'
                          : 'Tap or long-press photos to select them.',
                      style: AppTypography.caption,
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      // Clears Android's gesture bar (edge-to-edge).
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.x2,
                        0,
                        AppSpacing.x2,
                        AppSpacing.x4 + MediaQuery.paddingOf(context).bottom,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 120,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                          ),
                      itemCount: tiles.length,
                      itemBuilder: (context, i) {
                        final tile = tiles[i];
                        final selected = _selected.contains(tile.id);
                        final crop =
                            studio.tileCrops[studio.cropSlotFor(tile.id)];
                        return GestureDetector(
                          onTap: () {
                            if (_selecting) {
                              _toggle(tile.id);
                            } else if (widget.onOpenTile != null) {
                              widget.onOpenTile!(context, tile);
                            } else {
                              _startSelecting(tile.id);
                            }
                          },
                          onLongPress: _selecting
                              ? () => _toggle(tile.id)
                              : () => _startSelecting(tile.id),
                          child: _ManageTile(
                            image: tile.thumbnail,
                            crop: crop,
                            topCrop: studio.settings.mosaicMode == 'square',
                            selecting: _selecting,
                            selected: selected,
                            cutState: isCollage
                                ? collage.stateOf(tile.id)
                                : null,
                            cutImage: isCollage
                                ? collage.cutThumb(tile.id)
                                : null,
                            failReason: isCollage
                                ? collage.failReason(tile.id)
                                : null,
                            hero:
                                isCollage &&
                                studio.settings.collageHero == tile.id,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ManageTile extends StatelessWidget {
  const _ManageTile({
    required this.image,
    required this.crop,
    required this.topCrop,
    required this.selecting,
    required this.selected,
    this.cutState,
    this.cutImage,
    this.failReason,
    this.hero = false,
  });

  /// Collage only: the photo's cut-out state, its cut-out image, the failure reason
  /// and whether it is the centre piece.
  final CutState? cutState;
  final ui.Image? cutImage;
  final String? failReason;
  final bool hero;

  final ui.Image image;
  final TileCrop? crop;
  final bool topCrop;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          child: AnimatedScale(
            // The picked photo shrinks a little, as in the system gallery.
            scale: selected ? 0.88 : 1,
            duration: const Duration(milliseconds: 120),
            child: cutImage != null && cutState == CutState.cutout
                ? CustomPaint(painter: _CutPainter(image: cutImage!))
                : CustomPaint(
                    painter: _ThumbPainter(
                      image: image,
                      crop: crop,
                      topCrop: topCrop,
                    ),
                  ),
          ),
        ),
        if (crop != null && !selecting)
          // Same "this is cropped" signal as the strip: a hairline inset ring.
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        if (cutState == CutState.cutting)
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          ),
        if (cutState == CutState.failed)
          Positioned(
            left: 4,
            bottom: 4,
            child: Tooltip(
              message: failReason ?? 'Could not cut this photo out',
              child: const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Colors.amber,
              ),
            ),
          ),
        if (cutState == CutState.cutout)
          const Positioned(
            left: 4,
            bottom: 4,
            child: Icon(Icons.content_cut, size: 16, color: Colors.white),
          ),
        if (hero)
          const Positioned(
            left: 4,
            top: 4,
            child: Icon(Icons.star, size: 18, color: Colors.amber),
          ),
        if (selecting)
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.error : Colors.black45,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// The thumbnail framed as the mosaic uses it — manual crop, else the automatic one.
class _ThumbPainter extends CustomPainter {
  _ThumbPainter({required this.image, this.crop, this.topCrop = false});

  final ui.Image image;
  final TileCrop? crop;
  final bool topCrop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      centerCropSrc(
        image,
        size.width / size.height,
        topCrop: topCrop,
        crop: crop,
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) =>
      old.crop != crop || old.image != image || old.topCrop != topCrop;
}

/// A cut-out on a light checkerboard, fitted (it is transparent around the subject).
class _CutPainter extends CustomPainter {
  _CutPainter({required this.image});
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    const sq = 8.0;
    final a = Paint()..color = const Color(0xFF3A3F4B);
    final b = Paint()..color = const Color(0xFF2A2E37);
    for (var y = 0.0; y < size.height; y += sq) {
      for (var x = 0.0; x < size.width; x += sq) {
        final odd = ((x / sq).floor() + (y / sq).floor()).isOdd;
        canvas.drawRect(Rect.fromLTWH(x, y, sq, sq), odd ? a : b);
      }
    }
    final iw = image.width.toDouble(), ih = image.height.toDouble();
    final k = (size.width / iw) < (size.height / ih)
        ? size.width / iw
        : size.height / ih;
    final dw = iw * k, dh = ih * k;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _CutPainter old) => old.image != image;
}
