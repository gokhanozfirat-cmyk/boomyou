import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/vault_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Load environment variables
  await dotenv.load(fileName: '.env');

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
    ),
  );

  // Ensure anonymous auth
  final authService = AuthService();
  try {
    await authService.ensureAnonymousAuth();
    debugPrint('Current auth user: ${authService.currentUserId}');
  } catch (e, st) {
    debugPrint('Anonymous auth failed: $e');
    debugPrint('$st');
  }

  // Initialize default vault for the user
  final vaultService = VaultService();
  try {
    await vaultService.initDefaultVault();
  } catch (e, st) {
    debugPrint('Default vault init failed: $e');
    debugPrint('$st');
  }

  // Initialize push notifications & FCM token sync
  try {
    await NotificationService().initialize();
  } catch (e, st) {
    debugPrint('NotificationService init failed: $e');
    debugPrint('$st');
  }

  runApp(const BoomYouApp());
}

class BoomYouApp extends StatefulWidget {
  const BoomYouApp({super.key});

  @override
  State<BoomYouApp> createState() => _BoomYouAppState();
}

class _BoomYouAppState extends State<BoomYouApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BoomYou',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
