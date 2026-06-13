import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../router.dart';

/// Firebase Cloud Messaging integration. The server pushes a "your mosaic is
/// ready" message when a render finishes — so the user is notified even if they
/// left the app (the local notification only covers the app-open case).
///
/// Background/terminated delivery: the server sends a *notification* message, so
/// the OS displays it automatically; tapping it deep-links to the preview.
class PushService {
  PushService._();
  static final instance = PushService._();

  final _messaging = FirebaseMessaging.instance;

  /// Wires up permission + tap handlers. Call once at startup.
  Future<void> init() async {
    await _messaging.requestPermission();

    // Tapped while backgrounded.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleOpen);
    // Tapped from terminated (app launched by the notification).
    final initial = await _messaging.getInitialMessage();
    if (initial != null) _handleOpen(initial);
  }

  /// Registers this device's FCM token with the server for the signed-in user.
  /// Call after sign-in (needs the bearer token on [client]).
  Future<void> registerToken(ApiClient client) async {
    try {
      final token = await _messaging.getToken();
      if (token != null) await _send(client, token);
      _messaging.onTokenRefresh.listen((t) => _send(client, t));
    } catch (_) {
      // Push registration is best-effort.
    }
  }

  Future<void> _send(ApiClient client, String token) async {
    await client.post<dynamic>('/api/push/register', body: {
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
    });
  }

  void _handleOpen(RemoteMessage message) {
    // All current pushes route to the latest rendered mosaic.
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null) ctx.push('/preview');
  }
}
