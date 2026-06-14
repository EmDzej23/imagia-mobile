import 'package:flutter/material.dart';

import '../../services/haptics.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/primary_button.dart';

/// First-run carousel: three slides introducing the mosaic flow, fronted by an
/// animated "mosaic assembling" hero. Pop with `true` when finished/skipped so
/// the caller can persist the seen flag.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _Slide {
  const _Slide(this.title, this.body, this.icon);
  final String title;
  final String body;
  final IconData icon;
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pager = PageController();
  int _page = 0;

  static const _slides = [
    _Slide('Turn photos into mosaics',
        'Recreate any picture out of hundreds of your own photos.',
        Icons.auto_awesome_mosaic),
    _Slide('Tune it live',
        'Adjust density and style and watch the mosaic rebuild in real time. Tap to zoom into the tiles.',
        Icons.tune),
    _Slide('Export & share',
        'Render in print-ready resolution, save to your photos, or make a free video to share.',
        Icons.ios_share),
  ];

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _finish() {
    Haptics.tap();
    Navigator.of(context).pop(true);
  }

  void _next() {
    if (_page >= _slides.length - 1) {
      _finish();
      return;
    }
    Haptics.selection();
    _pager.nextPage(
        duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _slides.length - 1;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: Text('Skip',
                    style: AppTypography.label
                        .copyWith(color: AppColors.textSecondary)),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pager,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _slides.length,
                itemBuilder: (context, i) {
                  final s = _slides[i];
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Replays the assemble animation each time it's shown.
                        _MosaicHero(
                            key: ValueKey(i == _page ? 'on-$i' : 'off-$i'),
                            icon: s.icon),
                        const SizedBox(height: AppSpacing.x8),
                        Text(s.title,
                            textAlign: TextAlign.center,
                            style: AppTypography.display),
                        const SizedBox(height: AppSpacing.x3),
                        Text(s.body,
                            textAlign: TextAlign.center,
                            style: AppTypography.body.copyWith(
                                color: AppColors.textSecondary, height: 1.5)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: i == _page ? AppGradients.brand : null,
                      color: i == _page ? null : AppColors.border,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screen),
              child: PrimaryButton(
                label: last ? 'Get started' : 'Next',
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Decorative hero: a grid of gradient tiles that drift + fade into place,
/// evoking a mosaic assembling, with the slide's icon revealed on top.
class _MosaicHero extends StatefulWidget {
  const _MosaicHero({super.key, required this.icon});
  final IconData icon;

  @override
  State<_MosaicHero> createState() => _MosaicHeroState();
}

class _MosaicHeroState extends State<_MosaicHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(200),
              painter: _MosaicHeroPainter(_c.value),
            ),
            Opacity(
              opacity: Curves.easeIn.transform(
                  ((_c.value - 0.55) / 0.45).clamp(0.0, 1.0)),
              child: Icon(widget.icon,
                  size: 56, color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _MosaicHeroPainter extends CustomPainter {
  _MosaicHeroPainter(this.t);
  final double t;

  static const _n = 6;

  double _hash(int n) {
    var x = (n * 2654435761) & 0xFFFFFFFF;
    x ^= x >> 15;
    return (x & 0xFFFF) / 0x10000;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / _n;
    final radius = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(24));
    canvas.clipRRect(radius);
    final center = size.center(Offset.zero);
    final paint = Paint();

    for (var r = 0; r < _n; r++) {
      for (var c = 0; c < _n; c++) {
        final idx = r * _n + c;
        final start = _hash(idx) * 0.5;
        final lt = ((t - start) / 0.5).clamp(0.0, 1.0);
        if (lt <= 0) continue;
        final e = Curves.easeOutCubic.transform(lt);
        final color = Color.lerp(AppColors.gradientStart, AppColors.gradientEnd,
            (r + c) / (2 * _n))!;
        final cellRect = Rect.fromLTWH(c * cell, r * cell, cell, cell);
        final scaled = Rect.fromCenter(
          center: Offset.lerp(center, cellRect.center, e)!,
          width: cell * (0.4 + 0.6 * e),
          height: cell * (0.4 + 0.6 * e),
        );
        paint.color = color.withValues(alpha: e);
        canvas.drawRRect(
          RRect.fromRectAndRadius(scaled.deflate(1.5),
              const Radius.circular(4)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MosaicHeroPainter old) => old.t != t;
}
