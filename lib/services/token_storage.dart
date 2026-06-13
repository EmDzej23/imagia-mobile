import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the better-auth bearer session token in the platform secure store,
/// with an in-memory cache so reads after a write return immediately (mirrors
/// the RN reference `lib/storage.ts`).
class TokenStorage {
  TokenStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'session_token';

  final FlutterSecureStorage _storage;
  String? _cache;
  bool _loaded = false;

  Future<String?> read() async {
    if (_loaded) return _cache;
    _cache = await _storage.read(key: _key);
    _loaded = true;
    return _cache;
  }

  /// Synchronous best-effort read; returns null until [read] has run once.
  String? get cached => _cache;

  Future<void> write(String token) async {
    _cache = token;
    _loaded = true;
    await _storage.write(key: _key, value: token);
  }

  Future<void> clear() async {
    _cache = null;
    _loaded = true;
    await _storage.delete(key: _key);
  }
}
