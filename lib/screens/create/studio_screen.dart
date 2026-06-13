import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../mosaic/preview_painter.dart';
import '../../mosaic/types.dart';
import '../../state/render_controller.dart';
import '../../state/studio_controller.dart';
import '../../state/video_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';
import '../../widgets/segmented_selector.dart';

class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});

  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends ConsumerState<StudioScreen> {
  // Cached in initState so dispose() doesn't touch `ref` (unsafe once the
  // widget is being unmounted). The notifier is long-lived, so holding it is
  // safe.
  late final StudioController _controller =
      ref.read(studioControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final studio = ref.read(studioControllerProvider);
      if (studio.plan == null && studio.canPlan && !studio.isPlanning) {
        _controller.buildPlan();
      }
    });
  }

  @override
  void dispose() {
    // Leaving the studio (e.g. back to gallery) drops any in-flight restore.
    _controller.cancelRestore();
    super.dispose();
  }

  Future<void> _changeBase() async {
    await _controller.pickBaseImage();
    _controller.buildPlan();
  }

  Future<void> _addTiles() async {
    await _controller.pickTileImages();
    _controller.buildPlan();
  }

  void _removeTile(String id) {
    _controller.removeTile(id);
    _controller.buildPlan();
  }

  void _onExport(BuildContext context, bool canRender) {
    if (canRender) {
      ref.read(renderControllerProvider.notifier).reset();
      context.push('/create/export');
      return;
    }
    // No tokens — explain and offer to buy.
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('You’re out of tokens', style: AppTypography.title),
        content: Text(
          'A full-quality export costs 1 token. Building and previewing your '
          'mosaic is free — you only spend a token when you export.',
          style: AppTypography.body,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not now')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/account');
            },
            child: const Text('Buy tokens'),
          ),
        ],
      ),
    );
  }

  void _showTokenInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('Export & tokens', style: AppTypography.title),
        content: Text(
          'Each full-quality export renders your mosaic at high resolution on '
          'our servers and costs 1 token. Designing, previewing, and creating '
          'videos are all free — tokens are only used at export.',
          style: AppTypography.body,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  /// Loupe popup: a magnified window of the mosaic centered on the tapped point.
  void _showLoupe(SlimMosaicPlan plan, double bx, double by) {
    final widths = plan.placements.map((p) => p.width).toList()..sort();
    final medianW =
        widths.isEmpty ? plan.baseWidth / 10 : widths[widths.length ~/ 2];
    final windowSize =
        (medianW * 6).clamp(plan.baseWidth * 0.04, plan.baseWidth).toDouble();
    final studio = ref.read(studioControllerProvider);

    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        final side = MediaQuery.of(ctx).size.width.clamp(0, 360) * 0.9;
        return GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.primaryBright, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: CustomPaint(
                    painter: MosaicZoomPainter(
                      plan: plan,
                      tileImages: studio.tileImages,
                      baseImage: studio.base?.overlay,
                      tintStrength: studio.settings.tintStrength,
                      focusX: bx,
                      focusY: by,
                      windowSize: windowSize,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                Text('Tap to close', style: AppTypography.caption),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final studio = ref.watch(studioControllerProvider);
    final canRender = ref.watch(canRenderProvider);
    final settings = studio.settings;

    void update(MosaicSettings s) => _controller.updateSettings(s);

    return Scaffold(
      appBar: AppBar(title: const Text('Studio')),
      body: SafeArea(
        child: Column(
          children: [
            // ── Preview (top ~60%) — tap to zoom ──
            Expanded(
              flex: 6,
              child: LayoutBuilder(builder: (context, constraints) {
                final plan = studio.plan;
                return GestureDetector(
                  onTapUp: plan == null
                      ? null
                      : (details) {
                          final fit = computeMosaicFit(constraints.biggest,
                              plan.baseWidth, plan.baseHeight);
                          final bx =
                              (details.localPosition.dx - fit.ox) / fit.scale;
                          final by =
                              (details.localPosition.dy - fit.oy) / fit.scale;
                          if (bx < 0 ||
                              by < 0 ||
                              bx > plan.baseWidth ||
                              by > plan.baseHeight) {
                            return;
                          }
                          _showLoupe(plan, bx, by);
                        },
                  child: Container(
                    width: double.infinity,
                    color: AppColors.background,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (plan != null)
                          CustomPaint(
                            painter: MosaicPreviewPainter(
                              plan: plan,
                              tileImages: studio.tileImages,
                              baseImage: studio.base?.overlay,
                              tintStrength: settings.tintStrength,
                            ),
                          )
                        else
                          Center(
                            child: Text(
                              studio.isRestoring
                                  ? 'Restoring project… ${studio.uploadDone}/${studio.uploadTotal}'
                                  : studio.canPlan || studio.isPlanning
                                      ? 'Building preview…'
                                      : 'Add a base photo and tiles',
                              style: AppTypography.body
                                  .copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                        if (plan != null)
                          const Positioned(
                            bottom: AppSpacing.x2,
                            right: AppSpacing.x2,
                            child: _Hint(text: 'Tap to zoom'),
                          ),
                        if (studio.isPlanning)
                          const Positioned(
                            top: AppSpacing.x3,
                            right: AppSpacing.x3,
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.accent),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ),
            // ── Controls ──
            Expanded(
              flex: 4,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
                ),
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  children: [
                    _SourceAndTiles(
                      studio: studio,
                      onChangeBase: _changeBase,
                      onAddTiles: _addTiles,
                      onRemoveTile: _removeTile,
                    ),
                    const Divider(
                        color: AppColors.border, height: AppSpacing.x6),
                    Text('Mode', style: AppTypography.label),
                    const SizedBox(height: AppSpacing.x2),
                    SegmentedSelector<String>(
                      selected: settings.mosaicMode,
                      onSelected: (m) => update(settings.copyWith(mosaicMode: m)),
                      options: const [
                        SegmentOption('square', 'Square'),
                        SegmentOption('landscape', 'Landscape'),
                        SegmentOption('portrait', 'Portrait'),
                        SegmentOption('original', 'Original'),
                        SegmentOption('blocks', 'Blocks'),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x4),
                    LabeledSlider(
                      label: 'Density',
                      value: settings.density,
                      min: 40,
                      max: 500,
                      onChanged: (v) => update(settings.copyWith(density: v)),
                    ),
                    LabeledSlider(
                      label: 'Variety',
                      value: settings.reusePenalty,
                      min: 0,
                      max: 1,
                      valueLabel: settings.reusePenalty.toStringAsFixed(2),
                      onChanged: (v) =>
                          update(settings.copyWith(reusePenalty: v)),
                    ),
                    LabeledSlider(
                      label: 'Tint',
                      value: settings.tintStrength,
                      min: 0,
                      max: 0.5,
                      valueLabel: settings.tintStrength.toStringAsFixed(2),
                      onChanged: (v) =>
                          _controller.updateRenderParam(tintStrength: v),
                    ),
                    const Divider(
                        color: AppColors.border, height: AppSpacing.x6),
                    LabeledSlider(
                      label: 'Color boost',
                      value: settings.colorBoost,
                      min: 1,
                      max: 2,
                      valueLabel: settings.colorBoost.toStringAsFixed(2),
                      onChanged: (v) => update(settings.copyWith(colorBoost: v)),
                    ),
                    LabeledSlider(
                      label: 'Auto contrast',
                      value: settings.autoContrast,
                      min: 0,
                      max: 1,
                      valueLabel: settings.autoContrast.toStringAsFixed(2),
                      onChanged: (v) =>
                          update(settings.copyWith(autoContrast: v)),
                    ),
                    const SizedBox(height: AppSpacing.x4),
                    Row(
                      children: [
                        Expanded(
                          child: PrimaryButton(
                            label: 'Export full quality (1)',
                            onPressed: studio.plan == null
                                ? null
                                : () => _onExport(context, canRender),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        IconButton(
                          tooltip: 'About export & tokens',
                          icon: const Icon(Icons.info_outline,
                              color: AppColors.textSecondary),
                          onPressed: () => _showTokenInfo(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x3),
                    SecondaryButton(
                      label: 'Create video (free)',
                      icon: Icons.movie_creation_outlined,
                      onPressed: studio.plan == null
                          ? null
                          : () {
                              ref.read(videoControllerProvider.notifier).reset();
                              context.push('/create/video');
                            },
                    ),
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

/// Base-photo + tile management strip shown at the top of the controls panel.
class _SourceAndTiles extends StatelessWidget {
  const _SourceAndTiles({
    required this.studio,
    required this.onChangeBase,
    required this.onAddTiles,
    required this.onRemoveTile,
  });

  final StudioState studio;
  final VoidCallback onChangeBase;
  final VoidCallback onAddTiles;
  final void Function(String id) onRemoveTile;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (studio.base != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                child: RawImage(
                    image: studio.base!.thumbnail,
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover),
              ),
            const SizedBox(width: AppSpacing.x2),
            Text('Base photo', style: AppTypography.label),
            const Spacer(),
            TextButton.icon(
              onPressed: studio.isUploadingBase ? null : onChangeBase,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Change'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Row(
          children: [
            Text('Tiles (${studio.tiles.length})',
                style: AppTypography.label),
            const Spacer(),
            TextButton.icon(
              onPressed: studio.isUploadingTiles ? null : onAddTiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        SizedBox(
          height: 56,
          child: studio.tiles.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      studio.isUploadingTiles
                          ? 'Adding ${studio.uploadDone}/${studio.uploadTotal}…'
                          : 'No tiles yet',
                      style: AppTypography.caption),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: studio.tiles.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.x2),
                  itemBuilder: (context, i) {
                    final tile = studio.tiles[i];
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                          child: RawImage(
                              image: tile.thumbnail,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: () => onRemoveTile(tile.id),
                            child: Container(
                              decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle),
                              padding: const EdgeInsets.all(2),
                              child: const Icon(Icons.close,
                                  size: 13, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x2, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.zoom_in, size: 14, color: Colors.white70),
          const SizedBox(width: 4),
          Text(text,
              style: AppTypography.caption.copyWith(color: Colors.white70)),
        ],
      ),
    );
  }
}
