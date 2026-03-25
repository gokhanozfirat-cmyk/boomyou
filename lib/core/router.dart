import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'navigation_observer.dart';
import '../screens/game_screen.dart';
import '../screens/vault_setup_screen.dart';
import '../screens/vault_home_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/attachment_gallery_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/game',
  observers: [appRouteObserver],
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
      builder: (context, state) {
        final conversationId = state.pathParameters['conversationId']!;
        final activeVaultId = state.uri.queryParameters['vaultId'];
        return ChatScreen(
          key: ValueKey('chat:$conversationId:${activeVaultId ?? ""}'),
          conversationId: conversationId,
          activeVaultId: activeVaultId,
        );
      },
    ),
    GoRoute(
      path: '/gallery',
      builder: (context, state) => const AttachmentGalleryScreen(),
    ),
  ],
);
