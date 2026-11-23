import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../api/funnel_api.dart';
import '../../mosaic/hires_tiles.dart';
import '../../mosaic/preview_painter.dart' show sharperTile;
import '../../mosaic/recolor_bake.dart';
import '../../services/iap_service.dart';
import '../../state/auth_controller.dart';
import '../../state/features_providers.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/primary_button.dart';
import '../../wordart/wordart_renderer.dart';
import 'mosaic_inspector.dart';
import 'wordart_preview.dart' show wordartParamsFromState;

const _singleProductId = 'com.imagiastore.studio.tokens.single';

/// Physical size of one logical pixel (Flutter's density-independent unit: 1/163 in on
/// iOS, 1/160 in on Android).
double get _cmPerLogicalPx => 2.54 / (Platform.isIOS ? 163 : 160);

/// The export paywall (no tokens): the user's own design framed on a wall + a 100% crop
/// (photo mosaic) or a phone wallpaper (word art), what the export contains, a one-tap
/// in-app purchase that continues straight to the export. Same idea as the web purchase
/// popup. (The free small version was removed on 2026-11-23, on the web too.)
///
/// Returns true when the user bought a token here (the caller then starts the export).
Future<bool> showExportPaywall(BuildContext context, WidgetRef ref) async {
  final unlocked = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _ExportPaywall(),
  );
  return unlocked == true;
}

class _ExportPaywall extends ConsumerStatefulWidget {
  const _ExportPaywall();

  @override
  ConsumerState<_ExportPaywall> createState() => _ExportPaywallState();
}

class _ExportPaywallState extends ConsumerState<_ExportPaywall> {
  late final String _mode;
  late final bool _wordArt, _photo;
  ui.Image? _preview;
  ProductDetails? _single;
  bool _iapReady = false, _buying = false, _paid = false;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  // Sharp copies of the photos for the inspector's zoomed views (photo mosaics only).
  HiResTiles? _hr;
  /// The exact pixel size of the paid file, once known (shown instead of "full resolution").
  Size? _exportSize;

  @override
  void initState() {
    super.initState();
    final s = ref.read(studioControllerProvider);
    _mode = s.settings.mosaicMode;
    _wordArt = _mode == 'wordart';
    _photo = !_wordArt && s.plan != null && _mode != 'collage';
    trackFunnel(ref, 'purchase_modal_shown', mode: _mode);
    if (_photo) {
      final ctl = ref.read(studioControllerProvider.notifier);
      _hr = HiResTiles(
        fetch: (id) async {
          for (final t in ref.read(studioControllerProvider).tiles) {
            if (t.id == id) return ctl.tilePhotoBytes(t.blobUrl);
          }
          return null;
        },
      );
    }
    unawaited(_loadPictures());
    unawaited(_loadExportSize());
    unawaited(_initIap());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hr?.dispose();
    if (!_paid) trackFunnel(ref, 'purchase_modal_closed', mode: _mode);
    super.dispose();
  }

  // ── pictures ────────────────────────────────────────────────────────────────

  Future<void> _loadPictures() async {
    try {
      if (_photo) {
        final p = await _bakePhoto(800);
        if (mounted) setState(() => _preview = p);
      } else if (_wordArt) {
        final p = await _renderWordArt(800);
        if (mounted) setState(() => _preview = p);
      }
    } catch (_) {
      /* the sheet still works without the pictures */
    }
  }

  /// The photo mosaic exactly as the studio shows it (tiles + recolour + grade).
  Future<ui.Image?> _bakePhoto(double longSide, {Rect? win}) async {
    final s = ref.read(studioControllerProvider);
    final plan = s.plan;
    if (plan == null) return null;
    final w = win ?? Rect.fromLTWH(0, 0, plan.baseWidth, plan.baseHeight);
    final k = longSide / math.max(w.width, w.height);
    final tiles = s.tileImages;
    return bakeMosaicWindow(
      plan: plan,
      tileCrops: plan.tileCrops,
      imageFor: (p, _) => tiles[p.tileId],
      win: w,
      outW: math.max(1, (w.width * k).round()),
      outH: math.max(1, (w.height * k).round()),
      tileRecolor: s.settings.tileRecolor,
      outputSaturation: s.settings.outputSaturation,
      tintStrength: s.settings.tintStrength,
      overlay: s.base?.overlay,
    );
  }

  /// The inspector's baker: any window of the mosaic at any size, from the sharpest
  /// photo copies held (it asks for sharper ones as it goes).
  Future<ui.Image?> _bakeWindow(Rect win, int outW, int outH) async {
    final s = ref.read(studioControllerProvider);
    final plan = s.plan, hr = _hr;
    if (plan == null || hr == null) return null;
    final thumbs = s.tileImages;
    return bakeMosaicWindow(
      plan: plan,
      tileCrops: plan.tileCrops,
      imageFor: (p, need) {
        final thumb = thumbs[p.tileId];
        return thumb == null ? null : sharperTile(hr, p.tileId, thumb, need);
      },
      win: win,
      outW: outW,
      outH: outH,
      tileRecolor: s.settings.tileRecolor,
      outputSaturation: s.settings.outputSaturation,
      tintStrength: s.settings.tintStrength,
      overlay: s.base?.overlay,
    );
  }

  /// The word art exactly as the preview lays it out (same inputs as the export bake).
  Future<ui.Image?> _renderWordArt(double longSide) async {
    final studio = ref.read(studioControllerProvider);
    final base = studio.base;
    if (base == null) return null;
    final img = base.thumbnail;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final sw = img.width, sh = img.height;
    const previewLong = 1400.0; // must match wordart_preview._previewLong
    final scale = previewLong / math.max(sw, sh);
    final lw = (sw * scale).round(), lh = (sh * scale).round();
    if (lw < 2 || lh < 2) return null;
    final geo = await buildWordArtGeometryAsync(
      data.buffer.asUint8List(),
      sw,
      sh,
      lw.toDouble(),
      lh.toDouble(),
      wordartParamsFromState(studio),
    );
    final k = longSide / math.max(lw, lh);
    return renderWordArtCrop(
      geo,
      lw,
      lh,
      ui.Rect.fromLTWH(0, 0, lw.toDouble(), lh.toDouble()),
      math.max(1, (lw * k).round()),
      math.max(1, (lh * k).round()),
    );
  }

  /// Mirrors the export: photo modes = the server's in-app max resolution on the long
  /// side (render_controller `outputLongSide`), word art = 10,000 px.
  Future<void> _loadExportSize() async {
    try {
      final s = ref.read(studioControllerProvider);
      double? aspect;
      int? long;
      if (_wordArt && s.base != null) {
        aspect = s.base!.thumbnail.width / s.base!.thumbnail.height;
        long = 10000;
      } else if (_photo && s.plan != null) {
        aspect = s.plan!.baseWidth / s.plan!.baseHeight;
        long = await ref.read(maxResolutionProvider.future);
      }
      if (aspect == null || long == null || long <= 0 || !mounted) return;
      final size = aspect >= 1
          ? Size(long.toDouble(), math.max(1, (long / aspect).roundToDouble()))
          : Size(math.max(1, (long * aspect).roundToDouble()), long.toDouble());
      setState(() => _exportSize = size);
    } catch (_) {
      /* keep the generic wording */
    }
  }

  static String _px(double v) => v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  // ── purchase ────────────────────────────────────────────────────────────────

  Future<void> _initIap() async {
    final iap = ref.read(iapServiceProvider);
    _sub = iap.purchaseStream.listen(_onPurchases, onError: (_) {});
    try {
      if (!await iap.available()) return;
      final products = await iap.loadProducts();
      final single = products.where((p) => p.id == _singleProductId);
      if (mounted) {
        setState(() {
          _single = single.isEmpty ? null : single.first;
          _iapReady = true;
        });
      }
    } catch (_) {
      /* falls back to the token packs screen */
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    final iap = ref.read(iapServiceProvider);
    for (final p in purchases) {
      if (p.productID != _singleProductId) continue;
      switch (p.status) {
        case PurchaseStatus.pending:
          if (mounted) setState(() => _buying = true);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            await iap.verifyAndComplete(p);
            await ref.read(authControllerProvider.notifier).refreshUser();
            _paid = true;
            if (mounted) Navigator.of(context).pop(true);
          } catch (e) {
            _snack('Purchase verification failed — please try again.');
            if (mounted) setState(() => _buying = false);
          }
        case PurchaseStatus.error:
          await iap.complete(p);
          _snack(p.error?.message ?? 'Purchase failed.');
          if (mounted) setState(() => _buying = false);
        case PurchaseStatus.canceled:
          if (mounted) setState(() => _buying = false);
      }
    }
  }

  Future<void> _buy() async {
    trackFunnel(ref, 'checkout_click', mode: _mode);
    final single = _single;
    if (single == null) {
      // Store not reachable / product missing: the full token screen handles it.
      Navigator.of(context).pop(false);
      if (mounted) context.push('/account');
      return;
    }
    setState(() => _buying = true);
    try {
      await ref.read(iapServiceProvider).buy(single);
    } catch (_) {
      _snack('Could not start the purchase.');
      if (mounted) setState(() => _buying = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final price = _single?.price;
    final what = _wordArt ? 'print-quality files' : 'HD mosaic';
    final title = _wordArt
        ? 'Your word art, ready to print'
        : _photo
        ? 'Your mosaic, in full detail'
        : 'Export in full quality';
    final subtitle = _wordArt
        ? 'Sharp at any size — for a poster, a canvas or a gift.'
        : _photo
        ? 'Print-sharp, and every tile is one of your photos.'
        : 'Rendered at high resolution and saved to your device.';
    final size = _exportSize;
    final dims = size == null ? null : '${_px(size.width)} × ${_px(size.height)} px';
    final perks = _wordArt
        ? [dims != null ? '$dims JPG — sharp even on a big poster' : 'Full-resolution JPG — sharp even on a big poster', 'Print-ready PDF', 'Vector SVG — scales to any size']
        : _photo
        ? [dims != null ? '$dims — sharp even as a big print' : 'Full-resolution file — sharp even as a big print', 'Every tile is a real photo — zoom in anywhere', 'Saved to Photos and to your downloads']
        : const ['Full-resolution file', 'Saved to Photos and to your downloads'];
    final rich = _wordArt || _photo;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.x6, AppSpacing.x3, AppSpacing.x6, AppSpacing.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          // What is being sold: a digital file (the wall / print size only illustrate it).
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_download_outlined, size: 14, color: AppColors.accent),
                  const SizedBox(width: 5),
                  Text('Digital file', style: AppTypography.caption.copyWith(color: AppColors.accent, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(title, style: AppTypography.title, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.x1),
          Text(subtitle, style: AppTypography.caption, textAlign: TextAlign.center),
          if (_photo && _hr != null) ...[
            const SizedBox(height: AppSpacing.x4),
            MosaicInspector(
              planSize: Size(ref.read(studioControllerProvider).plan!.baseWidth, ref.read(studioControllerProvider).plan!.baseHeight),
              fileSize: _exportSize,
              whole: _preview,
              bake: _bakeWindow,
              sharperTiles: _hr!.version,
              cmPerLogicalPx: _cmPerLogicalPx,
            ),
          ] else if (rich) ...[
            const SizedBox(height: AppSpacing.x4),
            SizedBox(
              height: 190,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _Mockup(label: 'On your wall', child: _WallFrame(image: _preview))),
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(flex: 2, child: _Mockup(label: 'As a wallpaper', child: _Phone(image: _preview))),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.x4),
          for (final p in perks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_rounded, size: 18, color: AppColors.accent),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(child: Text(p, style: AppTypography.body)),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.x4),
          PrimaryButton(
            label: price != null ? 'Get $what · $price' : (_iapReady ? 'Get $what' : 'Get $what…'),
            loading: _buying,
            icon: Icons.download,
            onPressed: _buying ? null : _buy,
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            'Digital download.',
            style: AppTypography.caption.copyWith(color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: _buying
                ? null
                : () {
                    Navigator.of(context).pop(false);
                    context.push('/account');
                  },
            child: Text('Save with token packs', style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
          ),
        ],
      ),
    );
  }
}

class _Mockup extends StatelessWidget {
  const _Mockup({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(child: child),
      const SizedBox(height: 6),
      Text(label, style: AppTypography.caption),
    ],
  );
}

class _Img extends StatelessWidget {
  const _Img({required this.image, this.fit = BoxFit.contain});
  final ui.Image? image;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => image == null
      ? Container(color: AppColors.surfaceRaised)
      : RawImage(image: image, fit: fit, filterQuality: FilterQuality.medium);
}

/// Their picture in a dark frame with a white mat, on a warm wall.
class _WallFrame extends StatelessWidget {
  const _WallFrame({required this.image});
  final ui.Image? image;

  @override
  Widget build(BuildContext context) {
    final img = image;
    final ar = img == null ? 0.8 : img.width / img.height;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFEFE6DA), Color(0xFFD9CDBD)],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Center(
        child: AspectRatio(
          aspectRatio: ar,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              color: Color(0xFF2B2118),
              boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 8))],
            ),
            child: Container(color: Colors.white, padding: const EdgeInsets.all(5), child: _Img(image: img)),
          ),
        ),
      ),
    );
  }
}

/// Their picture as a phone wallpaper.
class _Phone extends StatelessWidget {
  const _Phone({required this.image});
  final ui.Image? image;

  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: 9 / 18,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF3A3F4B), width: 3),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Img(image: image, fit: BoxFit.cover),
            Align(
              alignment: const Alignment(0, -0.96),
              child: Container(width: 28, height: 6, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(3))),
            ),
          ],
        ),
      ),
    ),
  );
}
