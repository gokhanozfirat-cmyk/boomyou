import 'dart:async';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import 'vault_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const String _androidVibrateChannelId = 'boomyou_messages_v3_vibrate';
  static const String _androidVibrateChannelName = 'BoomYou Messages';
  static const String _androidSilentChannelId = 'boomyou_messages_v3_silent';
  static const String _androidSilentChannelName =
      'BoomYou Messages (No Vibration)';
  static const String _channelDescription = 'BoomYou chat notifications';

  static const List<String> _funTitles = [
    'Oyun zaman\u{0131}! \u{1F3AE}',
    'Haydi oyuna! \u{1F525}',
    'BoomYou! \u{1F4A3}',
    'Bomba haz\u{0131}r! \u{1F4A5}',
    'S\u{0131}ra sende! \u{1F3AF}',
  ];

  static const List<String> _funBodies = [
    'Haydi kasana gir, seni bekliyorlar!',
    'Boom! Kasan\u{0131} patlatma vakti!',
    'Rakibin hamlesini yapt\u{0131}, s\u{0131}ra sende!',
    'Oyun ba\u{015F}l\u{0131}yor, haz\u{0131}r m\u{0131}s\u{0131}n?',
    'Kasan\u{0131} a\u{00E7}, oyun seni bekliyor!',
  ];

  static final Random _rng = Random();

  final VaultService _vaultService = VaultService();
  FirebaseMessaging? _messaging;
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
    _messaging ??= FirebaseMessaging.instance;
    final messaging = _messaging!;

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
    );

    final notificationsPermissionGranted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
    debugPrint(
      'FCM permission status: ${settings.authorizationStatus.name} '
      '(granted=$notificationsPermissionGranted)',
    );

    await _initializeLocalNotifications();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    await _syncCurrentTokenWithRetry(enabled: true);

    if (!notificationsPermissionGranted) {
      debugPrint(
        'Notifications permission is not granted yet. '
        'FCM token sync still attempted for backend registration.',
      );
    }

    _tokenRefreshSub = messaging.onTokenRefresh.listen((token) async {
      try {
        final normalized = token.trim();
        if (normalized.isEmpty) {
          debugPrint('FCM token refresh produced an empty token.');
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        final pushEnabled = prefs.getBool('notif_push_enabled') ?? true;
        final vibrationEnabled =
            prefs.getBool('notif_vibration_enabled') ?? true;
        await _vaultService.upsertPushToken(
          normalized,
          platform: _platformLabel,
          notificationsEnabled: pushEnabled,
          vibrationEnabled: vibrationEnabled,
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
    final messaging = _messaging;
    if (messaging == null) {
      debugPrint('FCM token sync skipped: FirebaseMessaging is not ready.');
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    final pushEnabled = prefs.getBool('notif_push_enabled') ?? true;
    final vibrationEnabled = prefs.getBool('notif_vibration_enabled') ?? true;

    if (!enabled || !pushEnabled) {
      await _vaultService.clearPushTokensForCurrentUser();
      return true;
    }

    try {
      final token = await messaging.getToken();
      if (token == null || token.trim().isEmpty) {
        debugPrint('FCM token unavailable (null/empty).');
        return false;
      }

      await _vaultService.upsertPushToken(
        token,
        platform: _platformLabel,
        notificationsEnabled: pushEnabled,
        vibrationEnabled: vibrationEnabled,
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
        _androidVibrateChannelId,
        _androidVibrateChannelName,
        description: _channelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        enableLights: true,
        vibrationPattern: Int64List.fromList(<int>[0, 250, 160, 250]),
      ),
    );
    await androidPlatform?.createNotificationChannel(
      const AndroidNotificationChannel(
        _androidSilentChannelId,
        _androidSilentChannelName,
        description: _channelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: false,
        enableLights: true,
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
    final remoteTitle = (remoteNotification?.title ?? '').trim();
    final remoteBody = (remoteNotification?.body ?? '').trim();

    // Use server-sent text if available, otherwise pick a fun random message.
    final title = remoteTitle.isNotEmpty
        ? remoteTitle
        : _funTitles[_rng.nextInt(_funTitles.length)];
    final body = remoteBody.isNotEmpty
        ? remoteBody
        : _funBodies[_rng.nextInt(_funBodies.length)];

    final prefs = await SharedPreferences.getInstance();
    final pushEnabled = prefs.getBool('notif_push_enabled') ?? true;
    final vibrationEnabled = prefs.getBool('notif_vibration_enabled') ?? true;

    // Always vibrate if vibration is enabled, regardless of push setting.
    if (vibrationEnabled) {
      final hasVibrator = (await Vibration.hasVibrator()) == true;
      if (hasVibrator) {
        // Pattern: wait 0ms, vibrate 300ms, pause 200ms, vibrate 300ms
        Vibration.vibrate(pattern: [0, 300, 200, 300]);
      } else {
        HapticFeedback.heavyImpact();
      }
    }

    if (!pushEnabled) return;

    final androidChannelId =
        vibrationEnabled ? _androidVibrateChannelId : _androidSilentChannelId;
    final androidChannelName = vibrationEnabled
        ? _androidVibrateChannelName
        : _androidSilentChannelName;

    await _localNotifications.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          androidChannelId,
          androidChannelName,
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
