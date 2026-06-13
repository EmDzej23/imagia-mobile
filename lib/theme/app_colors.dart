import 'package:flutter/material.dart';

/// Central color palette derived from the brand logo (navy/indigo, warm cream,
/// cool grey/white on near-black). Defined once — widgets must never hardcode
/// colors. See mosaic-app-design-plan.md §3.1.
abstract final class AppColors {
  /// App canvas (near-black).
  static const background = Color(0xFF0A0B0F);

  /// Cards, sheets, control panels.
  static const surface = Color(0xFF14161D);

  /// Elevated elements, menus, dialogs.
  static const surfaceRaised = Color(0xFF1E212B);

  /// Primary actions, active states, selection.
  static const primary = Color(0xFF2B3A67);

  /// Pressed/hover, focus rings, sliders.
  static const primaryBright = Color(0xFF3D5394);

  /// Highlights, progress, "complete" states, the warm tile color.
  static const accent = Color(0xFFE8DCC0);

  /// Headings, primary body.
  static const textPrimary = Color(0xFFF4F5F7);

  /// Secondary text, labels, captions.
  static const textSecondary = Color(0xFF9AA3B2);

  /// Disabled, hints, metadata.
  static const textMuted = Color(0xFF5C6373);

  /// Hairline dividers, card edges.
  static const border = Color(0xFF262A35);

  /// Errors, destructive actions.
  static const error = Color(0xFFC45B5B);

  /// Confirmation, success toasts.
  static const success = Color(0xFF7FA88B);
}
