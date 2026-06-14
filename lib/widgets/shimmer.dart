import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Sweeps a soft highlight across its child to signal loading. Wrap skeleton
/// shapes ([SkeletonBox]) in this. Modern alternative to a bare spinner.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value * 2 - 0.5; // sweep from off-left to off-right
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [
              AppColors.surfaceRaised,
              AppColors.border,
              AppColors.surfaceRaised,
            ],
            stops: [
              (t - 0.25).clamp(0.0, 1.0),
              t.clamp(0.0, 1.0),
              (t + 0.25).clamp(0.0, 1.0),
            ],
          ).createShader(bounds),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A self-contained animated brand-gradient placeholder — a glowing "loader"
/// shown in image slots (project cards, download thumbnails) until the real
/// picture decodes. Owns its own ticker, so it can appear/disappear per item.
class GradientShimmerBox extends StatefulWidget {
  const GradientShimmerBox({super.key, this.width, this.height});
  final double? width;
  final double? height;

  @override
  State<GradientShimmerBox> createState() => _GradientShimmerBoxState();
}

class _GradientShimmerBoxState extends State<GradientShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value * 1.6 - 0.3; // sweep the bright band across
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.gradientStart.withValues(alpha: 0.7),
                AppColors.gradientEnd.withValues(alpha: 1),
                AppColors.gradientStart.withValues(alpha: 0.7),
              ],
              stops: [
                (t - 0.35).clamp(0.0, 1.0),
                t.clamp(0.0, 1.0),
                (t + 0.35).clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A network image with the animated gradient placeholder showing *behind* it
/// until the picture decodes, then fading the image in on top — the same feel
/// as the project cards (robust to fast/cached loads, unlike `loadingBuilder`).
class ShimmerNetworkImage extends StatelessWidget {
  const ShimmerNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.errorIconSize = 24,
  });

  final String url;
  final BoxFit fit;
  final double errorIconSize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const GradientShimmerBox(),
        Image.network(
          url,
          fit: fit,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              child: child,
            );
          },
          errorBuilder: (_, _, _) => ColoredBox(
            color: AppColors.surfaceRaised,
            child: Center(
              child: Icon(Icons.image,
                  size: errorIconSize, color: AppColors.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}

/// A solid placeholder block tinted for the shimmer to sweep over.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadius.chip,
  });
  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Skeleton matching the gallery's 2-column project grid.
class GalleryGridSkeleton extends StatelessWidget {
  const GalleryGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: GridView.builder(
        padding: const EdgeInsets.all(AppSpacing.screen),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: AppSpacing.x3,
          crossAxisSpacing: AppSpacing.x3,
          childAspectRatio: 0.85,
        ),
        itemCount: 6,
        itemBuilder: (_, _) =>
            const SkeletonBox(radius: AppRadius.card),
      ),
    );
  }
}

/// Skeleton matching the downloads list rows.
class DownloadsListSkeleton extends StatelessWidget {
  const DownloadsListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.screen),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 7,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x2),
        itemBuilder: (_, _) => Row(
          children: [
            const SkeletonBox(width: 48, height: 48),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(width: 160, height: 12),
                  SizedBox(height: AppSpacing.x2),
                  SkeletonBox(width: 90, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
