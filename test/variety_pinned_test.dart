import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/mosaic/shared.dart';

/// Variety is no longer a choice. It is pinned in `sanitizeSettings` rather than merely
/// defaulted, so that saved projects, presets and any stored value land on it too — a
/// project created before the dial was retired must not keep running on its old number.
void main() {
  test('every input lands on the pinned value', () {
    for (final v in [0.0, 0.01, 0.25, 0.5, 1.0, -3.0, 99.0]) {
      final out = sanitizeSettings(defaultSettings()..reusePenalty = v);
      expect(out.reusePenalty, fixedReusePenalty,
          reason: 'input $v should be ignored, not clamped');
    }
  });

}
