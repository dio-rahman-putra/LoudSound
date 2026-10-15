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

/// Layanan notifikasi LoudSound.
///
/// Peringatan kebisingan dibuat LOKAL oleh aplikasi begitu data BLE dari ESP32
/// menunjukkan suara melewati ambang batas, sehingga TIDAK bergantung pada
/// konfigurasi Firebase/backend. Firebase Cloud Messaging (topic `noise-alerts`)
/// tetap dipakai sebagai tambahan bila Firebase berhasil diinisialisasi.
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

  static const int _alertNotificationId = 1001;
  static const int _statusNotificationId = 1002;

  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static bool get isConfigured => _initialized;

  static bool get _supportsNotifications =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get _firebaseReady => Firebase.apps.isNotEmpty;

  static Future<void> initialize() async {
    if (!_supportsNotifications || _initialized) {
      return;
    }

    try {
      await _localNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // Izin diminta saat user menekan ikon lonceng, bukan saat start.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );

      if (defaultTargetPlatform == TargetPlatform.android) {
        await _localNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(_channel);
      }
      _initialized = true;
    } catch (e) {
      debugPrint('[Notif] Gagal inisialisasi notifikasi lokal: $e');
      return;
    }

    // Bagian Firebase bersifat opsional.
    if (_firebaseReady) {
      try {
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler,
        );
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          await FirebaseMessaging.instance
              .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
        }
        FirebaseMessaging.onMessage.listen(_showForegroundNotification);
      } catch (e) {
        debugPrint('[Notif] Firebase Messaging tidak aktif: $e');
      }
    }
  }

  /// Apakah izin notifikasi sistem sudah diberikan.
  static Future<bool> hasPermission() async {
    if (!_supportsNotifications) return false;
    await initialize();
    if (!_initialized) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      return await _localNotifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false;
    }
    return false;
  }

  /// Meminta izin notifikasi dan mengaktifkan peringatan kebisingan.
  static Future<NotificationPermissionResult> enableNotifications() async {
    if (!_supportsNotifications) {
      return NotificationPermissionResult.unsupportedPlatform;
    }
    await initialize();
    if (!_initialized) {
      return NotificationPermissionResult.denied;
    }

    bool granted = false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = _localNotifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        granted = await android?.requestNotificationsPermission() ??
            await android?.areNotificationsEnabled() ??
            false;
      } else {
        granted = await _localNotifications
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } catch (e) {
      debugPrint('[Notif] Gagal meminta izin notifikasi: $e');
    }

    if (!granted) {
      return NotificationPermissionResult.denied;
    }

    if (_firebaseReady) {
      try {
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        await FirebaseMessaging.instance.subscribeToTopic('noise-alerts');
      } catch (e) {
        debugPrint('[Notif] Gagal subscribe topic FCM: $e');
      }
    }
    return NotificationPermissionResult.enabled;
  }

  /// Notifikasi konfirmasi setelah user mengaktifkan peringatan.
  static Future<void> showActivatedNotification() {
    return _show(
      id: _statusNotificationId,
      title: 'Notifikasi LoudSound aktif',
      body:
          'Anda akan diberi tahu saat suara melewati batas aman 85 dB.',
      vibrate: false,
    );
  }

  /// Peringatan saat suara terlalu berisik.
  static Future<void> showNoiseAlert({required double db}) {
    return _show(
      id: _alertNotificationId,
      title: 'Terlalu berisik!',
      body:
          'Tingkat suara ${db.toStringAsFixed(1)} dB melewati batas aman 85 dB.',
      vibrate: true,
    );
  }

  static Future<void> _show({
    required int id,
    required String? title,
    required String? body,
    required bool vibrate,
  }) async {
    if (!_supportsNotifications || !_initialized) return;

    try {
      await _localNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: vibrate,
            vibrationPattern: vibrate ? _vibrationPattern : null,
            playSound: true,
            ticker: title,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notif] Gagal menampilkan notifikasi: $e');
    }
  }

  static Future<void> _showForegroundNotification(
    RemoteMessage message,
  ) async {
    final notification = message.notification;
    if (notification == null ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await HapticFeedback.vibrate();

    await _show(
      id: message.messageId.hashCode & 0x7fffffff,
      title: notification.title,
      body: notification.body,
      vibrate: true,
    );
  }
}
