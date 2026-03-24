import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
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

  // Initialize Firebase for FCM
  await Firebase.initializeApp();

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
  await authService.ensureAnonymousAuth();

  // Initialize default vault for the user
  final vaultService = VaultService();
  await vaultService.initDefaultVault();

  // Initialize push notifications (FCM token + permission sync)
  await NotificationService().initialize();

  runApp(const BoomYouApp());
}

class BoomYouApp extends StatelessWidget {
  const BoomYouApp({super.key});

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
