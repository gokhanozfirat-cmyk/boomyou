import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'vault_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const String _channelId = 'boomyou_messages';
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

    await _initializeLocalNotifications();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    await _syncCurrentToken(enabled: notificationsEnabled);

    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) async {
      if (token.trim().isEmpty) return;
      await _vaultService.upsertPushToken(
        token,
        platform: _platformLabel,
        notificationsEnabled: true,
      );
    });

    _foregroundMessageSub = FirebaseMessaging.onMessage.listen(
      _showForegroundNotification,
    );
  }

  Future<void> _syncCurrentToken({required bool enabled}) async {
    if (!enabled) {
      await _vaultService.clearPushTokensForCurrentUser();
      return;
    }

    final token = await _messaging.getToken();
    if (token == null || token.trim().isEmpty) return;

    await _vaultService.upsertPushToken(
      token,
      platform: _platformLabel,
      notificationsEnabled: true,
    );
  }

  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(settings);

    final androidPlatform = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlatform?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final remoteNotification = message.notification;
    final title = (remoteNotification?.title ?? '').trim();
    final body = (remoteNotification?.body ?? '').trim();
    if (title.isEmpty && body.isEmpty) return;

    await _localNotifications.show(
      message.hashCode,
      title.isEmpty ? 'BoomYou' : title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
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
