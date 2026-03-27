import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vault_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const String _channelId = 'boomyou_messages_v2';
  static const String _channelName = 'BoomYou Messages';
  static const String _channelDescription = 'BoomYou chat notifications';

  final VaultService _vaultService = VaultService();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundMessageSub;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('FCM init skipped: $e');
      return;
    }

    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
    );

    final notificationsEnabled =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
    debugPrint(
      'FCM permission status: ${settings.authorizationStatus.name} (enabled=$notificationsEnabled)',
    );

    await _initializeLocalNotifications();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    await _syncCurrentTokenWithRetry(enabled: notificationsEnabled);

    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) async {
      try {
        final normalized = token.trim();
        if (normalized.isEmpty) {
          debugPrint('FCM token refresh produced an empty token.');
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        final pushEnabled = prefs.getBool('notif_push_enabled') ?? true;
        await _vaultService.upsertPushToken(
          normalized,
          platform: _platformLabel,
          notificationsEnabled: pushEnabled,
        );
        debugPrint('FCM token refreshed: ${_maskToken(normalized)}');
      } catch (e) {
        debugPrint('FCM token refresh sync failed: $e');
      }
    });

    _foregroundMessageSub = FirebaseMessaging.onMessage.listen(
      _showForegroundNotification,
    );
  }

  Future<void> _syncCurrentTokenWithRetry({required bool enabled}) async {
    if (!enabled) {
      await _syncCurrentToken(enabled: false);
      return;
    }

    const delays = <Duration>[
      Duration.zero,
      Duration(seconds: 2),
      Duration(seconds: 6),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ];

    for (var i = 0; i < delays.length; i++) {
      final delay = delays[i];
      if (delay > Duration.zero) {
        await Future.delayed(delay);
      }
      final ok = await _syncCurrentToken(enabled: true);
      if (ok) return;
      debugPrint('FCM token sync retry ${i + 1}/${delays.length} failed.');
    }
  }

  Future<bool> _syncCurrentToken({required bool enabled}) async {
    if (!enabled) {
      await _vaultService.clearPushTokensForCurrentUser();
      debugPrint('FCM token sync skipped: notifications disabled.');
      return true;
    }

    try {
      final token = await _messaging.getToken();
      if (token == null || token.trim().isEmpty) {
        debugPrint('FCM token unavailable (null/empty).');
        return false;
      }

      await _vaultService.upsertPushToken(
        token,
        platform: _platformLabel,
        notificationsEnabled: true,
      );
      debugPrint('FCM token synced: ${_maskToken(token)}');
      return true;
    } catch (e) {
      debugPrint('FCM token fetch/sync failed: $e');
      return false;
    }
  }

  Future<void> _initializeLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(settings);

    final androidPlatform =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlatform?.requestNotificationsPermission();
    await androidPlatform?.createNotificationChannel(
      AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        enableLights: true,
        vibrationPattern: Int64List.fromList(<int>[0, 250, 160, 250]),
      ),
    );

    final iosPlatform =
        _localNotifications.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    await iosPlatform?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    final macosPlatform =
        _localNotifications.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
    await macosPlatform?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final remoteNotification = message.notification;
    final title = (remoteNotification?.title ?? '').trim();
    final body = (remoteNotification?.body ?? '').trim();

    final prefs = await SharedPreferences.getInstance();
    final pushEnabled = prefs.getBool('notif_push_enabled') ?? true;
    final vibrationEnabled = prefs.getBool('notif_vibration_enabled') ?? true;

    // Always vibrate if vibration is enabled, regardless of push setting.
    if (vibrationEnabled) {
      HapticFeedback.heavyImpact();
    }

    if (!pushEnabled || (title.isEmpty && body.isEmpty)) return;

    await _localNotifications.show(
      message.hashCode,
      title.isEmpty ? 'BoomYou' : title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          enableVibration: vibrationEnabled,
          playSound: pushEnabled,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: pushEnabled,
          presentBadge: pushEnabled,
          presentSound: pushEnabled,
        ),
      ),
    );
  }

  /// Call from settings screen to persist user preferences.
  Future<void> setNotificationPrefs({
    required bool pushEnabled,
    required bool vibrationEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notif_push_enabled', pushEnabled);
    await prefs.setBool('notif_vibration_enabled', vibrationEnabled);
    await _syncCurrentTokenWithRetry(enabled: pushEnabled);
  }

  String _maskToken(String token) {
    final trimmed = token.trim();
    if (trimmed.length <= 12) return trimmed;
    return '${trimmed.substring(0, 6)}...${trimmed.substring(trimmed.length - 6)}';
  }

  String get _platformLabel {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    await _foregroundMessageSub?.cancel();
    _tokenRefreshSub = null;
    _foregroundMessageSub = null;
    _initialized = false;
  }
}
