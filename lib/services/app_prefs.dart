import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small persisted app flags (not secrets — but reuses the secure store we
/// already depend on). Currently just the first-run onboarding flag.
class AppPrefs {
  AppPrefs([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _onboardingKey = 'onboarding_seen_v1';

  final FlutterSecureStorage _storage;

  Future<bool> onboardingSeen() async =>
      (await _storage.read(key: _onboardingKey)) == '1';

  Future<void> setOnboardingSeen() =>
      _storage.write(key: _onboardingKey, value: '1');
}

final appPrefsProvider = Provider<AppPrefs>((ref) => AppPrefs());
