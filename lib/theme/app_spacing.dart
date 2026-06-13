/// Spacing, radius and sizing tokens. Base unit 4px. See design plan §3.3.
abstract final class AppSpacing {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;

  /// Horizontal screen padding.
  static const double screen = 16;

  /// Minimum touch target.
  static const double touchTarget = 48;
}

/// Corner radius tokens. Echoes the rectangular tiles without being literal.
abstract final class AppRadius {
  /// Cards and sheets.
  static const double card = 12;

  /// Buttons and controls.
  static const double control = 8;

  /// Chips.
  static const double chip = 4;
}
