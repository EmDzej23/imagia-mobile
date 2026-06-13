import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Animated brand splash shown while the auth bootstrap resolves: the logo
/// fades/scales in, then the wordmark and slogan rise in below it. A minimum
/// display time is enforced in the auth controller so the animation is seen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..forward();

  late final Animation<double> _logoFade = _interval(0.0, 0.5);
  late final Animation<double> _logoScale = Tween(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack)));
  late final Animation<double> _titleFade = _interval(0.4, 0.8);
  late final Animation<double> _sloganFade = _interval(0.6, 1.0);

  Animation<double> _interval(double a, double b) => CurvedAnimation(
      parent: _c, curve: Interval(a, b, curve: Curves.easeOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: _logoFade.value,
                  child: Transform.scale(
                    scale: _logoScale.value,
                    child: Image.asset('assets/logo.png',
                        width: 168, height: 168, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: AppSpacing.x6),
                Opacity(
                  opacity: _titleFade.value,
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - _titleFade.value)),
                    child: Text('Imagia',
                        style: AppTypography.display.copyWith(
                            fontSize: 34, letterSpacing: 0.5)),
                  ),
                ),
                const SizedBox(height: AppSpacing.x2),
                Opacity(
                  opacity: _sloganFade.value,
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - _sloganFade.value)),
                    child: Text('Made of moments.',
                        style: AppTypography.body
                            .copyWith(color: AppColors.accent, letterSpacing: 1.2)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
