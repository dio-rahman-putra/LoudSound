import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'firebase_options.dart';

enum NotificationPermissionResult {
  enabled,
  denied,
  notConfigured,
  unsupportedPlatform,
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final options = DefaultFirebaseOptions.currentPlatform;
  if (options == null) {
    return;
  }
  await Firebase.initializeApp(options: options);
}

abstract final class FirebaseNotificationService {
  static final Int64List _vibrationPattern =
      Int64List.fromList([0, 500, 200, 500]);

  static final _channel = AndroidNotificationChannel(
    'sound_alerts',
    'Peringatan kebisingan',
    description: 'Notifikasi saat tingkat suara melewati batas.',
    importance: Importance.high,
    enableVibration: true,
    vibrationPattern: _vibrationPattern,
  );

  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static bool get isConfigured => _initialized;

  static Future<void> initialize() async {
    if (!_supportsPushNotifications || Firebase.apps.isEmpty) {
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);
    } else {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    _initialized = true;
  }

  static Future<NotificationPermissionResult> enableNotifications() async {
    if (!_supportsPushNotifications) {
      return NotificationPermissionResult.unsupportedPlatform;
    }
    if (!_initialized) {
      return NotificationPermissionResult.notConfigured;
    }

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!granted) {
      return NotificationPermissionResult.denied;
    }

    await FirebaseMessaging.instance.subscribeToTopic('noise-alerts');
    return NotificationPermissionResult.enabled;
  }

  static bool get _supportsPushNotifications =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> _showForegroundNotification(
    RemoteMessage message,
  ) async {
    final notification = message.notification;
    if (notification == null ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await HapticFeedback.vibrate();

    await _localNotifications.show(
      id: message.messageId.hashCode & 0x7fffffff,
      title: notification.title,
      body: notification.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          enableVibration: true,
          vibrationPattern: _vibrationPattern,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }
}
