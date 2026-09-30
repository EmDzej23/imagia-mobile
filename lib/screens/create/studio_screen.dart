import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../mosaic/preview_painter.dart';
import '../../mosaic/shared.dart'
    show maxOutputSaturation, minOutputSaturation;
import '../../mosaic/types.dart';
import '../../print/print_catalog.dart' show isPrintRegionAllowed;
import '../../services/haptics.dart';
import '../../state/render_controller.dart';
import '../../state/studio_controller.dart';
import '../../state/video_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_progress_bar.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/sample_pack_sheet.dart';
import '../../widgets/primary_button.dart';
import '../../wordart/wordart_renderer.dart' show suggestColorsFromRgba;
import 'ancient_preview.dart';
import 'wordart_preview.dart';
import 'base_crop_screen.dart';
import 'tile_crop_screen.dart';
import '../../widgets/segmented_selector.dart';

/// The photo layouts the studio offers.
///
/// Top-level, not inline in `build`, so a test can check the list the UI ACTUALLY
/// renders against `sanitizeSettings`. Every value here must be in `validModes`:
/// an unlisted mode is silently rewritten to 'original' rather than rejected, which
/// is how "3D" and "Hexagons" shipped as no-ops.
///
/// `blocks` is deliberately absent — `original` covers it. Not deleted from the
/// engine: saved projects and presets still carry the mode and still render.
/// Photo layouts that honour a manual per-tile crop.
///
/// Every tile-matching mode does: the preview painter and both compositors apply
/// `tileCrops` unconditionally, and the map is keyed by tile id with nothing
/// mode-specific in it. So the editor is offered wherever tiles are used, and a crop
/// set in one mode carries into the others.
///
/// This was gated to 'square' alone, which meant a crop chosen there silently applied
/// in every other mode with no way to see or change it — and in every mode BUT square
/// the button simply was not there. Mirrors `modeSupportsTileCrops` in
/// foto-mozaik/components/mosaic-studio.tsx; keep the two lists together.
bool modeSupportsTileCrops(String mode) => const {
      'original',
      'blocks',
      'square',
      'landscape',
      'portrait',
      'rhombille',
      'hexagon',
    }.contains(mode);

const kPhotoModeOptions = <SegmentOption<String>>[
  SegmentOption('original', 'Original'),
  SegmentOption('square', 'Square'),
  SegmentOption('landscape', 'Landscape'),
  SegmentOption('portrait', 'Portrait'),
  SegmentOption('rhombille', '🧊 3D'),
  SegmentOption('hexagon', '⬡ Hexagons'),
];

/// Advanced word-art sliders (flow tilt / contrast / palette / ground / vividness)
/// are hidden — their values are now fixed defaults. Flip to true to restore them.
const bool _showAdvancedWordart = false;
/// "Empty space" is hidden for now (its default still applies). Flip to true to restore.
const bool _showEmptySpace = false;

class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});

  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

/// The way back out of a collapsed preview.
///
/// Labelled, not just an icon: the grabber above the settings can be found by someone
/// looking for it, but this has to be understood by someone who is not. It only
/// appears once the preview is actually small, so it costs nothing the rest of the
/// time.
class _ExpandPreviewButton extends StatelessWidget {
  const _ExpandPreviewButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.open_in_full, size: 13, color: Colors.white),
            const SizedBox(width: 6),
            Text('Expand',
                style: AppTypography.caption.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// How much flex the preview gives up when fully collapsed (of 600). It shrinks to
/// 260/1000 of the pane rather than vanishing: a preview you cannot see is not a
/// preview, and the point is to keep the picture in view while the settings get room.
const double _collapseTravel = 340;

/// Scroll distance over which the preview goes from full height to fully collapsed.
///
/// Short enough that the picture is out of the way once the first controls have
/// scrolled past, long enough that the shrink reads as motion rather than a jump.
const double _collapseDistance = 180;

class _StudioScreenState extends ConsumerState<StudioScreen>
    with SingleTickerProviderStateMixin {
  // Assigned eagerly in initState so dispose() never touches `ref` (unsafe once
  // the widget is being unmounted). Must NOT be a `late` lazy initializer —
  // that defers the `ref.read` to first access, which can be dispose() itself
  // if the screen is torn down before any build/handler reads it. The notifier
  // is long-lived, so holding the reference is safe.
  late StudioController _controller;

  // Horizontal tiles strip — scrolled to a tile when it's tapped in the loupe.
  final ScrollController _tilesScroll = ScrollController();

  /// Settings pane scroll — drives the preview collapse.
  final ScrollController _settingsScroll = ScrollController();

  /// 0 = preview at full height, 1 = collapsed.
  ///
  /// Held in an AnimationController only so the Column can rebuild off it; the value
  /// is now SET from the scroll position rather than animated, so the durations that
  /// used to be here are gone — the scroll supplies the motion.
  late final AnimationController _previewCollapse =
      AnimationController(vsync: this);

  void _onSettingsScroll() {
    if (!_settingsScroll.hasClients) return;
    // The preview follows the scroll DIRECTLY rather than animating once a threshold
    // trips. A snap always reads as a lurch — it is motion the finger did not make.
    // Tracking 1:1 reads as the list pushing the picture out of the way, which is how
    // every well-behaved collapsing header feels.
    //
    // This also settles the flapping problem by construction: with no animation there
    // is nothing to fight, so a small upward correction gives back a proportionally
    // small amount of preview instead of flinging it open.
    final t =
        (_settingsScroll.position.pixels / _collapseDistance).clamp(0.0, 1.0);
    if ((t - _previewCollapse.value).abs() > 0.001) _previewCollapse.value = t;
  }

  // ── Inline preview zoom ────────────────────────────────────────────────────
  //
  // Driven through `MosaicZoomPainter` rather than by scaling the rendered preview.
  // That matters: the painter re-draws from the actual tile images at whatever scale
  // is asked for, so zooming in shows MORE detail instead of magnifying preview-sized
  // pixels — and it culls the cells outside the window, so the cost does not grow as
  // the user zooms further in.

  /// 1 = the whole mosaic, fitted. Above that, the visible window shrinks.
  double _zoom = 1;
  double _zoomAtGestureStart = 1;

  /// Centre of the visible window, in BASE pixels. Null until first use = centred.
  Offset? _focusBase;

  /// Upper bound on pinch zoom.
  ///
  /// Deep enough that a single cell can more than fill the screen. Note the real
  /// detail ceiling is lower than this: the strip's tile images are decoded at 256 px
  /// (see `tileThumbBatch`), so past roughly 10-12x it is those thumbnails being
  /// magnified rather than new detail appearing. Zooming further is still useful for
  /// placing and inspecting a specific cell, which is why the cap is not set there.
  static const double _maxZoom = 40;

  void _resetZoom() {
    if (_zoom == 1 && _focusBase == null) return;
    setState(() {
      _zoom = 1;
      _focusBase = null;
    });
  }

  /// Keep the window inside the picture. When the window is larger than the base on an
  /// axis (which happens on the short side of a fitted view), centre on that axis
  /// instead — clamping would otherwise fight the user at the edges.
  Offset _clampFocus(Offset f, double winW, double winH, SlimMosaicPlan plan) {
    final bw = plan.baseWidth, bh = plan.baseHeight;
    final x = winW >= bw
        ? bw / 2
        : f.dx.clamp(winW / 2, bw - winW / 2).toDouble();
    final y = winH >= bh
        ? bh / 2
        : f.dy.clamp(winH / 2, bh - winH / 2).toDouble();
    return Offset(x, y);
  }

  /// Changing a setting no longer forces the preview open.
  ///
  /// It used to, on the reasoning that you touch a control to see what it does. But
  /// the preview never disappears — at full collapse it still holds a quarter of the
  /// pane — so the change IS visible, and yanking the list back to the top under
  /// someone mid-way through the settings was the more disruptive of the two. The
  /// ways back are all explicit now: the Expand button, the grabber, tapping the
  /// preview, or scrolling up.
  /// Put the preview back by returning the list to the top.
  ///
  /// The scroll position IS the collapse now, so animating the height open on its own
  /// would be overwritten by the very next scroll callback. Scrolling the list back is
  /// what actually expands it — and it is the honest gesture anyway: the preview is
  /// large exactly when you are looking at the picture rather than at the settings.
  void _expandPreview() {
    if (_settingsScroll.hasClients && _settingsScroll.position.pixels > 0) {
      _settingsScroll.animateTo(0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic);
    } else {
      _previewCollapse.value = 0;
    }
  }
  String? _highlightedTileId;
  Timer? _highlightTimer;

  // Word-art phrases list is collapsible so a long list doesn't create a big
  // scroll through the controls panel.
  bool _wordsExpanded = true;

  // Tiles strip geometry (must match the ListView item + separator below).
  static const double _tileExtent = 56;
  static const double _tileGap = AppSpacing.x2;

  /// Scrolls the tiles strip so [tileId] is visible and briefly highlights it.
  void _revealTile(String tileId) {
    final tiles = ref.read(studioControllerProvider).tiles;
    final index = tiles.indexWhere((t) => t.id == tileId);
    if (index < 0) return;

    if (_tilesScroll.hasClients) {
      final itemStart = index * (_tileExtent + _tileGap);
      final viewport = _tilesScroll.position.viewportDimension;
      // Center the tile in the viewport where possible.
      final target = (itemStart - (viewport - _tileExtent) / 2)
          .clamp(0.0, _tilesScroll.position.maxScrollExtent);
      _tilesScroll.animateTo(target,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
    }

    setState(() => _highlightedTileId = tileId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedTileId = null);
    });
  }

  @override
  void initState() {
    super.initState();
    _controller = ref.read(studioControllerProvider.notifier);
    _settingsScroll.addListener(_onSettingsScroll);
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
    _highlightTimer?.cancel();
    _tilesScroll.dispose();
    _settingsScroll.removeListener(_onSettingsScroll);
    _settingsScroll.dispose();
    _previewCollapse.dispose();
    super.dispose();
  }

  Future<void> _changeBase() async {
    await pickCropAndSetBase(context, ref);
    _controller.buildPlan();
  }

  /// Number of non-empty phrases in the shared word-art text state.
  int _wordPhraseCount(String textInput) =>
      textInput.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).length;

  /// Word-art controls: phrases + type-look sliders. The word colours come from
  /// the photo (no picker) — the picture is composed entirely of the words; only
  /// the optional photo-title caption has its own colour choice. Preview + the
  /// high-res server export share the same look params (baked layout).
  Widget _buildWordartPanel(
      StudioState studio, MosaicSettings settings, void Function(MosaicSettings) update) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.x4),
        InkWell(
          onTap: () => setState(() => _wordsExpanded = !_wordsExpanded),
          child: Row(
            children: [
              Text('Words', style: AppTypography.label),
              if (_wordPhraseCount(studio.textInput) > 0) ...[
                const SizedBox(width: AppSpacing.x1),
                Text('(${_wordPhraseCount(studio.textInput)})',
                    style: AppTypography.caption),
              ],
              const Spacer(),
              Icon(_wordsExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: AppColors.textSecondary),
            ],
          ),
        ),
        if (_wordsExpanded) ...[
          const SizedBox(height: AppSpacing.x1),
          Text('Add a word or phrase at a time — the picture is composed from '
              'them, coloured from your photo.',
              style: AppTypography.caption),
          const SizedBox(height: AppSpacing.x2),
          _PhraseChipsField(
            textInput: studio.textInput,
            onChanged: _controller.setTextInput,
          ),
        ],
        const SizedBox(height: AppSpacing.x2),
        Row(
          children: [
            Expanded(child: Text('UPPERCASE', style: AppTypography.caption)),
            Switch(
                value: studio.textUppercase,
                onChanged: _controller.setTextUppercase),
          ],
        ),
        const SizedBox(height: AppSpacing.x3),
        _CaptionField(
          base: studio.base?.thumbnail,
          caption: settings.wordartCaption,
          captionColor: settings.wordartTitleColor,
          onCaptionChanged: (v) =>
              update(settings.copyWith(wordartCaption: v)),
          onColorChanged: (v) =>
              update(settings.copyWith(wordartTitleColor: v)),
        ),
        const SizedBox(height: AppSpacing.x2),
        LabeledSlider(
          label: 'Word size',
          value: settings.wordartDensity,
          min: 18,
          max: 100,
          valueLabel: settings.wordartDensity.toStringAsFixed(0),
          onChanged: (v) => update(settings.copyWith(wordartDensity: v)),
        ),
        // Advanced controls (flow tilt / contrast / palette / ground / vividness)
        // are hidden — their values are now fixed defaults (see MosaicSettings).
        // Flip [_showAdvancedWordart] to true to bring the sliders back.
        if (_showAdvancedWordart) ...[
          LabeledSlider(
            label: 'Flow tilt',
            value: settings.wordartRotation,
            min: 0,
            max: 80,
            valueLabel: '${settings.wordartRotation.toStringAsFixed(0)}°',
            onChanged: (v) => update(settings.copyWith(wordartRotation: v)),
          ),
          LabeledSlider(
            label: 'Contrast',
            value: settings.wordartContrast,
            min: -1,
            max: 1,
            valueLabel: settings.wordartContrast.toStringAsFixed(2),
            onChanged: (v) => update(settings.copyWith(wordartContrast: v)),
          ),
          LabeledSlider(
            label: 'Palette',
            value: settings.wordartPalette,
            min: 2,
            max: 64,
            valueLabel: settings.wordartPalette.round() >= 64
                ? 'Full'
                : settings.wordartPalette.toStringAsFixed(0),
            onChanged: (v) => update(settings.copyWith(wordartPalette: v)),
          ),
          LabeledSlider(
            label: 'Ground',
            value: settings.wordartGround,
            min: 0,
            max: 1,
            valueLabel: settings.wordartGround.toStringAsFixed(2),
            onChanged: (v) => update(settings.copyWith(wordartGround: v)),
          ),
          LabeledSlider(
            label: 'Vividness',
            value: settings.wordartVivid,
            min: 0,
            max: 1,
            valueLabel: settings.wordartVivid.toStringAsFixed(2),
            onChanged: (v) => update(settings.copyWith(wordartVivid: v)),
          ),
        ],
        if (_showEmptySpace)
          LabeledSlider(
            label: 'Empty space',
            value: settings.wordartEmpty,
            min: 0,
            max: 1,
            valueLabel: '${(settings.wordartEmpty * 100).round()}%',
            onChanged: (v) => update(settings.copyWith(wordartEmpty: v)),
          ),
        LabeledSlider(
          label: 'Coverage',
          value: settings.wordartCoverage,
          min: 0,
          max: 1,
          valueLabel: '${(settings.wordartCoverage * 100).round()}%',
          onChanged: (v) => update(settings.copyWith(wordartCoverage: v)),
        ),
        const SizedBox(height: AppSpacing.x3),
        OutlinedButton.icon(
          onPressed: studio.base == null ? null : _controller.newWordartLayout,
          icon: const Icon(Icons.casino_outlined, size: 18),
          label: const Text('New word layout'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size.fromHeight(AppSpacing.touchTarget),
          ),
        ),
      ],
    );
  }

  /// Two-level mode selector: top-level group (Photos / Shapes / Words), then a
  /// sub-choice — a photo layout, a shape style, or nothing for words. Mirrors
  /// the web mode grouping. The shape row flattens the curved flag + motif into
  /// one choice (Cut stone = ancient; Cobblestone / ♥ / 🏀 / 🌸 = ancient-curved).
  Widget _buildModeGroups(
      MosaicSettings settings, void Function(MosaicSettings) update) {
    final mode = settings.mosaicMode;
    final isAncient = mode == 'ancient' || mode == 'ancient-curved';
    final isWordart = mode == 'wordart';
    final group = isWordart ? 'word' : (isAncient ? 'shape' : 'photo');

    String shapeKey() {
      if (mode == 'ancient') return 'cut';
      switch (settings.ancientShape) {
        case 'heart':
          return 'heart';
        case 'basketball':
          return 'ball';
        case 'flower':
          return 'flower';
        default:
          return 'cobble';
      }
    }

    void selectShape(String key) {
      switch (key) {
        case 'cut':
          update(settings.copyWith(mosaicMode: 'ancient', ancientShape: 'none'));
        case 'cobble':
          update(settings.copyWith(
              mosaicMode: 'ancient-curved', ancientShape: 'none'));
        case 'heart':
          update(settings.copyWith(
              mosaicMode: 'ancient-curved', ancientShape: 'heart'));
        case 'ball':
          update(settings.copyWith(
              mosaicMode: 'ancient-curved', ancientShape: 'basketball'));
        case 'flower':
          update(settings.copyWith(
              mosaicMode: 'ancient-curved', ancientShape: 'flower'));
      }
    }

    void selectGroup(String g) {
      if (g == group) return;
      switch (g) {
        case 'photo':
          update(settings.copyWith(mosaicMode: 'square'));
        case 'shape':
          update(settings.copyWith(mosaicMode: 'ancient', ancientShape: 'none'));
        case 'word':
          update(settings.copyWith(mosaicMode: 'wordart'));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedSelector<String>(
          selected: group,
          onSelected: selectGroup,
          options: const [
            SegmentOption('photo', '🖼 Photos'),
            SegmentOption('shape', '🪨 Shapes'),
            SegmentOption('word', '🔤 Words'),
          ],
        ),
        if (group == 'photo') ...[
          const SizedBox(height: AppSpacing.x2),
          SegmentedSelector<String>(
            selected: mode,
            onSelected: (m) => update(settings.copyWith(mosaicMode: m)),
            // `blocks` hidden — `original` covers it. Not deleted: saved projects and
            // presets still carry the mode and the layout pipeline still honours it, so
            // those keep rendering exactly as before. Restore by un-commenting.
            options: kPhotoModeOptions,
          ),
        ],
        if (group == 'shape') ...[
          const SizedBox(height: AppSpacing.x2),
          SegmentedSelector<String>(
            selected: shapeKey(),
            onSelected: selectShape,
            options: const [
              SegmentOption('cut', 'Cut stone'),
              SegmentOption('cobble', 'Cobblestone'),
              SegmentOption('heart', '💗 Heart'),
              SegmentOption('ball', '🏀 Ball'),
              SegmentOption('flower', '🌸 Flower'),
            ],
          ),
        ],
      ],
    );
  }

  /// Ancient-mosaic controls (tile-less stone renderer).
  Widget _buildAncientPanel(StudioState studio, MosaicSettings settings,
      void Function(MosaicSettings) update, {required bool curved}) {
    Widget groutChip(String v, String label) {
      final active = settings.ancientGroutColor == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => update(settings.copyWith(ancientGroutColor: v)),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
            decoration: BoxDecoration(
              color: active ? AppColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(
                  color: active ? AppColors.primaryBright : AppColors.border),
            ),
            child: Center(child: Text(label, style: AppTypography.label)),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.x3),
        Text(
            'No tiles — the picture is rebuilt from cut-stone shapes sampled from your photo.',
            style: AppTypography.caption),
        const SizedBox(height: AppSpacing.x3),
        LabeledSlider(
          label: 'Stone size',
          value: settings.ancientStoneSize,
          min: 7,
          max: 34,
          valueLabel: settings.ancientStoneSize.toStringAsFixed(0),
          onChanged: (v) => update(settings.copyWith(ancientStoneSize: v)),
        ),
        LabeledSlider(
          label: 'Grout width',
          value: settings.ancientGrout,
          min: 0,
          max: 4,
          valueLabel: settings.ancientGrout.toStringAsFixed(1),
          onChanged: (v) => update(settings.copyWith(ancientGrout: v)),
        ),
        LabeledSlider(
          label: 'Irregularity',
          value: settings.ancientIrregularity,
          min: 0,
          max: 1,
          valueLabel: settings.ancientIrregularity.toStringAsFixed(2),
          onChanged: (v) => update(settings.copyWith(ancientIrregularity: v)),
        ),
        LabeledSlider(
          label: 'Colour variation',
          value: settings.ancientVariation,
          min: 0,
          max: 0.35,
          valueLabel: settings.ancientVariation.toStringAsFixed(2),
          onChanged: (v) => update(settings.copyWith(ancientVariation: v)),
        ),
        LabeledSlider(
          label: 'Bevel',
          value: settings.ancientBevel,
          min: 0,
          max: 0.7,
          valueLabel: settings.ancientBevel.toStringAsFixed(2),
          onChanged: (v) => update(settings.copyWith(ancientBevel: v)),
        ),
        if (curved)
          LabeledSlider(
            label: 'Curviness',
            value: settings.ancientCurviness,
            min: 0,
            max: 1,
            valueLabel: settings.ancientCurviness.toStringAsFixed(2),
            onChanged: (v) => update(settings.copyWith(ancientCurviness: v)),
          ),
        const SizedBox(height: AppSpacing.x2),
        Text('Grout colour', style: AppTypography.label),
        const SizedBox(height: AppSpacing.x2),
        Row(children: [
          groutChip('dark', 'Dark'),
          groutChip('stone', 'Stone'),
          groutChip('light', 'Light'),
        ]),
        const SizedBox(height: AppSpacing.x3),
        OutlinedButton.icon(
          onPressed: studio.base == null ? null : _controller.newAncientLayout,
          icon: const Icon(Icons.casino_outlined, size: 18),
          label: const Text('New stone layout'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size.fromHeight(AppSpacing.touchTarget),
          ),
        ),
      ],
    );
  }

  /// Tile-less export (ancient / word art): the high-res 10k render runs on the
  /// server (free, saved to the profile Downloads). Routes to the shared export
  /// screen, which triggers the generative render + download/save flow.
  void _onTilelessExport() {
    ref.read(renderControllerProvider.notifier).reset();
    context.push('/create/export');
  }

  Future<void> _addTiles() async {
    await _controller.pickTileImages();
    _controller.buildPlan();
  }

  Future<void> _loadSamples() async {
    final folder = await showSamplePackPicker(context);
    if (folder == null) return;
    await _controller.loadSampleTiles(folder);
    _controller.buildPlan();
  }

  /// Always asks first. Removing a tile re-plans the whole mosaic, so a mis-tap on
  /// a 56px thumbnail visibly rearranges the picture — cheap to undo only if you
  /// still have the photo to hand.
  Future<void> _removeTile(String id) async {
    final ok = await confirmDestructive(
      context,
      title: 'Remove this photo?',
      message:
          'It will no longer be used in your mosaic. You can add it again later.',
    );
    if (!ok) return;
    _controller.removeTile(id);
    _controller.buildPlan();
  }

  /// Open the crop editor for one tile, seeded with its CURRENT crop, and apply
  /// whatever comes back.
  ///
  /// No replan on a crop change: cropping does not affect which tile is matched to
  /// which cell, only how that tile is drawn, so the painters simply repaint. A
  /// removal does need one — the tile is gone from the library.
  Future<void> _onCropTile(BuildContext context, TileAsset tile) async {
    final studio = ref.read(studioControllerProvider);
    final result = await Navigator.of(context).push<TileCropResult>(
      MaterialPageRoute(
        builder: (_) => TileCropScreen(
          image: tile.thumbnail,
          title: tile.filename,
          initial: studio.tileCrops[studio.cropSlotFor(tile.id)],
          cropPortraitTop: studio.settings.mosaicMode == 'square',
          // The editor frames the cell this tile will actually land in — see
          // StudioState.cropAspectFor.
          cellAspect: studio.cropAspectFor(tile.id),
          cellShape: studio.cropShape,
        ),
      ),
    );
    if (result == null) return;
    if (result.removed) {
      // The editor already asked — going through _removeTile would prompt twice.
      _controller.removeTile(tile.id);
      _controller.buildPlan();
      return;
    }
    _controller.setTileCrop(tile.id, result.cleared ? null : result.crop);
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
        title: Text('Export', style: AppTypography.title),
        content: Text(
          AppConfig.freeRenders
              ? 'Export renders your mosaic at full resolution on our servers '
                  'and saves it to your device. Designing, previewing, and '
                  'creating videos are all free too.'
              : 'Each full-quality export renders your mosaic at high resolution '
                  'on our servers and costs 1 token. Designing, previewing, and '
                  'creating videos are all free — tokens are only used at export.',
          style: AppTypography.body,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  /// The placement (tile cell) covering base-space point ([x], [y]), or null.
  SlimPlacement? _placementAt(SlimMosaicPlan plan, double x, double y) {
    for (final p in plan.placements) {
      if (x >= p.x &&
          x < p.x + p.width &&
          y >= p.y &&
          y < p.y + p.height) {
        return p;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Surface upload/picker/restore failures instead of swallowing them.
    ref.listen(studioControllerProvider.select((s) => s.error), (_, err) {
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 8),
        ));
      }
    });


    final studio = ref.watch(studioControllerProvider);
    final canRender = ref.watch(canRenderProvider);
    final rendering = ref.watch(renderControllerProvider
        .select((s) => s.phase == RenderPhase.rendering));
    final settings = studio.settings;
    final isAncientCurved = settings.mosaicMode == 'ancient-curved';
    final isAncient = settings.mosaicMode == 'ancient' || isAncientCurved;
    final isWordart = settings.mosaicMode == 'wordart';
    // Tile-less modes (ancient shapes + word art): no tile plan; render/preview
    // themselves and export via the server (no tiles, no loupe, no tint slider).
    final isTileless = isAncient || isWordart;

    void update(MosaicSettings s) => _controller.updateSettings(s);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Studio'),
        actions: [
          IconButton(
            tooltip: AppConfig.freeRenders
                ? 'About export'
                : 'About export & tokens',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showTokenInfo(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Busy banner (restore / tile upload) — visible immediately ──
            if (studio.isRestoring || studio.isUploadingTiles)
              _BusyBanner(
                label: studio.isRestoring
                    ? 'Restoring project…'
                    : 'Adding photos…',
                done: studio.uploadDone,
                total: studio.uploadTotal,
              ),
            // ── Preview + controls, with a collapsing preview ──────────────
            //
            // Scrolling DOWN through the settings shrinks the preview instead of
            // pushing it off-screen; scrolling up — or touching any setting — grows it
            // back. Same idea as composing an Instagram post: the picture stays in
            // view while you work, but yields room when you are reading rather than
            // looking. See `_previewCollapse` / `_onSettingsScroll`.
            //
            // The Column is rebuilt per tick because Expanded must be a DIRECT child
            // of a Flex, so the split cannot be animated from further down the tree.
            // That is cheap: the subtrees are the same widgets with the same values,
            // so the painters' shouldRepaint returns false and only layout re-runs.
            Expanded(
              child: AnimatedBuilder(
                animation: _previewCollapse,
                builder: (context, _) {
                  // A 1000-unit flex so the split slides smoothly rather than
                  // stepping between whole 6/4 ratios.
                  final t =
                      Curves.easeOutCubic.transform(_previewCollapse.value);
                  final previewFlex = (600 - _collapseTravel * t).round();
                  return Column(
                    children: [
                  // ── Preview — pinch to zoom, drag to pan ──
                  Expanded(
                    flex: previewFlex,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final plan = studio.plan;
                      final box = constraints.biggest;
                      // Screen px per base px at the current zoom. `fit.scale` is the
                      // contained-at-zoom-1 scale, so this agrees with the untouched
                      // preview exactly when _zoom == 1.
                      final fit = plan == null
                          ? null
                          : computeMosaicFit(
                              box, plan.baseWidth, plan.baseHeight);
                      final zoomScale = fit == null ? 1.0 : fit.scale * _zoom;
                      final zoomed = plan != null && !isTileless && _zoom > 1.001;
                      final winW = fit == null ? 0.0 : box.width / zoomScale;
                      final winH = fit == null ? 0.0 : box.height / zoomScale;
                      final focus = (plan == null)
                          ? Offset.zero
                          : _clampFocus(
                              _focusBase ??
                                  Offset(plan.baseWidth / 2, plan.baseHeight / 2),
                              winW,
                              winH,
                              plan);

                      return GestureDetector(
                        // Tap no longer zooms — pinch does. Collapsed, it gives the
                        // picture back; expanded, it answers "which photo is that?" by
                        // highlighting the cell's tile in the strip. Two meanings, but
                        // they never compete: when the preview is squeezed the only
                        // thing anyone wants from it is to see it again.
                        //
                        // ONE mapping for every zoom level: the zoom transform below
                        // collapses to the fitted one at zoom 1 (asserted in
                        // preview_zoom_seam_test), so there is no separate fitted-view
                        // case to keep in step.
                        onTapUp: (isTileless || plan == null)
                            ? null
                            : (details) {
                                if (!_previewCollapse.isDismissed) {
                                  _expandPreview();
                                  return;
                                }
                                final sc = fit!.scale * _zoom;
                                final ox = box.width / 2 - focus.dx * sc;
                                final oy = box.height / 2 - focus.dy * sc;
                                final bx =
                                    (details.localPosition.dx - ox) / sc;
                                final by =
                                    (details.localPosition.dy - oy) / sc;
                                if (bx < 0 ||
                                    by < 0 ||
                                    bx > plan.baseWidth ||
                                    by > plan.baseHeight) {
                                  return;
                                }
                                final hit = _placementAt(plan, bx, by);
                                if (hit != null) _revealTile(hit.tileId);
                              },
                        // Double-tap back to the whole picture — the way out of a zoom
                        // that a pinch alone makes fiddly to reverse.
                        onDoubleTap:
                            (isTileless || plan == null) ? null : _resetZoom,
                        onScaleStart: (isTileless || plan == null)
                            ? null
                            : (_) => _zoomAtGestureStart = _zoom,
                        onScaleUpdate: (isTileless || plan == null)
                            ? null
                            : (d) {
                                setState(() {
                                  if (d.scale != 1.0) {
                                    _zoom = (_zoomAtGestureStart * d.scale)
                                        .clamp(1.0, _maxZoom);
                                  }
                                  // Pan in BASE pixels so a drag tracks the finger at
                                  // every zoom level.
                                  final sc = fit!.scale * _zoom;
                                  final w = box.width / sc, h = box.height / sc;
                                  _focusBase = _clampFocus(
                                    (_focusBase ??
                                            Offset(plan.baseWidth / 2,
                                                plan.baseHeight / 2)) -
                                        d.focalPointDelta / sc,
                                    w,
                                    h,
                                    plan,
                                  );
                                });
                              },
                        child: Container(
                          width: double.infinity,
                          color: AppColors.background,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (isAncient)
                                (studio.base != null
                                    ? AncientPreview(
                                        base: studio.base!,
                                        params: ancientParamsFromState(studio,
                                            curved: isAncientCurved),
                                      )
                                    : Center(
                                        child: Text('Add a base photo',
                                            style: AppTypography.body.copyWith(
                                                color: AppColors.textSecondary))))
                              else if (isWordart)
                                (studio.base != null
                                    ? WordArtPreview(
                                        base: studio.base!,
                                        params: wordartParamsFromState(studio),
                                      )
                                    : Center(
                                        child: Text('Add a base photo',
                                            style: AppTypography.body.copyWith(
                                                color: AppColors.textSecondary))))
                              else if (plan != null && zoomed)
                                // Same painter the loupe uses, so the zoomed view and
                                // the loupe agree on crop, tint and saturation.
                                CustomPaint(
                                  painter: MosaicZoomPainter(
                                    plan: plan,
                                    tileImages: studio.tileImages,
                                    baseImage: studio.base?.overlay,
                                    tintStrength: settings.tintStrength,
                                    outputSaturation: settings.outputSaturation,
                                    focusX: focus.dx,
                                    focusY: focus.dy,
                                    windowSize: winW,
                                  ),
                                )
                              else if (plan != null)
                                _AnimatedMosaicPreview(
                                  plan: plan,
                                  tileImages: studio.tileImages,
                                  baseImage: studio.base?.overlay,
                                  tintStrength: settings.tintStrength,
                                  outputSaturation: settings.outputSaturation,
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
                              if ((isTileless && studio.base != null) ||
                                  (!isTileless && plan != null))
                                Positioned(
                                  bottom: AppSpacing.x2,
                                  right: AppSpacing.x2,
                                  // Swaps to the way OUT once the preview is squeezed.
                                  // "Pinch to zoom" is advice for a picture you can
                                  // see; shrunk, the only question is how to get it
                                  // back, and a bare grabber does not answer that
                                  // clearly enough to be the only answer.
                                  child: t > 0.35
                                      ? _ExpandPreviewButton(onTap: _expandPreview)
                                      : const _Hint(text: 'Pinch to zoom'),
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
                    flex: 1000 - previewFlex,
                    child: Container(
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
                        ),
                        child: Column(
                          children: [
                            // ── Grabber ────────────────────────────────────────
                            //
                            // Marks the seam between the picture and the controls, and
                            // gives the collapse a handle. It is deliberately a REAL
                            // control: a grabber that cannot be grabbed is a small lie,
                            // and tapping it is the quickest way to trade preview height
                            // for settings room without scrolling for it.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _previewCollapse.isDismissed
                                  ? _previewCollapse.forward()
                                  : _previewCollapse.reverse(),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: AppSpacing.x2),
                                child: Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      // Soft grey rather than the hairline border colour:
                                      // against this surface a border-toned pill reads as
                                      // a scratch on the screen rather than a handle.
                                      color: AppColors.textSecondary
                                          .withValues(alpha: 0.28),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: ListView(
                                controller: _settingsScroll,
                                // Top padding halved — the grabber above already provides it.
                                padding: const EdgeInsets.fromLTRB(AppSpacing.x4,
                                    AppSpacing.x2, AppSpacing.x4, AppSpacing.x4),
                                children: [
                                  _SourceAndTiles(
                                    studio: studio,
                                    onChangeBase: _changeBase,
                                    onAddTiles: _addTiles,
                                    onLoadSamples: _loadSamples,
                                    onRemoveTile: _removeTile,
                                    onCropTile: modeSupportsTileCrops(settings.mosaicMode)
                                        ? (t) => _onCropTile(context, t)
                                        : null,
                                    tilesScroll: _tilesScroll,
                                    highlightedTileId: _highlightedTileId,
                                    isAncient: isTileless,
                                  ),
                                  const Divider(
                                      color: AppColors.border, height: AppSpacing.x6),
                                  Text('Mode', style: AppTypography.label),
                                  const SizedBox(height: AppSpacing.x2),
                                  _buildModeGroups(settings, update),
                                  if (isAncient)
                                    _buildAncientPanel(studio, settings, update,
                                        curved: isAncientCurved),
                                  if (isWordart)
                                    _buildWordartPanel(studio, settings, update),
                                  if (!isTileless) ...[
                                    const SizedBox(height: AppSpacing.x4),
                                    LabeledSlider(
                                      label: 'Density',
                                      value: settings.density,
                                      min: 40,
                                      max: 500,
                                      onChanged: (v) => update(settings.copyWith(density: v)),
                                    ),
                                    // Variety dial retired — pinned to
                                    // fixedReusePenalty. Measured better than every
                                    // value of the old dial at every library size.
                                    LabeledSlider(
                                      label: 'Tint',
                                      value: settings.tintStrength,
                                      min: 0,
                                      max: 0.5,
                                      valueLabel: settings.tintStrength.toStringAsFixed(2),
                                      onChanged: (v) =>
                                          _controller.updateRenderParam(tintStrength: v),
                                    ),
                                    LabeledSlider(
                                      label: 'Saturation',
                                      value: settings.outputSaturation,
                                      min: minOutputSaturation,
                                      max: maxOutputSaturation,
                                      valueLabel:
                                          settings.outputSaturation.toStringAsFixed(2),
                                      onChanged: (v) =>
                                          _controller.updateRenderParam(outputSaturation: v),
                                    ),
                                    const Divider(
                                        color: AppColors.border, height: AppSpacing.x6),
                                    LabeledSlider(
                                      label: 'Color boost',
                                      value: settings.colorBoost,
                                      min: 1,
                                      max: 2,
                                      valueLabel: settings.colorBoost.toStringAsFixed(2),
                                      onChanged: (v) =>
                                          update(settings.copyWith(colorBoost: v)),
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
                                  ],
                                  // Actions live in the persistent bottom bar (see below).
                                  const SizedBox(height: AppSpacing.x2),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      // Persistent action bar — always reachable, doesn't scroll. Primary CTA
      // is "Order wall art" where prints are available (the monetised action;
      // digital export is free during the bridge); export + video are compact
      // secondary actions. Hidden until a mosaic plan exists.
      bottomNavigationBar: isTileless
          ? (studio.base == null
              ? null
              : Container(
                  color: AppColors.surface,
                  padding: const EdgeInsets.fromLTRB(AppSpacing.x4,
                      AppSpacing.x3, AppSpacing.x4, AppSpacing.x4),
                  child: SafeArea(
                    top: false,
                    child: PrimaryButton(
                      label: rendering ? 'Rendering…' : 'Export full quality',
                      loading: rendering,
                      icon: Icons.download,
                      onPressed: rendering ? null : _onTilelessExport,
                    ),
                  ),
                ))
          : (studio.plan == null
              ? null
              : _StudioActionBar(
                  rendering: rendering,
                  printAllowed: isPrintRegionAllowed(),
                  onExport:
                      rendering ? null : () => _onExport(context, canRender),
                  // The reel generator draws every cell as a RECTANGLE. That is right
                  // for the grid modes and wrong for the two shaped ones: a honeycomb
                  // or a cube wall would come out as floating rectangles with gaps
                  // between them, which reads as a broken render rather than a style.
                  // Disabled rather than shipped broken — the web has no hexagon video
                  // path either, so this is parity, not a regression.
                  onVideo: (settings.mosaicMode == 'rhombille' ||
                          settings.mosaicMode == 'hexagon')
                      ? null
                      : () {
                          ref.read(videoControllerProvider.notifier).reset();
                          context.push('/create/video');
                        },
                  onPrint: () => context.push('/create/wallart'),
                )),
    );
  }
}

/// Chip-style phrase input for word art (mirrors the web PhraseChips). Existing
/// phrases render as removable chips; a single-line field appends a new one.
/// Enter adds + dismisses the keyboard; the "Add" button adds and keeps the
/// keyboard up for rapid entry. Phrases are stored as a newline-joined blob in
/// [textInput] (multi-word phrases are kept whole — the separator is the line).
class _PhraseChipsField extends StatefulWidget {
  const _PhraseChipsField({required this.textInput, required this.onChanged});

  final String textInput;
  final ValueChanged<String> onChanged;

  @override
  State<_PhraseChipsField> createState() => _PhraseChipsFieldState();
}

class _PhraseChipsFieldState extends State<_PhraseChipsField> {
  final TextEditingController _draft = TextEditingController();
  final FocusNode _focus = FocusNode();

  List<String> get _phrases => widget.textInput
      .split('\n')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  void _add(String raw) {
    final phrases = _phrases;
    var added = false;
    // A paste may hold several lines — add each new, non-duplicate phrase.
    for (final line in raw.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      if (phrases.any((p) => p.toLowerCase() == s.toLowerCase())) continue;
      phrases.add(s);
      added = true;
    }
    _draft.clear();
    if (added) widget.onChanged(phrases.join('\n'));
  }

  void _removeAt(int i) {
    final phrases = _phrases;
    if (i < 0 || i >= phrases.length) return;
    phrases.removeAt(i);
    widget.onChanged(phrases.join('\n'));
  }

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phrases = _phrases;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (phrases.isNotEmpty) ...[
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              for (var i = 0; i < phrases.length; i++)
                Chip(
                  label: Text(phrases[i], style: AppTypography.caption),
                  onDeleted: () => _removeAt(i),
                  deleteIcon: const Icon(Icons.close, size: 15),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  backgroundColor: AppColors.background,
                  side: const BorderSide(color: AppColors.border),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _draft,
                focusNode: _focus,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                style: AppTypography.body,
                // Enter adds AND lets the keyboard close (single line, no re-focus).
                onSubmitted: _add,
                decoration: InputDecoration(
                  hintText: phrases.isEmpty
                      ? 'Type a word or phrase…'
                      : 'Add another…',
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      borderSide: const BorderSide(color: AppColors.border)),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            OutlinedButton(
              // Add keeps focus so several can be entered without re-tapping.
              onPressed: () {
                _add(_draft.text);
                _focus.requestFocus();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.border),
                minimumSize: const Size(0, 46),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }
}

/// One tile thumbnail, drawn through the SAME source-rect rule the mosaic uses —
/// manual crop when there is one, the automatic cover-crop otherwise. Drawing it any
/// other way would make the strip disagree with the picture it describes.
class _TileThumbPainter extends CustomPainter {
  _TileThumbPainter({required this.image, this.crop, this.topCrop = false});

  final ui.Image image;
  final TileCrop? crop;
  final bool topCrop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      // Square thumbnail → cell aspect 1, the same as a square-mode cell.
      centerCropSrc(image, 1, topCrop: topCrop, crop: crop),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _TileThumbPainter old) =>
      old.crop != crop || old.image != image || old.topCrop != topCrop;
}

/// Base-photo + tile management strip shown at the top of the controls panel.
class _SourceAndTiles extends StatelessWidget {
  const _SourceAndTiles({
    required this.studio,
    required this.onChangeBase,
    required this.onAddTiles,
    required this.onLoadSamples,
    required this.onRemoveTile,
    required this.tilesScroll,
    required this.highlightedTileId,
    this.onCropTile,
    this.isAncient = false,
  });

  final StudioState studio;
  final VoidCallback onChangeBase;
  final VoidCallback onAddTiles;
  final VoidCallback onLoadSamples;
  final void Function(String id) onRemoveTile;
  final ScrollController tilesScroll;
  final String? highlightedTileId;

  /// Opens the crop editor for a tile. Null outside square mode — the only mode
  /// with per-tile crops, mirroring the web. When it is set the thumbnail itself
  /// becomes the control and the ✕ goes away: anything painted on top hides the
  /// very thing the thumbnail exists to show, and on touch it cannot hide behind a
  /// hover. Removal moves into the editor, next to the tile's other actions.
  final void Function(TileAsset tile)? onCropTile;

  /// Tile-less modes (ancient / word art) use no tiles at all — the whole tiles
  /// section is hidden.
  final bool isAncient;

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
        if (!isAncient) ...[
        const SizedBox(height: AppSpacing.x2),
        Row(
          children: [
            Text('Tiles (${studio.tiles.length})', style: AppTypography.label),
            const Spacer(),
            TextButton.icon(
              onPressed: studio.isUploadingTiles ? null : onLoadSamples,
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('Samples'),
            ),
            TextButton.icon(
              onPressed: studio.isUploadingTiles ? null : onAddTiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        if (onCropTile != null && studio.tiles.isNotEmpty) ...[
          Text('Tap a photo to crop or remove it',
              style: AppTypography.caption),
          const SizedBox(height: AppSpacing.x1),
        ],
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
                  controller: tilesScroll,
                  scrollDirection: Axis.horizontal,
                  itemCount: studio.tiles.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.x2),
                  itemBuilder: (context, i) {
                    final tile = studio.tiles[i];
                    final highlighted = tile.id == highlightedTileId;
                    // Slot-keyed, not id-keyed: in a non-square mode the bare id
                    // holds the SQUARE crop, so the strip would contradict the mosaic.
                    final crop =
                        studio.tileCrops[studio.cropSlotFor(tile.id)];
                    return Stack(
                      children: [
                        // The thumbnail is framed exactly as the mosaic will use
                        // it, so the strip answers "what did I set for this tile?"
                        // at a glance — automatic crop included.
                        GestureDetector(
                          onTap: onCropTile == null
                              ? null
                              : () => onCropTile!(tile),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                            child: CustomPaint(
                              size: const Size(56, 56),
                              painter: _TileThumbPainter(
                                image: tile.thumbnail,
                                crop: crop,
                                topCrop: studio.settings.mosaicMode == 'square',
                              ),
                            ),
                          ),
                        ),
                        if (crop != null)
                          // The only "this is cropped" signal: a hairline inset
                          // ring, on the edge rather than over the picture.
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.chip),
                                  border: Border.all(
                                      color: AppColors.accent.withValues(
                                          alpha: 0.45)),
                                ),
                              ),
                            ),
                          ),
                        // Highlight ring (overlay — doesn't affect item size).
                        Positioned.fill(
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: highlighted ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.chip),
                                  border: Border.all(
                                      color: AppColors.accent, width: 2),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (onCropTile != null)
                          // Tapping opens the editor, where Reset and "Remove photo"
                          // live — the same arrangement the web uses, so the two
                          // platforms teach the same gesture.
                          Positioned(
                            bottom: 2,
                            right: 2,
                            child: IgnorePointer(
                              child: Container(
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                padding: const EdgeInsets.all(2),
                                child: const Icon(Icons.crop,
                                    size: 11, color: Colors.white),
                              ),
                            ),
                          ),
                        if (onCropTile == null)
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
      ],
    );
  }
}

/// Mosaic preview with motion. The first plan plays the full tile-drift reveal;
/// later *committed* config changes (density / variety / mode — each already
/// debounced to rest, and each producing a new plan object) cross-dissolve via
/// the [AnimatedSwitcher]. Tint/blur mutate the same plan object (no new key),
/// so they repaint instantly with no fade.
///
/// The ticker lives in [_PlanLayer] (a plain StatefulWidget), deliberately NOT
/// on the screen's ConsumerState — a ticker there would let TickerMode changes
/// during route transitions resume Riverpod subscriptions mid-build and crash.
class _AnimatedMosaicPreview extends StatefulWidget {
  const _AnimatedMosaicPreview({
    required this.plan,
    required this.tileImages,
    required this.baseImage,
    required this.tintStrength,
    required this.outputSaturation,
  });

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;
  final double tintStrength;
  final double outputSaturation;

  @override
  State<_AnimatedMosaicPreview> createState() => _AnimatedMosaicPreviewState();
}

class _AnimatedMosaicPreviewState extends State<_AnimatedMosaicPreview> {
  bool _first = true;

  @override
  Widget build(BuildContext context) {
    // The very first plan drifts in; every plan after it cross-fades.
    final reveal = _first;
    _first = false;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      // Stack the outgoing arrangement under the incoming one for a true
      // cross-dissolve (both fill the preview area).
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, ?current],
      ),
      child: _PlanLayer(
        key: ValueKey(widget.plan),
        plan: widget.plan,
        tileImages: widget.tileImages,
        baseImage: widget.baseImage,
        tintStrength: widget.tintStrength,
        outputSaturation: widget.outputSaturation,
        reveal: reveal,
      ),
    );
  }
}

/// One painted mosaic arrangement. When [reveal] it owns a controller and plays
/// the staggered tile-drift; otherwise it paints fully assembled and lets the
/// parent [AnimatedSwitcher] fade it in.
class _PlanLayer extends StatefulWidget {
  const _PlanLayer({
    super.key,
    required this.plan,
    required this.tileImages,
    required this.baseImage,
    required this.tintStrength,
    required this.outputSaturation,
    required this.reveal,
  });

  final SlimMosaicPlan plan;
  final Map<String, ui.Image> tileImages;
  final ui.Image? baseImage;
  final double tintStrength;
  final double outputSaturation;
  final bool reveal;

  @override
  State<_PlanLayer> createState() => _PlanLayerState();
}

class _PlanLayerState extends State<_PlanLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _drift;

  @override
  void initState() {
    super.initState();
    if (widget.reveal) {
      _drift = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      )..forward();
      Haptics.selection();
    }
  }

  @override
  void dispose() {
    _drift?.dispose();
    super.dispose();
  }

  Widget _paint(double appear) => CustomPaint(
        painter: MosaicPreviewPainter(
          plan: widget.plan,
          tileImages: widget.tileImages,
          baseImage: widget.baseImage,
          tintStrength: widget.tintStrength,
          outputSaturation: widget.outputSaturation,
          appear: appear,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final drift = _drift;
    if (drift == null) return _paint(1);
    return AnimatedBuilder(
      animation: drift,
      builder: (_, _) => _paint(drift.value),
    );
  }
}

/// Thin progress banner under the app bar while restoring a project or adding
/// tiles. Shows an indeterminate bar until [total] is known, then a count.
class _BusyBanner extends StatelessWidget {
  const _BusyBanner({
    required this.label,
    required this.done,
    required this.total,
  });

  final String label;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    // Show an animated loader until the first item lands, then a real bar.
    final hasProgress = done > 0 && total > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen, AppSpacing.x3, AppSpacing.screen, AppSpacing.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hasProgress ? '$label $done/$total' : label,
              style: AppTypography.caption),
          const SizedBox(height: AppSpacing.x2),
          hasProgress
              ? AppProgressBar(percent: done / total * 100)
              : const AppIndeterminateBar(),
        ],
      ),
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

/// Persistent studio action bar. Print is the primary CTA where available
/// (the monetised action; digital export is free during the bridge); export +
/// video are compact secondary actions. Always visible, doesn't scroll.
class _StudioActionBar extends StatelessWidget {
  const _StudioActionBar({
    required this.rendering,
    required this.printAllowed,
    required this.onExport,
    required this.onVideo,
    required this.onPrint,
  });

  final bool rendering;
  final bool printAllowed;
  final VoidCallback? onExport;
  /// Null when the current mode has no video path — see the note at the call site.
  final VoidCallback? onVideo;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final exportLabel = AppConfig.freeRenders ? 'Export' : 'Export (1)';
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
          child: Row(
            children: [
              if (printAllowed) ...[
                _ActionIcon(
                  icon: Icons.download_outlined,
                  label: exportLabel,
                  busy: rendering,
                  onPressed: onExport,
                ),
                const SizedBox(width: AppSpacing.x2),
              ],
              _ActionIcon(
                icon: Icons.movie_creation_outlined,
                label: 'Video',
                onPressed: onVideo,
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: printAllowed
                    ? PrimaryButton(
                        label: 'Order wall art',
                        icon: Icons.image_outlined,
                        onPressed: onPrint,
                      )
                    : PrimaryButton(
                        label: rendering
                            ? 'Rendering…'
                            : (AppConfig.freeRenders
                                ? 'Export full quality'
                                : 'Export full quality (1)'),
                        onPressed: onExport,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact secondary action: icon + small label in a bordered square.
class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final color = disabled ? AppColors.textMuted : AppColors.textSecondary;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 60,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.accent),
                  )
                : Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(label,
                style: AppTypography.caption.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// In-artwork photo title ("caption") field for word art: an optional line baked
/// bottom-left into the word field, plus a colour choice (Auto = sampled from
/// the photo at that spot, or one of a few swatches pulled from the base photo).
/// Mirrors the web word-art panel's photo-title control.
class _CaptionField extends StatefulWidget {
  const _CaptionField({
    required this.base,
    required this.caption,
    required this.captionColor,
    required this.onCaptionChanged,
    required this.onColorChanged,
  });

  final ui.Image? base;
  final String caption;
  final String captionColor; // "" = auto/from photo
  final ValueChanged<String> onCaptionChanged;
  final ValueChanged<String> onColorChanged;

  @override
  State<_CaptionField> createState() => _CaptionFieldState();
}

class _CaptionFieldState extends State<_CaptionField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.caption);
  List<String> _swatches = const [];
  // The title is baked into the whole word field, so committing it re-packs the
  // (expensive) layout. Debounce keystrokes and commit on a pause / submit —
  // never on every letter.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadSwatches();
  }

  @override
  void didUpdateWidget(_CaptionField old) {
    super.didUpdateWidget(old);
    // Keep the field in sync if the caption is changed elsewhere (e.g. reset).
    if (widget.caption != _text.text && widget.caption != old.caption) {
      _text.text = widget.caption;
    }
    if (old.base != widget.base) _loadSwatches();
  }

  Future<void> _loadSwatches() async {
    final img = widget.base;
    if (img == null) {
      if (_swatches.isNotEmpty) setState(() => _swatches = const []);
      return;
    }
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted || data == null) return;
    final swatches = suggestColorsFromRgba(
        data.buffer.asUint8List(), img.width, img.height,
        count: 6);
    if (mounted) setState(() => _swatches = swatches);
  }

  static Color? _parseHex(String hex) {
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
    if (m == null) return null;
    return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
  }

  void _commit(String v) {
    _debounce?.cancel();
    widget.onCaptionChanged(v);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCaption = widget.caption.trim().isNotEmpty;
    final selected = widget.captionColor.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Photo title (optional)', style: AppTypography.caption),
        const SizedBox(height: AppSpacing.x1),
        TextField(
          controller: _text,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.characters,
          style: AppTypography.body,
          onChanged: (v) {
            _debounce?.cancel();
            _debounce =
                Timer(const Duration(milliseconds: 450), () => _commit(v));
          },
          onSubmitted: _commit,
          decoration: InputDecoration(
            hintText: 'e.g. a name or a place',
            isDense: true,
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
                borderSide: const BorderSide(color: AppColors.border)),
          ),
        ),
        if (hasCaption) ...[
          const SizedBox(height: AppSpacing.x2),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _AutoColorChip(
                selected: selected.isEmpty,
                onTap: () => widget.onColorChanged(''),
              ),
              for (final hex in _swatches)
                _SwatchDot(
                  color: _parseHex(hex) ?? AppColors.textPrimary,
                  selected: selected == hex.toLowerCase(),
                  onTap: () => widget.onColorChanged(hex),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Auto" colour chip — title colour is sampled from the photo at the title's
/// position (the default).
class _AutoColorChip extends StatelessWidget {
  const _AutoColorChip({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text('Auto',
            style: AppTypography.caption.copyWith(
                color: selected ? AppColors.accent : AppColors.textSecondary)),
      ),
    );
  }
}

/// A single photo-derived colour swatch for the title colour.
class _SwatchDot extends StatelessWidget {
  const _SwatchDot(
      {required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}
