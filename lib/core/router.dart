import 'package:go_router/go_router.dart';
import '../screens/game_screen.dart';
import '../screens/vault_setup_screen.dart';
import '../screens/vault_home_screen.dart';
import '../screens/chat_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/game',
  routes: [
    GoRoute(
      path: '/game',
      builder: (context, state) => const GameScreen(),
    ),
    GoRoute(
      path: '/vault-setup/:vaultId',
      builder: (context, state) => VaultSetupScreen(
        vaultId: state.pathParameters['vaultId']!,
      ),
    ),
    GoRoute(
      path: '/vault/:vaultId',
      builder: (context, state) => VaultHomeScreen(
        vaultId: state.pathParameters['vaultId']!,
      ),
    ),
    GoRoute(
      path: '/chat/:conversationId',
      builder: (context, state) => ChatScreen(
        conversationId: state.pathParameters['conversationId']!,
      ),
    ),
  ],
);
