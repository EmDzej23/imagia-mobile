import 'package:flutter/services.dart';

/// Thin wrapper over [HapticFeedback] so call sites read intent, not strength,
/// and so we can tune feel in one place.
abstract final class Haptics {
  /// Light tap — buttons, card taps, toggles.
  static void tap() => HapticFeedback.lightImpact();

  /// Medium — committing an action (export, purchase).
  static void impact() => HapticFeedback.mediumImpact();

  /// Discrete tick — moving through options / reveal moments.
  static void selection() => HapticFeedback.selectionClick();

  /// Celebratory double-beat for completion (render done, tokens added).
  static Future<void> success() async {
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    HapticFeedback.lightImpact();
  }
}
