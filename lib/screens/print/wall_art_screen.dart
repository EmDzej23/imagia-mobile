import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mosaic/preview_painter.dart';
import '../../print/mockup_painter.dart';
import '../../print/print_catalog.dart';
import '../../print/print_order_draft.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/pressable.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/segmented_selector.dart';
import 'crop_screen.dart';
import 'real_size_loupe_screen.dart';
import 'shipping_address_screen.dart';

/// Turn the current mosaic into wall art: pick a product type + orientation,
/// frame the crop, and preview it as a realistic mockup. (Ordering/checkout is
/// wired once the Prodigi catalog is live.)
class WallArtScreen extends ConsumerStatefulWidget {
  const WallArtScreen({super.key});

  @override
  ConsumerState<WallArtScreen> createState() => _WallArtScreenState();
}

class _WallArtScreenState extends ConsumerState<WallArtScreen> {
  ui.Image? _mosaic;
  String? _error;
  PrintType _type = PrintType.framedPrint;
  PrintOrientation _orientation = PrintOrientation.portrait;
  PrintOptionChoice? _option =
      printOption(PrintType.framedPrint)?.defaultChoice;
  ui.Rect? _cropSrc; // in mosaic pixels

  Color get _frameColor => _type == PrintType.framedPrint
      ? (_option?.swatch ?? const Color(0xFF1C1C1E))
      : const Color(0xFF1C1C1E);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _rasterize());
  }

  @override
  void dispose() {
    _mosaic?.dispose();
    super.dispose();
  }

  Future<void> _rasterize() async {
    final s = ref.read(studioControllerProvider);
    final plan = s.plan;
    if (plan == null) {
      setState(() => _error = 'Generate a mosaic preview first.');
      return;
    }
    try {
      const longer = 1800.0;
      final scale = longer / math.max(plan.baseWidth, plan.baseHeight);
      final w = (plan.baseWidth * scale).round();
      final h = (plan.baseHeight * scale).round();
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(
          rec, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      MosaicPreviewPainter(
        plan: plan,
        tileImages: s.tileImages,
        baseImage: s.base?.overlay,
        tintStrength: s.settings.tintStrength,
      ).paint(canvas, Size(w.toDouble(), h.toDouble()));
      final img = await rec.endRecording().toImage(w, h);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _mosaic = img;
        _orientation = orientationForAspect(w / h);
        _cropSrc = _centerCrop(img, printSpec(_type, _orientation).aspect);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  ui.Rect _centerCrop(ui.Image img, double aspect) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    if (iw / ih > aspect) {
      final w = ih * aspect;
      return ui.Rect.fromLTWH((iw - w) / 2, 0, w, ih);
    }
    final h = iw / aspect;
    return ui.Rect.fromLTWH(0, (ih - h) / 2, iw, h);
  }

  void _setOrientation(PrintOrientation o) {
    setState(() {
      _orientation = o;
      if (_mosaic != null) {
        _cropSrc = _centerCrop(_mosaic!, printSpec(_type, o).aspect);
      }
    });
  }

  void _setType(PrintType t) {
    setState(() {
      _type = t;
      _option = printOption(t)?.defaultChoice; // reset to the type's default
      // Different products have different aspects — re-fit the crop.
      if (_mosaic != null) {
        _cropSrc = _centerCrop(_mosaic!, printSpec(t, _orientation).aspect);
      }
    });
  }

  void _viewActualSize() {
    final img = _mosaic;
    final crop = _cropSrc;
    if (img == null || crop == null) return;
    final studio = ref.read(studioControllerProvider);
    final plan = studio.plan;
    if (plan == null) return;
    // Normalise the crop (in raster px) to 0..1 so the loupe can map it onto
    // the base-coordinate plan it renders directly.
    final cropN = Rect.fromLTWH(
      crop.left / img.width,
      crop.top / img.height,
      crop.width / img.width,
      crop.height / img.height,
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RealSizeLoupeScreen(
        plan: plan,
        tileImages: studio.tileImages,
        overlay: studio.base?.overlay,
        tintStrength: studio.settings.tintStrength,
        cropNormalized: cropN,
        printLongEdgeCm: printSpec(_type, _orientation).longEdgeCm,
      ),
    ));
  }

  Future<void> _adjustCrop() async {
    final img = _mosaic;
    if (img == null) return;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final initial = _cropSrc == null
        ? null
        : Rect.fromLTWH(_cropSrc!.left / iw, _cropSrc!.top / ih,
            _cropSrc!.width / iw, _cropSrc!.height / ih);
    final result = await Navigator.of(context).push<Rect>(MaterialPageRoute(
      builder: (_) => CropScreen(
          image: img, aspect: printSpec(_type, _orientation).aspect, initialCrop: initial),
    ));
    if (result != null && mounted) {
      setState(() => _cropSrc = ui.Rect.fromLTWH(result.left * iw,
          result.top * ih, result.width * iw, result.height * ih));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wall art')),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.x6),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: AppTypography.body
                          .copyWith(color: AppColors.textSecondary)),
                ),
              )
            : _mosaic == null
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.accent))
                : _content(),
      ),
    );
  }

  Widget _content() {
    final mosaic = _mosaic!;
    final crop = _cropSrc!;
    return Column(
      children: [
        // Mockup preview.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: CustomPaint(
              size: Size.infinite,
              painter: MockupPainter(
                mosaic: mosaic,
                cropSrc: crop,
                type: _type,
                aspect: printSpec(_type, _orientation).aspect,
                frameColor: _frameColor,
                canvasWrap:
                    _type == PrintType.canvas ? _option?.value : null,
              ),
            ),
          ),
        ),
        // Controls.
        Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 84,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: kAvailablePrintTypes.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: AppSpacing.x2),
                      itemBuilder: (_, i) {
                        final t = kAvailablePrintTypes[i];
                        return _TypeCard(
                          type: t,
                          orientation: _orientation,
                          selected: t == _type,
                          onTap: () => _setType(t),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  SegmentedSelector<PrintOrientation>(
                    selected: _orientation,
                    onSelected: _setOrientation,
                    options: [
                      for (final o in PrintOrientation.values)
                        SegmentOption(o, o.label),
                    ],
                  ),
                  // Product option (frame colour / canvas wrap / metal finish).
                  if (printOption(_type) case final opt?) ...[
                    const SizedBox(height: AppSpacing.x3),
                    Text('${opt.label}: ${_option?.label ?? ''}',
                        style: AppTypography.caption),
                    const SizedBox(height: AppSpacing.x2),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final c in opt.choices)
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: AppSpacing.x2),
                              child: _OptionChip(
                                choice: c,
                                selected: c.value == _option?.value,
                                onTap: () => setState(() => _option = c),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.x3),
                  Text(
                    '${_type.label} · ${printSpec(_type, _orientation).sizeLabel}\n${_type.blurb}',
                    style: AppTypography.caption,
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _viewActualSize,
                          icon: const Icon(Icons.zoom_in, size: 18),
                          label: const Text('Actual size'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _adjustCrop,
                          icon: const Icon(Icons.crop, size: 18),
                          label: const Text('Framing'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  PrimaryButton(
                    label:
                        'Order · €${printPriceEur(_type, _orientation).toStringAsFixed(0)}',
                    icon: Icons.shopping_bag_outlined,
                    onPressed: () {
                      final draft = PrintOrderDraft(
                        type: _type,
                        orientation: _orientation,
                        mosaic: mosaic,
                        cropSrc: crop,
                        priceEur: printPriceEur(_type, _orientation),
                        option: _option,
                      );
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ShippingAddressScreen(draft: draft),
                      ));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A product-option choice: a colour swatch (frame colours) or a labelled chip
/// (canvas wrap, metal finish).
class _OptionChip extends StatelessWidget {
  const _OptionChip(
      {required this.choice, required this.selected, required this.onTap});
  final PrintOptionChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (choice.swatch != null) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: choice.swatch,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(choice.label, style: AppTypography.caption),
      ),
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard(
      {required this.type,
      required this.orientation,
      required this.selected,
      required this.onTap});
  final PrintType type;
  final PrintOrientation orientation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onPressed: onTap,
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(AppSpacing.x3),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(type.label,
                style: AppTypography.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            Text('€${printPriceEur(type, orientation).toStringAsFixed(0)}',
                style: AppTypography.number(AppTypography.caption)
                    .copyWith(color: AppColors.accent)),
          ],
        ),
      ),
    );
  }
}
