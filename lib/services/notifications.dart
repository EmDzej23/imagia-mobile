import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';

/// Local notifications. Used so far for the "mosaic render finished" alert,
/// which deep-links to the high-res preview screen.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  static const _channelId = 'render';
  static const _previewPayload = 'preview';

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _onTap,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          'Mosaic updates',
          description: 'Notifies you when a high-res mosaic is ready',
          importance: Importance.high,
        ));
  }

  /// Asks for notification permission (iOS, and Android 13+). Safe to call
  /// repeatedly; the OS only prompts once.
  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> showRenderDone({String? fileName}) async {
    await _plugin.show(
      id: 1,
      title: 'Your mosaic is ready 🎉',
      body: fileName == null
          ? 'Tap to view and download your high-res mosaic.'
          : 'Tap to view and download "$fileName".',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Mosaic updates',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: _previewPayload,
    );
  }

  void _onTap(NotificationResponse response) {
    if (response.payload == _previewPayload) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) ctx.push('/preview');
    }
  }
}
