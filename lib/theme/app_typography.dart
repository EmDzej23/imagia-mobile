import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Inter type scale, backed by the bundled Inter font asset (see pubspec
/// `fonts:`). Numbers use tabular figures so they don't jitter while sliders
/// move. See design plan §3.2.
abstract final class AppTypography {
  static const String fontFamily = 'Inter';
  static const _tabular = [FontFeature.tabularFigures()];

  static const TextStyle display = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.4,
    color: AppColors.textPrimary,
  );

  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: AppColors.textPrimary,
  );

  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: AppColors.textSecondary,
  );

  /// Tabular variant for live numeric values (counts, density, percentages).
  static TextStyle number(TextStyle base) =>
      base.copyWith(fontFeatures: _tabular);
}
