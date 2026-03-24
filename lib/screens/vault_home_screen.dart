import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme.dart';
import '../services/vault_service.dart';

class VaultHomeScreen extends StatefulWidget {
  final String vaultId;

  const VaultHomeScreen({super.key, required this.vaultId});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  final VaultService _vaultService = VaultService();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _pendingInvites = [];
  String? _myRumus;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _vaultService.getConversations(widget.vaultId),
        _vaultService.getPendingInvites(),
        _vaultService.getCurrentUserRumus(),
      ]);
      if (mounted) {
        setState(() {
          _conversations =
              results[0] as List<Map<String, dynamic>>;
          _pendingInvites =
              results[1] as List<Map<String, dynamic>>;
          _myRumus = results[2] as String?;
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

  Future<void> _sendInvite(String toRumus) async {
    if (toRumus == _myRumus) {
      _showSnack('Kendine davet gönderemezsin.');
      return;
    }
    try {
      await _vaultService.sendInvite(toRumus);
      _showSnack('Davet gönderildi.');
    } catch (_) {
      _showSnack('Davet gönderilemedi.');
    }
  }

  void _showNewVaultDialog() {
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
              final code = codeController.text.trim();
              final confirm = confirmController.text.trim();
              if (code.length != 6) {
                _showSnack('Şifre 6 haneli olmalı.');
                return;
              }
              if (code != confirm) {
                _showSnack('Şifreler eşleşmiyor.');
                return;
              }
              Navigator.pop(ctx);
              try {
                await _vaultService.createVault(code);
                _showSnack('Yeni alan oluşturuldu.');
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
              final matchedId =
                  await _vaultService.checkCode(current);
              if (!ctx.mounted) return;
              if (matchedId != widget.vaultId) {
                _showSnack('Mevcut şifre yanlış.');
                return;
              }
              // ignore: use_build_context_synchronously
              Navigator.pop(ctx);
              try {
                await _vaultService.changeVaultCode(
                    widget.vaultId, newCode);
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

  void _showAcceptInviteBottomSheet(Map<String, dynamic> invite) async {
    final vaults = await _vaultService.getVaults();
    if (!mounted) return;

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
              'Daveti hangi alana ekle?',
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...vaults.map((vault) => ListTile(
                  tileColor: kInputBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  title: Text(
                    vault['is_setup'] == true
                        ? 'Alan (kurulu)'
                        : 'Alan (kurulmamış)',
                    style: GoogleFonts.orbitron(
                      color: kTextPrimary,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '${vault['id'].toString().substring(0, 8)}...',
                    style: GoogleFonts.orbitron(
                      color: kTextSecondary,
                      fontSize: 11,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      await _vaultService.acceptInvite(
                        invite['id'] as String,
                        vault['id'] as String,
                        invite['from_user_id'] as String,
                      );
                      _showSnack('Davet kabul edildi.');
                      _loadData();
                    } catch (_) {
                      _showSnack('Davet kabul edilemedi.');
                    }
                  },
                )),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _vaultService
                      .declineInvite(invite['id'] as String);
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
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        leading: IconButton(
          icon: const Icon(Icons.lock_outline, color: kAccentGreen),
          onPressed: () => context.go('/game'),
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
            onPressed: _loadData,
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
        ],
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
                  vaultService: _vaultService,
                  onTap: () => context.push('/chat/${conv['id']}'),
                )),
        ],
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
  final VaultService vaultService;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.myVaultId,
    required this.vaultService,
    required this.onTap,
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
    final initiatorId =
        widget.conversation['initiator_id'] as String?;
    final participantId =
        widget.conversation['participant_id'] as String?;

    final initiatorRumus = initiatorId != null
        ? await widget.vaultService.getRumusByUserId(initiatorId)
        : null;
    final participantRumus = participantId != null
        ? await widget.vaultService.getRumusByUserId(participantId)
        : null;

    final currentRumus = await widget.vaultService.getCurrentUserRumus();

    String? other;
    if (initiatorRumus != null && initiatorRumus != currentRumus) {
      other = initiatorRumus;
    } else if (participantRumus != null &&
        participantRumus != currentRumus) {
      other = participantRumus;
    }

    if (mounted) {
      setState(() => _otherRumus = other);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: kBombBody,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: kBombBorder),
        ),
        child: const Icon(Icons.person_outline, color: kTextSecondary, size: 22),
      ),
      title: Text(
        _otherRumus != null ? '@$_otherRumus' : '...',
        style: GoogleFonts.orbitron(
          color: kTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: kTextSecondary),
      onTap: widget.onTap,
    );
  }
}
