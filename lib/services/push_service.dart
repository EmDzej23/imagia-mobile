import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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
    final settings = await _messaging.requestPermission();
    debugPrint('[push] permission: ${settings.authorizationStatus}');

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
      // iOS: FCM cannot mint a token until APNs has registered this (re)install.
      // On a fresh install there's a short delay before the APNs token lands,
      // so poll for it — otherwise getToken() returns null and the new install
      // never registers, leaving the server with a stale (dead) token.
      if (Platform.isIOS) {
        var apns = await _messaging.getAPNSToken();
        for (var i = 0; i < 12 && apns == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          apns = await _messaging.getAPNSToken();
        }
        debugPrint(
            '[push] APNs token: ${apns == null ? 'NULL — not registered with APNs' : 'present'}');
      }

      final token = await _messaging.getToken();
      debugPrint('[push] FCM token: ${token ?? 'NULL'}');
      if (token != null) await _send(client, token);

      // Re-register if the token rotates (e.g. after a reinstall/restore).
      _messaging.onTokenRefresh.listen((t) {
        debugPrint('[push] FCM token refreshed');
        _send(client, t);
      });
    } catch (e) {
      debugPrint('[push] registerToken failed: $e');
    }
  }

  Future<void> _send(ApiClient client, String token) async {
    final res = await client.post<dynamic>('/api/push/register', body: {
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
    });
    debugPrint(
        '[push] register → ${res.status} ${res.isOk ? 'OK' : res.error}');
  }

  void _handleOpen(RemoteMessage message) {
    // All current pushes route to the latest rendered mosaic.
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null) ctx.push('/preview');
  }
}
