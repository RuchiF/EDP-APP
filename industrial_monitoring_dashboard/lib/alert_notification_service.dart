import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android / iOS system notifications. Web and unsupported platforms no-op.
class AlertNotificationService {
  AlertNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static bool get _useNativeNotifications {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'sensor_alerts',
    'Sensor alerts',
    description: 'Temperature and vibration threshold alerts',
    importance: Importance.high,
  );

  static Future<void> init() async {
    if (!_useNativeNotifications) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_channel);
    await android?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  static int _nextId = 9000;

  static Future<void> showVibrationAlert(String deviceLabel, String body) async {
    await _show(
      id: _nextId++,
      title: 'Vibration alert · $deviceLabel',
      body: body,
    );
  }

  static Future<void> showTemperatureAlert(String deviceLabel, String body) async {
    await _show(
      id: _nextId++,
      title: 'Temperature alert · $deviceLabel',
      body: body,
    );
  }

  static Future<void> _show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_useNativeNotifications || !_initialized) return;

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          ticker: title,
        ),
        iOS: iosDetails,
      ),
    );
  }
}
