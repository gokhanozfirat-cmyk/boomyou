import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/navigation_observer.dart';
import '../core/supabase_client.dart';
import '../core/theme.dart';
import '../services/vault_service.dart';

class VaultHomeScreen extends StatefulWidget {
  final String vaultId;

  const VaultHomeScreen({super.key, required this.vaultId});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen>
    with WidgetsBindingObserver, RouteAware {
  final VaultService _vaultService = VaultService();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _pendingInvites = [];
  Map<String, int> _unreadCounts = {};
  String? _myRumus;
  bool _isLoading = true;
  RealtimeChannel? _realtimeChannel;
  Timer? _realtimeReloadDebounce;
  Timer? _idleExitTimer;
  ModalRoute<dynamic>? _route;
  bool _isRouteActive = true;
  bool _leavingForBackground = false;
  bool _exitToGameOnResume = false;

  static const Duration _idleTimeout = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restartIdleTimer();
    _loadData();
    _subscribeRealtime();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      if (_route != null) {
        appRouteObserver.unsubscribe(this);
      }
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
      _route = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _cancelIdleTimer();
    _realtimeReloadDebounce?.cancel();
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  @override
  void didPush() {
    _isRouteActive = true;
    _restartIdleTimer();
  }

  @override
  void didPopNext() {
    _isRouteActive = true;
    _restartIdleTimer();
    _loadData();
  }

  @override
  void didPushNext() {
    _isRouteActive = false;
    _cancelIdleTimer();
  }

  @override
  void didPop() {
    _isRouteActive = false;
    _cancelIdleTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || !_isRouteActive) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelIdleTimer();
      _requestExitToGame();
      return;
    }

    if (state == AppLifecycleState.resumed && _exitToGameOnResume) {
      _requestExitToGame();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _restartIdleTimer();
    }
  }

  void _subscribeRealtime() {
    _realtimeChannel = supabase
        .channel('vault-home:${widget.vaultId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: (_) => _scheduleRealtimeReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'invites',
          callback: (_) => _scheduleRealtimeReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          callback: (_) => _scheduleRealtimeReload(),
        )
        .subscribe();
  }

  void _scheduleRealtimeReload() {
    if (!mounted) return;
    _realtimeReloadDebounce?.cancel();
    _realtimeReloadDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        _loadData();
      }
    });
  }

  void _onUserActivity() {
    if (!mounted || !_isRouteActive || _leavingForBackground) return;
    _restartIdleTimer();
  }

  void _restartIdleTimer() {
    _idleExitTimer?.cancel();
    if (!mounted || !_isRouteActive || _leavingForBackground) return;
    _idleExitTimer = Timer(_idleTimeout, () {
      if (!mounted || !_isRouteActive || _leavingForBackground) return;
      _requestExitToGame();
    });
  }

  void _cancelIdleTimer() {
    _idleExitTimer?.cancel();
    _idleExitTimer = null;
  }

  void _requestExitToGame() {
    _exitToGameOnResume = true;
    _cancelIdleTimer();
    if (!mounted || !_isRouteActive || _leavingForBackground) return;
    _leavingForBackground = true;

    void goToGame() {
      if (!mounted) return;
      context.go('/game');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => goToGame());
    Future<void>.delayed(const Duration(milliseconds: 80), goToGame);
    Future<void>.delayed(const Duration(milliseconds: 220), goToGame);
    Future<void>.delayed(const Duration(milliseconds: 500), goToGame);

    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      _leavingForBackground = false;
      _exitToGameOnResume = false;
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final conversationsFuture =
          _vaultService.getConversations(widget.vaultId);
      final pendingInvitesFuture =
          _vaultService.getPendingInvites(vaultId: widget.vaultId);
      final myRumusFuture = _vaultService.getVaultRumus(widget.vaultId);

      final conversations = await conversationsFuture;
      final unreadCounts = await _vaultService.getUnreadCounts(
        widget.vaultId,
        conversations
            .map((conv) => (conv['id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toList(),
      );
      final pendingInvites = await pendingInvitesFuture;
      final myRumus = await myRumusFuture;

      if (mounted) {
        setState(() {
          _conversations = conversations;
          _pendingInvites = pendingInvites;
          _myRumus = myRumus;
          _unreadCounts = unreadCounts;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSearchDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Ara',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: TextField(
          controller: controller,
          style: GoogleFonts.orbitron(color: kTextPrimary),
          decoration: const InputDecoration(
            hintText: 'Rumus gir...',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'İptal',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentRed),
            onPressed: () async {
              final rumus = controller.text.trim();
              if (rumus.isEmpty) return;
              Navigator.pop(ctx);
              await _sendInvite(rumus);
            },
            child: Text(
              'Davet Gönder',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteConversation(String conversationId) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Sohbeti Sil',
          style: GoogleFonts.orbitron(color: kAccentRed),
        ),
        content: Text(
          'Bu sohbet kapatılır ve listeden kaldırılır. Tekrar konuşmak için yeni davet gerekir. Devam edilsin mi?',
          style: GoogleFonts.orbitron(color: kTextSecondary, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Vazgeç',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Sil',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      try {
        await _vaultService.deleteConversation(conversationId, widget.vaultId);
        if (mounted) {
          setState(() => _conversations
              .removeWhere((c) => c['id'].toString() == conversationId));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Sohbet kapatılamadı.',
                style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 12),
              ),
              backgroundColor: kBombBody,
            ),
          );
        }
      }
    }
  }

  Future<void> _sendInvite(String toRumus) async {
    final normalizedTarget = toRumus.trim().toLowerCase();
    if (normalizedTarget.isEmpty) return;
    if (normalizedTarget == (_myRumus ?? '').trim().toLowerCase()) {
      _showSnack('Kendine davet gönderemezsin.');
      return;
    }
    try {
      await _vaultService.sendInvite(
        normalizedTarget,
        fromVaultId: widget.vaultId,
      );
      _showSnack('Davet gönderildi.');
    } catch (_) {
      _showSnack('Davet gönderilemedi.');
    }
  }

  void _showNewVaultDialog() {
    final rumusController = TextEditingController();
    final codeController = TextEditingController();
    final confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Yeni Alan',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rumusController,
              style: GoogleFonts.orbitron(color: kTextPrimary),
              decoration: const InputDecoration(hintText: 'Alan rumuzu'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Şifre (6 hane)'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Şifre tekrar'),
              textInputAction: TextInputAction.done,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showExistingVaultLoginDialog();
                },
                icon: const Icon(Icons.login, color: kAccentGreen),
                label: Text(
                  'Varolan bir alanda oturum aç',
                  style: GoogleFonts.orbitron(
                    color: kAccentGreen,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'İptal',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentRed),
            onPressed: () async {
              final rumus = rumusController.text.trim().toLowerCase();
              final code = codeController.text.trim();
              final confirm = confirmController.text.trim();
              if (rumus.isEmpty || rumus.length < 3) {
                _showSnack('Rumus en az 3 karakter olmalı.');
                return;
              }
              final rumusRegex = RegExp(r'^[a-z0-9_]+$');
              if (!rumusRegex.hasMatch(rumus)) {
                _showSnack('Rumus sadece küçük harf, sayı ve _ içerebilir.');
                return;
              }
              final rumusTaken = await _vaultService.isRumusTaken(rumus);
              if (rumusTaken) {
                _showSnack('Bu rumus zaten kullanılıyor.');
                return;
              }
              if (code.length != 6) {
                _showSnack('Şifre 6 haneli olmalı.');
                return;
              }
              if (code != confirm) {
                _showSnack('Şifreler eşleşmiyor.');
                return;
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              try {
                final newVaultId =
                    await _vaultService.createVaultWithSetup(rumus, code);
                if (!mounted) return;
                _showSnack('Yeni alan oluşturuldu.');
                await context.push('/vault/$newVaultId');
                if (mounted) _loadData();
              } catch (_) {
                _showSnack('Alan oluşturulamadı.');
              }
            },
            child: Text(
              'Oluştur',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _showExistingVaultLoginDialog() {
    final rumusController = TextEditingController();
    final codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Varolan Alanda Oturum Aç',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rumusController,
              style: GoogleFonts.orbitron(color: kTextPrimary),
              decoration: const InputDecoration(hintText: 'Rumus'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Şifre (6 hane)'),
              textInputAction: TextInputAction.done,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'İptal',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentGreen),
            onPressed: () async {
              final rumus = rumusController.text.trim().toLowerCase();
              final code = codeController.text.trim();

              if (rumus.isEmpty) {
                _showSnack('Rumus gerekli.');
                return;
              }
              if (code.length != 6) {
                _showSnack('Şifre 6 haneli olmalı.');
                return;
              }

              if (!ctx.mounted) return;
              Navigator.pop(ctx);

              try {
                final vaultId =
                    await _vaultService.loginToExistingVault(rumus, code);
                if (!mounted) return;
                _showSnack('Alanda oturum açıldı.');
                await context.push('/vault/$vaultId');
                if (mounted) _loadData();
              } catch (_) {
                _showSnack('Rumus veya şifre yanlış.');
              }
            },
            child: Text(
              'Oturum Aç',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _showChangeCodeDialog() {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Şifre Değiştir',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Mevcut şifre'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Yeni şifre'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(hintText: 'Yeni şifre tekrar'),
              textInputAction: TextInputAction.done,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'İptal',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentRed),
            onPressed: () async {
              final current = currentController.text.trim();
              final newCode = newController.text.trim();
              final confirm = confirmController.text.trim();
              if (current.length != 6 || newCode.length != 6) {
                _showSnack('Şifreler 6 haneli olmalı.');
                return;
              }
              if (newCode != confirm) {
                _showSnack('Yeni şifreler eşleşmiyor.');
                return;
              }
              // Verify current code
              final matchedId = await _vaultService.checkCode(current);
              if (!ctx.mounted) return;
              if (matchedId != widget.vaultId) {
                _showSnack('Mevcut şifre yanlış.');
                return;
              }
              // ignore: use_build_context_synchronously
              Navigator.pop(ctx);
              try {
                await _vaultService.changeVaultCode(widget.vaultId, newCode);
                _showSnack('Şifre değiştirildi.');
              } catch (_) {
                _showSnack('Şifre değiştirilemedi.');
              }
            },
            child: Text(
              'Değiştir',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Alanı Sil',
          style: GoogleFonts.orbitron(color: kAccentRed),
        ),
        content: Text(
          'Bu alanı silmek istediğine emin misin? Tüm konuşmalar silinecek ve alan varsayılana sıfırlanacak.',
          style: GoogleFonts.orbitron(
            color: kTextSecondary,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Vazgeç',
              style: GoogleFonts.orbitron(color: kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccentRed),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _vaultService.deleteVault(widget.vaultId);
                if (mounted) context.go('/game');
              } catch (_) {
                _showSnack('Alan silinemedi.');
              }
            },
            child: Text(
              'Sil',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _showAcceptInviteBottomSheet(Map<String, dynamic> invite) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBombBody,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@${invite['from_rumus']} senden gelen davet',
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Konuşma bu alan üzerinden başlayacak.',
              style: GoogleFonts.orbitron(
                color: kTextSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccentGreen,
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      try {
                        await _vaultService.acceptInvite(
                          invite['id'] as String,
                          widget.vaultId,
                          invite['from_user_id'] as String,
                        );
                        _showSnack('Davet kabul edildi.');
                        _loadData();
                      } catch (_) {
                        _showSnack('Davet kabul edilemedi.');
                      }
                    },
                    child: Text(
                      'Kabul Et',
                      style: GoogleFonts.orbitron(color: kTextPrimary),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kAccentRed),
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _vaultService.declineInvite(invite['id'] as String);
                      _showSnack('Davet reddedildi.');
                      _loadData();
                    },
                    child: Text(
                      'Reddet',
                      style: GoogleFonts.orbitron(color: kAccentRed),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                },
                child: Text(
                  'Kapat',
                  style: GoogleFonts.orbitron(color: kTextSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
        ),
        backgroundColor: kBombBody,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onUserActivity(),
      onPointerMove: (_) => _onUserActivity(),
      onPointerSignal: (_) => _onUserActivity(),
      child: Scaffold(
        backgroundColor: kBackground,
        appBar: AppBar(
          backgroundColor: kBackground,
          leading: IconButton(
            icon: const Icon(Icons.lock_outline, color: kAccentGreen),
            onPressed: () {
              _requestExitToGame();
            },
          ),
          title: Text(
            _myRumus != null ? '@$_myRumus' : 'Alan',
            style: GoogleFonts.orbitron(
              color: kTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: kTextSecondary),
              onPressed: () {
                _onUserActivity();
                _loadData();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            _buildActionButtons(),
            const Divider(color: kBombBorder, height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: kAccentRed))
                  : _buildConversationList(),
            ),
            _buildQuickLockButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _ActionButton(
            label: 'Ara',
            icon: Icons.search,
            onTap: _showSearchDialog,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Yeni Alan',
            icon: Icons.add_box_outlined,
            onTap: _showNewVaultDialog,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Şifre\nDeğiştir',
            icon: Icons.lock_reset,
            onTap: _showChangeCodeDialog,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Alanı\nSil',
            icon: Icons.delete_outline,
            color: kAccentRed,
            onTap: _showDeleteConfirmDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList() {
    final hasInvites = _pendingInvites.isNotEmpty;
    final hasConvos = _conversations.isNotEmpty;

    if (!hasInvites && !hasConvos) {
      return Center(
        child: Text(
          'Henüz konuşma yok.\nBirini ara ve davet et.',
          textAlign: TextAlign.center,
          style: GoogleFonts.orbitron(
            color: kTextSecondary,
            fontSize: 14,
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: kAccentRed,
      onRefresh: _loadData,
      child: ListView(
        children: [
          if (hasInvites) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Bekleyen Davetler',
                style: GoogleFonts.orbitron(
                  color: kAccentGreen,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ..._pendingInvites.map((invite) => _InviteTile(
                  invite: invite,
                  onTap: () => _showAcceptInviteBottomSheet(invite),
                )),
            const Divider(color: kBombBorder, height: 1),
            const SizedBox(height: 4),
          ],
          if (hasConvos)
            ..._conversations.map((conv) => _ConversationTile(
                  conversation: conv,
                  myVaultId: widget.vaultId,
                  unreadCount:
                      _unreadCounts[(conv['id'] ?? '').toString()] ?? 0,
                  vaultService: _vaultService,
                  onTap: () => context.push(
                    '/chat/${conv['id']}?vaultId=${Uri.encodeComponent(widget.vaultId)}',
                  ),
                  onLongPress: () =>
                      _confirmDeleteConversation(conv['id'].toString()),
                )),
        ],
      ),
    );
  }

  Widget _buildQuickLockButton() {
    return Container(
      width: double.infinity,
      color: kBackground,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      child: SizedBox(
        height: 58,
        child: ElevatedButton.icon(
          onPressed: _requestExitToGame,
          icon: const Icon(Icons.lock, color: kTextPrimary, size: 24),
          label: Text(
            'KILITLE ve OYUNA DÖN',
            style: GoogleFonts.orbitron(
              color: kTextPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: kAccentGreen,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = kTextSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: kBombBody,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kBombBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: GoogleFonts.orbitron(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InviteTile extends StatelessWidget {
  final Map<String, dynamic> invite;
  final VoidCallback onTap;

  const _InviteTile({required this.invite, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      tileColor: kBombBody.withAlpha(80),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: kAccentGreen.withAlpha(30),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kAccentGreen.withAlpha(100)),
        ),
        child: const Icon(Icons.mail_outline, color: kAccentGreen, size: 20),
      ),
      title: Text(
        '@${invite['from_rumus']}',
        style: GoogleFonts.orbitron(
          color: kTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        'seni davet ediyor',
        style: GoogleFonts.orbitron(
          color: kTextSecondary,
          fontSize: 11,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: kTextSecondary),
      onTap: onTap,
    );
  }
}

class _ConversationTile extends StatefulWidget {
  final Map<String, dynamic> conversation;
  final String myVaultId;
  final int unreadCount;
  final VaultService vaultService;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conversation,
    required this.myVaultId,
    required this.unreadCount,
    required this.vaultService,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  String? _otherRumus;

  @override
  void initState() {
    super.initState();
    _loadOtherRumus();
  }

  Future<void> _loadOtherRumus() async {
    final initiatorVaultId =
        widget.conversation['initiator_vault_id'] as String?;
    final participantVaultId =
        widget.conversation['participant_vault_id'] as String?;
    final initiatorId = widget.conversation['initiator_id'] as String?;
    final participantId = widget.conversation['participant_id'] as String?;

    String? other;
    if (initiatorVaultId != null && initiatorVaultId != widget.myVaultId) {
      other = await widget.vaultService.getVaultRumus(initiatorVaultId);
    } else if (participantVaultId != null &&
        participantVaultId != widget.myVaultId) {
      other = await widget.vaultService.getVaultRumus(participantVaultId);
    }

    // Backward compatibility with old records that do not have
    // initiator_vault_id / participant_vault_id.
    if (other == null) {
      final initiatorRumus = initiatorId != null
          ? await widget.vaultService.getRumusByUserId(initiatorId)
          : null;
      final participantRumus = participantId != null
          ? await widget.vaultService.getRumusByUserId(participantId)
          : null;
      final currentRumus = await widget.vaultService.getVaultRumus(
        widget.myVaultId,
      );

      if (initiatorRumus != null && initiatorRumus != currentRumus) {
        other = initiatorRumus;
      } else if (participantRumus != null && participantRumus != currentRumus) {
        other = participantRumus;
      }
    }

    if (mounted) {
      setState(() => _otherRumus = other);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isClosed = widget.conversation['is_closed'] == true;
    final unreadCount = widget.unreadCount;

    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: kBombBody,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: kBombBorder),
        ),
        child:
            const Icon(Icons.person_outline, color: kTextSecondary, size: 22),
      ),
      title: Text(
        _otherRumus != null ? '@$_otherRumus' : '...',
        style: GoogleFonts.orbitron(
          color: kTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        isClosed ? 'Sohbet kapalı • tekrar davet gerekir' : 'Sohbet açık',
        style: GoogleFonts.orbitron(
          color: kTextSecondary,
          fontSize: 11,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: kAccentRed,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                unreadCount > 99 ? '99+' : unreadCount.toString(),
                style: GoogleFonts.orbitron(
                  color: kTextPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (unreadCount > 0) const SizedBox(width: 8),
          Icon(
            isClosed ? Icons.lock_outline : Icons.chevron_right,
            color: kTextSecondary,
          ),
        ],
      ),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }
}
