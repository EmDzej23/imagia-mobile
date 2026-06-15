import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/print_api.dart';
import '../../print/mockup_painter.dart';
import '../../print/print_catalog.dart';
import '../../print/print_order_draft.dart';
import '../../print/wall_image_provider.dart';
import '../../state/print_job_controller.dart';
import '../../state/print_providers.dart';
import '../../state/studio_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_card.dart';
import '../../widgets/primary_button.dart';
import '../account/checkout_webview_screen.dart';
import 'order_processing_screen.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  const OrderReviewScreen(
      {super.key, required this.draft, required this.recipient});
  final PrintOrderDraft draft;
  final PrintRecipient recipient;

  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  bool _busy = false;
  String _step = '';

  Future<void> _pay() async {
    final studio = ref.read(studioControllerProvider);
    final plan = studio.plan;
    final base = studio.base;
    if (plan == null || base == null) {
      _snack('No mosaic to print.');
      return;
    }
    setState(() {
      _busy = true;
      _step = 'Starting checkout…';
    });
    try {
      // The print mosaic is rendered server-side after payment (no render
      // token), so we just send the design to checkout.
      final tileUrls = {for (final t in studio.tiles) t.id: t.blobUrl};
      final checkout = await ref.read(printApiProvider).checkout(
            productKey: widget.draft.productKey,
            sessionId: 'mobile-${DateTime.now().millisecondsSinceEpoch}',
            plan: plan.toJson(),
            tileUrls: tileUrls,
            baseUrl: base.blobUrl,
            cropRect: widget.draft.cropNormalized,
            recipient: widget.recipient,
            attributes: widget.draft.attributes,
          );
      if (!checkout.isOk || checkout.data == null) {
        throw checkout.error ?? 'Could not start checkout.';
      }
      if (!mounted) return;

      final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CheckoutWebviewScreen(
          checkoutUrl: checkout.data!.checkoutUrl,
          successPath: '/print-success',
        ),
      ));
      if (!mounted) return;
      if (paid != true) {
        setState(() {
          _busy = false;
          _step = '';
        });
        _snack('Payment was not completed.');
        return;
      }

      // Hand off to the global print job: it renders + submits the order and
      // survives leaving this screen. We jump to the processing screen (rooted
      // at the gallery) so the app-wide indicator can bring the user back.
      ref.read(printJobControllerProvider.notifier).start(
            orderId: checkout.data!.orderId,
            productName:
                '${widget.draft.type.label} · ${widget.draft.orientation.label}',
          );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OrderProcessingScreen()),
        (r) => r.isFirst,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = '';
      });
      _snack('$e');
    }
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m), duration: const Duration(seconds: 6)));
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final r = widget.recipient;

    return Scaffold(
      appBar: AppBar(title: const Text('Review order')),
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(AppSpacing.screen),
              children: [
                AspectRatio(
                  aspectRatio: 0.82,
                  child: AppCard(
                    clip: true,
                    child: CustomPaint(
                      painter: MockupPainter(
                        mosaic: d.mosaic,
                        cropSrc: d.cropSrc,
                        type: d.type,
                        aspect: d.aspect,
                        frameColor: d.frameColor,
                        canvasWrap: d.type == PrintType.canvas
                            ? d.option?.value
                            : null,
                        wall: ref.watch(wallImageProvider).asData?.value,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.x4),
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${d.type.label} · ${d.orientation.label}',
                          style: AppTypography.label),
                      Text(d.sizeLabel, style: AppTypography.caption),
                      const Divider(
                          color: AppColors.border, height: AppSpacing.x6),
                      Text('Ship to', style: AppTypography.caption),
                      const SizedBox(height: AppSpacing.x1),
                      Text(r.name, style: AppTypography.body),
                      Text(
                        '${r.address1}${r.address2 != null && r.address2!.isNotEmpty ? ', ${r.address2}' : ''}\n'
                        '${r.city}${r.stateCode != null && r.stateCode!.isNotEmpty ? ', ${r.stateCode}' : ''} ${r.zip}\n${r.countryCode}',
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x4),
                Row(
                  children: [
                    Text('Total', style: AppTypography.label),
                    const Spacer(),
                    Text('€${d.priceEur.toStringAsFixed(2)}',
                        style: AppTypography.number(AppTypography.title)
                            .copyWith(color: AppColors.accent)),
                  ],
                ),
                Text('VAT included · ships in 5–10 days',
                    style: AppTypography.caption),
                const SizedBox(height: AppSpacing.x6),
                PrimaryButton(
                  label: 'Pay €${d.priceEur.toStringAsFixed(2)}',
                  icon: Icons.lock_outline,
                  onPressed: _busy ? null : _pay,
                ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  'We print a high-resolution mosaic from your design — no render tokens are used.',
                  style: AppTypography.caption,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            if (_busy)
              ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: AppColors.accent),
                      const SizedBox(height: AppSpacing.x4),
                      Text(_step,
                          style: AppTypography.body
                              .copyWith(color: AppColors.textPrimary)),
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
