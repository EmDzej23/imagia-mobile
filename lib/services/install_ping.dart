import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import 'token_storage.dart';

/// Anonymous "app install" ping so the server can count installs over time.
/// Sent once per installation: a random installId (UUID v4) is persisted, POSTed
/// to `/api/app/install`, and only marked sent on a 2xx — any failure (offline,
/// 404 before the backend ships, 500) silently retries on the next launch. The
/// endpoint is idempotent per installId, so a repeat send is harmless.
///
/// State lives in a small file in the app-support dir, NOT the secure store: the
/// iOS Keychain survives uninstall, which would make a reinstall look like the
/// same install. The app-support dir is wiped on uninstall on both platforms.
class InstallPing {
  InstallPing._();

  static const _fileName = 'install_ping_v1.json';

  /// Fire-and-forget from startup; never throws, never shows UI.
  static Future<void> run() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');

      Map<String, dynamic> state = {};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) state = decoded;
      }
      if (state['sent'] == true) return;

      var installId = state['installId'];
      if (installId is! String || installId.isEmpty) {
        installId = _uuidV4();
        state = {'installId': installId, 'sent': false};
        if (!await dir.exists()) await dir.create(recursive: true);
        await file.writeAsString(jsonEncode(state));
      }

      // Anonymous: no bearer token, and a 401 can't sign the user out.
      final client = ApiClient(_NoToken());
      final res = await client.post<dynamic>('/api/app/install', body: {
        'installId': installId,
        'platform': Platform.operatingSystem,
        // package_info_plus isn't a dependency; the server accepts null.
        'appVersion': null,
      });
      if (!res.isOk) {
        debugPrint('[install] ping → ${res.status}, will retry next launch');
        return;
      }
      await file.writeAsString(jsonEncode({'installId': installId, 'sent': true}));
      debugPrint('[install] ping sent');
    } catch (_) {
      // Retry next launch.
    }
  }

  /// RFC 4122 v4 from a CSPRNG (avoids adding the `uuid` package).
  static String _uuidV4() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// Token store that never yields (or clears) a session token.
class _NoToken extends TokenStorage {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> clear() async {}
}
