import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'pressable.dart';

/// The app's standard surface card: a subtle top-lit gradient, soft elevation
/// shadow, hairline border and rounded corners. Pass [onTap]/[onLongPress] to
/// make it pressable (adds scale + haptic). Used everywhere a card appears so
/// the look stays consistent.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.onLongPress,
    this.radius,
    this.highlighted = false,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? radius;

  /// Accent border (e.g. selected state).
  final bool highlighted;

  /// Clip the child to the rounded corners (for edge-to-edge media).
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? AppRadius.card;
    final borderRadius = BorderRadius.circular(r);

    Widget inner =
        padding == null ? child : Padding(padding: padding!, child: child);
    // Clip only the child (media) — clipping the whole box would also clip the
    // drop shadow.
    if (clip) {
      inner = ClipRRect(borderRadius: borderRadius, child: inner);
    }

    final content = DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppGradients.surface,
        borderRadius: borderRadius,
        border: Border.all(
          color: highlighted ? AppColors.primaryBright : AppColors.border,
          width: highlighted ? 1.5 : 1,
        ),
        boxShadow: AppGradients.elevation(opacity: 0.30, blur: 16),
      ),
      child: inner,
    );

    if (onTap == null && onLongPress == null) return content;
    return PressableScale(
        onPressed: onTap, onLongPress: onLongPress, child: content);
  }
}
