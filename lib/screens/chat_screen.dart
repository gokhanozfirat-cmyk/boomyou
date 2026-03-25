import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/vault_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String? activeVaultId;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.activeVaultId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final VaultService _vaultService = VaultService();
  final AuthService _authService = AuthService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocus = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  List<Map<String, dynamic>> _messages = [];
  final Set<String> _hiddenMessageIds = {};
  final Set<String> _selectedMessageIds = {};

  String? _myUserId;
  String? _otherRumus;
  String? _myVaultId;
  RealtimeChannel? _subscription;
  bool _isConversationClosed = false;
  bool _isLoading = true;
  bool _isSending = false;
  bool _leavingForBackground = false;
  bool _exitToGameOnResume = false;
  bool _isExternalPickerActive = false;
  Timer? _idleExitTimer;
  Timer? _readMarkDebounce;
  Timer? _autoExpireTimer;
  bool _timerEnabled = false;

  static const Duration _idleTimeout = Duration(seconds: 10);
  static const Duration _expireDuration = Duration(hours: 1);

  String get _hiddenStoreKey =>
      'chat_hidden_${_myUserId ?? "anon"}_${widget.conversationId}';
  String get _timerEnabledKey => 'chat_timer_enabled_${widget.conversationId}';
  String get _timerReadAtKey => 'chat_timer_read_at_${widget.conversationId}';

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  String? get _activeUserId =>
      _myUserId ?? _authService.currentUserId ?? supabase.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _myUserId = _authService.currentUserId;
    _messageController.addListener(_onUserActivity);
    _restartIdleTimer();
    _loadHiddenMessages();
    _loadTimerState();
    _loadInitialData();
    _subscribeToMessages();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId) return;

    _subscription?.unsubscribe();
    _subscription = null;
    _readMarkDebounce?.cancel();
    _autoExpireTimer?.cancel();
    _messageController.clear();

    if (!mounted) return;
    setState(() {
      _messages = [];
      _hiddenMessageIds.clear();
      _selectedMessageIds.clear();
      _otherRumus = null;
      _myVaultId = null;
      _isConversationClosed = false;
      _isLoading = true;
      _isSending = false;
      _timerEnabled = false;
    });

    _loadHiddenMessages();
    _loadTimerState();
    _loadInitialData();
    _subscribeToMessages();
    _restartIdleTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    // Native pickers (image/file) temporarily pause the app; do not force game lock then.
    if (_isExternalPickerActive) {
      if (state == AppLifecycleState.resumed) {
        _restartIdleTimer();
      }
      return;
    }

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

  Future<T?> _runWithExternalPicker<T>(Future<T?> Function() action) async {
    _isExternalPickerActive = true;
    _cancelIdleTimer();
    try {
      return await action();
    } finally {
      _isExternalPickerActive = false;
      if (mounted && !_leavingForBackground) {
        _restartIdleTimer();
      }
    }
  }

  void _requestExitToGame() {
    _exitToGameOnResume = true;
    _cancelIdleTimer();
    if (!mounted || _leavingForBackground) return;
    _leavingForBackground = true;

    void goToGame() {
      if (!mounted) return;
      context.go('/game');
    }

    // Try immediately, then retry a few times for devices that defer lifecycle routing.
    WidgetsBinding.instance.addPostFrameCallback((_) => goToGame());
    Future<void>.delayed(const Duration(milliseconds: 80), goToGame);
    Future<void>.delayed(const Duration(milliseconds: 220), goToGame);
    Future<void>.delayed(const Duration(milliseconds: 500), goToGame);

    // Reset guard so future background transitions can trigger again.
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      _leavingForBackground = false;
      _exitToGameOnResume = false;
    });
  }

  void _onUserActivity() {
    if (!mounted || _leavingForBackground) return;
    _restartIdleTimer();
  }

  void _restartIdleTimer() {
    _idleExitTimer?.cancel();
    if (!mounted || _leavingForBackground) return;
    _idleExitTimer = Timer(_idleTimeout, () {
      if (!mounted || _leavingForBackground) return;
      _requestExitToGame();
    });
  }

  void _cancelIdleTimer() {
    _idleExitTimer?.cancel();
    _idleExitTimer = null;
  }

  void _scheduleMarkConversationRead() {
    _readMarkDebounce?.cancel();
    _readMarkDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_markConversationReadNow());
    });
  }

  Future<void> _markConversationReadNow() async {
    final current = (_myVaultId ?? widget.activeVaultId ?? '').trim();
    final resolvedVaultId = current.isNotEmpty
        ? current
        : await _vaultService.checkMyConversationVault(widget.conversationId);
    if (resolvedVaultId == null || resolvedVaultId.isEmpty) return;

    _myVaultId ??= resolvedVaultId;
    await _vaultService.markConversationRead(
      widget.conversationId,
      resolvedVaultId,
    );

    if (_timerEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _timerReadAtKey, DateTime.now().toUtc().toIso8601String());
    }
  }

  @override
  void dispose() {
    unawaited(_markConversationReadNow());
    WidgetsBinding.instance.removeObserver(this);
    _messageController.removeListener(_onUserActivity);
    _cancelIdleTimer();
    _readMarkDebounce?.cancel();
    _autoExpireTimer?.cancel();
    _subscription?.unsubscribe();
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  Future<void> _loadTimerState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_timerEnabledKey) ?? false;
    if (!mounted) return;
    setState(() => _timerEnabled = enabled);
    if (enabled) _startAutoExpireTimer();
  }

  Future<void> _toggleTimer() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !_timerEnabled;
    await prefs.setBool(_timerEnabledKey, newValue);
    if (!mounted) return;
    setState(() => _timerEnabled = newValue);
    if (newValue) {
      _startAutoExpireTimer();
      _showSnack('Zamanlayıcı açık — okunmuş mesajlar 1 saat sonra kaybolur.');
    } else {
      _autoExpireTimer?.cancel();
      _showSnack('Zamanlayıcı kapatıldı.');
    }
  }

  void _startAutoExpireTimer() {
    _autoExpireTimer?.cancel();
    // Check every minute
    _autoExpireTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _expireReadMessages();
    });
    // Also check immediately
    _expireReadMessages();
  }

  Future<void> _expireReadMessages() async {
    if (!_timerEnabled || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final readAtStr = prefs.getString(_timerReadAtKey);
    if (readAtStr == null) return;
    final readAt = DateTime.tryParse(readAtStr);
    if (readAt == null) return;
    final expireAt = readAt.add(_expireDuration);
    if (DateTime.now().isBefore(expireAt)) return;

    // 1 hour has passed since last read — hide all messages created before readAt
    final toHide = _messages.map((m) => (m['id'] ?? '').toString()).where((id) {
      if (id.isEmpty || _hiddenMessageIds.contains(id)) return false;
      final msg = _messages.firstWhere(
        (m) => (m['id'] ?? '').toString() == id,
        orElse: () => {},
      );
      if (msg.isEmpty) return false;
      final createdAt = DateTime.tryParse((msg['created_at'] ?? '').toString());
      if (createdAt == null) return false;
      return createdAt.isBefore(readAt.add(const Duration(seconds: 1)));
    }).toList();

    if (toHide.isEmpty) return;
    setState(() => _hiddenMessageIds.addAll(toHide));
    await _persistHiddenMessages();
  }

  Future<void> _loadHiddenMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getStringList(_hiddenStoreKey) ?? const <String>[];
    if (!mounted) return;
    setState(() {
      _hiddenMessageIds
        ..clear()
        ..addAll(hidden);
    });
  }

  Future<void> _persistHiddenMessages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenStoreKey, _hiddenMessageIds.toList());
  }

  Future<void> _loadInitialData() async {
    try {
      _myUserId = _activeUserId;
      final msgs = await _vaultService.getMessages(widget.conversationId);
      Map<String, dynamic>? convResult;
      try {
        convResult = await supabase
            .from('conversations')
            .select(
                'initiator_id, participant_id, initiator_vault_id, participant_vault_id, is_closed')
            .eq('id', widget.conversationId)
            .maybeSingle();
      } catch (_) {
        convResult = await supabase
            .from('conversations')
            .select(
                'initiator_id, participant_id, initiator_vault_id, participant_vault_id')
            .eq('id', widget.conversationId)
            .maybeSingle();
      }

      String? otherRumus;
      String? myVault;
      bool isClosed = false;
      if (convResult != null) {
        final initiatorVaultId = convResult['initiator_vault_id'] as String?;
        final participantVaultId =
            convResult['participant_vault_id'] as String?;
        final initiatorId = convResult['initiator_id'] as String?;
        final participantId = convResult['participant_id'] as String?;
        isClosed = convResult['is_closed'] as bool? ?? false;
        final routeVaultId = widget.activeVaultId?.trim();
        if (routeVaultId != null && routeVaultId.isNotEmpty) {
          myVault = routeVaultId;
        } else {
          myVault = await _vaultService.checkMyConversationVault(
            widget.conversationId,
          );
        }

        if (myVault != null) {
          if (initiatorVaultId != null && initiatorVaultId != myVault) {
            otherRumus = await _vaultService.getVaultRumus(initiatorVaultId);
          } else if (participantVaultId != null &&
              participantVaultId != myVault) {
            otherRumus = await _vaultService.getVaultRumus(participantVaultId);
          }
        }

        if (otherRumus == null) {
          final otherId =
              initiatorId == _myUserId ? participantId : initiatorId;
          if (otherId != null) {
            otherRumus = await _vaultService.getRumusByUserId(otherId);
          }
        }

        // If fallback accidentally resolves to my own rumus, force the opposite vault.
        if (myVault != null && otherRumus != null) {
          final myRumus = await _vaultService.getVaultRumus(myVault);
          if (myRumus != null &&
              otherRumus.toLowerCase().trim() == myRumus.toLowerCase().trim()) {
            final oppositeVaultId = initiatorVaultId == myVault
                ? participantVaultId
                : initiatorVaultId;
            if (oppositeVaultId != null) {
              final forcedOther =
                  await _vaultService.getVaultRumus(oppositeVaultId);
              if (forcedOther != null && forcedOther.trim().isNotEmpty) {
                otherRumus = forcedOther;
              }
            }
          }
        }
      }

      if (mounted) {
        msgs.sort(_compareMessageOrder);
        setState(() {
          _messages = msgs;
          _otherRumus = otherRumus;
          _myVaultId = myVault;
          _isConversationClosed = isClosed;
          _isLoading = false;
        });
        _scrollToBottom();
        _scheduleMarkConversationRead();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToMessages() {
    _subscription = supabase
        .channel('messages:${widget.conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (payload) {
            final newMessage = payload.newRecord;
            if (mounted) {
              setState(() {
                final exists =
                    _messages.any((m) => m['id'] == newMessage['id']);
                if (!exists) {
                  _messages.add(newMessage);
                  _messages.sort(_compareMessageOrder);
                }
              });
              _scrollToBottom();
              _scheduleMarkConversationRead();
            }
          },
        )
        .subscribe();
  }

  int _compareMessageOrder(Map<String, dynamic> a, Map<String, dynamic> b) {
    final at = (a['created_at'] ?? '').toString();
    final bt = (b['created_at'] ?? '').toString();
    final byTime = at.compareTo(bt);
    if (byTime != 0) return byTime;
    final aid = (a['id'] ?? '').toString();
    final bid = (b['id'] ?? '').toString();
    return aid.compareTo(bid);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    if (_isConversationClosed) {
      _showSnack(
          'Bu sohbet kapatıldı. Tekrar konuşmak için yeni davet gönder.');
      return;
    }

    final content = _messageController.text.trim();
    if (content.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      final senderVaultId = _myVaultId ??
          widget.activeVaultId ??
          await _vaultService.checkMyConversationVault(widget.conversationId);
      await _vaultService.sendMessage(
        widget.conversationId,
        content,
        senderVaultId: senderVaultId,
      );
      _scheduleMarkConversationRead();
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('SOHBET_KAPALI')) {
        setState(() => _isConversationClosed = true);
        _showSnack(
            'Bu sohbet kapatıldı. Tekrar konuşmak için yeni davet gönder.');
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Mesaj gönderilemedi.',
            style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
          ),
          backgroundColor: kBombBody,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _showAttachmentActions() async {
    if (_isSending) return;
    if (_isConversationClosed) {
      _showSnack(
          'Bu sohbet kapatıldı. Tekrar konuşmak için yeni davet gönder.');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: kBombBody,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined, color: kTextPrimary),
              title: Text(
                'Görsel Gönder',
                style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _pickAndSendImage(oneTime: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined, color: kAccentRed),
              title: Text(
                'Tek Seferlik Foto',
                style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
              ),
              subtitle: Text(
                'Açılınca sohbetten gizlenir.',
                style:
                    GoogleFonts.orbitron(color: kTextSecondary, fontSize: 10),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _pickAndSendImage(oneTime: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file, color: kTextPrimary),
              title: Text(
                'Dosya Gönder',
                style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _pickAndSendFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendImage({required bool oneTime}) async {
    try {
      _messageFocus.unfocus();
      final picked = await _runWithExternalPicker(
        () => _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        ),
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _uploadAndSendAttachment(
        bytes: bytes,
        fileName: picked.name.isEmpty ? 'image.jpg' : picked.name,
        mimeType: 'image/jpeg',
        type: _MessagePayload.typeImage,
        oneTime: oneTime,
      );
    } catch (e) {
      debugPrint('Image picker/send failed: $e');
      _showSnack('Görsel seçilemedi.');
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      _messageFocus.unfocus();
      final result = await _runWithExternalPicker(
        () => FilePicker.platform.pickFiles(withData: true),
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        _showSnack('Dosya okunamadı.');
        return;
      }
      final extension = (file.extension ?? '').toLowerCase();
      final mime = switch (extension) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };
      await _uploadAndSendAttachment(
        bytes: bytes,
        fileName: file.name,
        mimeType: mime,
        type: _MessagePayload.typeFile,
      );
    } catch (e) {
      debugPrint('File picker/send failed: $e');
      _showSnack('Dosya gönderilemedi.');
    }
  }

  Future<void> _uploadAndSendAttachment({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String type,
    bool oneTime = false,
  }) async {
    if (_isSending) return;
    if (_isConversationClosed) {
      _showSnack(
          'Bu sohbet kapatıldı. Tekrar konuşmak için yeni davet gönder.');
      return;
    }
    setState(() => _isSending = true);
    try {
      final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final objectPath =
          '${_activeUserId ?? "anon"}/${DateTime.now().millisecondsSinceEpoch}_$safeName';

      debugPrint(
          'UPLOAD: userId=$_activeUserId bytes=${bytes.length} path=$objectPath mime=$mimeType');

      await supabase.storage.from('chat_attachments').uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              cacheControl: '3600',
              upsert: false,
              contentType: mimeType,
            ),
          );
      final publicUrl =
          supabase.storage.from('chat_attachments').getPublicUrl(objectPath);

      final payload = _MessagePayload(
        type: type,
        text: '',
        url: publicUrl,
        fileName: safeName,
        mimeType: mimeType,
        oneTime: oneTime,
      ).encode();
      final senderVaultId = _myVaultId ??
          widget.activeVaultId ??
          await _vaultService.checkMyConversationVault(widget.conversationId);
      await _vaultService.sendMessage(
        widget.conversationId,
        payload,
        senderVaultId: senderVaultId,
      );
    } catch (e, stack) {
      debugPrint('UPLOAD FULL ERROR: $e\n$stack');
      String msg = 'Hata: $e';
      try {
        final se = e as dynamic;
        msg = 'Hata: msg=${se.message} status=${se.statusCode} err=${se.error}';
      } catch (_) {}
      _showSnack(msg);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 12),
        ),
        backgroundColor: kBombBody,
      ),
    );
  }

  Future<void> _confirmClearMessages() async {
    if (_selectionMode) return;
    if (_messages.isEmpty) return;

    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Mesajları Temizle',
          style: GoogleFonts.orbitron(color: kAccentRed),
        ),
        content: Text(
          'Tüm mesajlar senin için gizlenir. Sohbet açık kalır, karşı taraf etkilenmez.',
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
              'Temizle',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );

    if (shouldClear == true) {
      final allIds = _messages.map((m) => (m['id'] ?? '').toString()).toSet();
      setState(() {
        _hiddenMessageIds.addAll(allIds);
        _selectedMessageIds.clear();
      });
      await _persistHiddenMessages();
    }
  }

  Future<void> _confirmCloseConversation() async {
    if (_selectionMode) return;

    if (_isConversationClosed) {
      _showSnack('Bu sohbet zaten kapatıldı.');
      return;
    }

    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          'Sohbeti Sil',
          style: GoogleFonts.orbitron(color: kAccentRed),
        ),
        content: Text(
          'Sohbet iki tarafta da kalır ama yazışma kapanır. Tekrar konuşmak için yeniden davet gönderilmesi gerekir. Devam edilsin mi?',
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
              'Sohbeti Kapat',
              style: GoogleFonts.orbitron(color: kTextPrimary),
            ),
          ),
        ],
      ),
    );

    if (shouldClose == true) {
      await _closeConversation();
    }
  }

  Future<void> _closeConversation() async {
    try {
      final vaultId = _myVaultId ??
          await _vaultService.checkMyConversationVault(widget.conversationId);
      if (vaultId == null) {
        _showSnack('Sohbet kapatılamadı.');
        return;
      }

      await _vaultService.closeConversation(widget.conversationId, vaultId);
      if (!mounted) return;
      setState(() => _isConversationClosed = true);
      _showSnack(
          'Sohbet kapatıldı. Tekrar konuşmak için yeni davet gönderilmeli.');
    } catch (_) {
      _showSnack('Sohbet kapatılamadı.');
    }
  }

  Future<void> _hideMessageLocally(String messageId) async {
    if (messageId.isEmpty) return;
    setState(() {
      _hiddenMessageIds.add(messageId);
      _selectedMessageIds.remove(messageId);
    });
    await _persistHiddenMessages();
  }

  Future<void> _hideSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    setState(() {
      _hiddenMessageIds.addAll(_selectedMessageIds);
      _selectedMessageIds.clear();
    });
    await _persistHiddenMessages();
  }

  void _onMessageLongPress(String messageId) {
    if (messageId.isEmpty) return;
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  Future<void> _onMessageTap({
    required String messageId,
    required _MessagePayload payload,
    required bool isMe,
  }) async {
    if (_selectionMode) {
      _onMessageLongPress(messageId);
      return;
    }
    if (payload.isImage && payload.url != null) {
      if (payload.oneTime && isMe) return;
      await _openImage(payload);
      if (payload.oneTime) {
        await _hideMessageLocally(messageId);
      }
      return;
    }
    if (payload.isFile && payload.url != null) {
      await _openFileInfo(payload);
      return;
    }
    if (payload.oneTime && !isMe) {
      await _hideMessageLocally(messageId);
    }
  }

  Future<void> _openImage(_MessagePayload payload) async {
    if (!mounted || payload.url == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(
                payload.url!,
                fit: BoxFit.contain,
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFileInfo(_MessagePayload payload) async {
    if (!mounted || payload.url == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          payload.fileName ?? 'Dosya',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: SelectableText(
          payload.url!,
          style: GoogleFonts.orbitron(color: kTextSecondary, fontSize: 11),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: payload.url!));
              if (ctx.mounted) Navigator.pop(ctx);
              _showSnack('Dosya linki kopyalandı.');
            },
            child: Text(
              'Linki Kopyala',
              style: GoogleFonts.orbitron(color: kAccentGreen, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Kapat',
              style: GoogleFonts.orbitron(color: kTextSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleMessages = _messages
        .where((m) => !_hiddenMessageIds.contains((m['id'] ?? '').toString()))
        .toList();

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        leading: IconButton(
          icon: Icon(
            _selectionMode ? Icons.close : Icons.arrow_back,
            color: kTextPrimary,
          ),
          onPressed: () {
            if (_selectionMode) {
              setState(() => _selectedMessageIds.clear());
            } else {
              context.pop();
            }
          },
        ),
        title: Text(
          _selectionMode
              ? '${_selectedMessageIds.length} seçili'
              : (_otherRumus != null ? '@$_otherRumus' : 'Mesajlar'),
          style: GoogleFonts.orbitron(
            color: kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: 'Sohbetten gizle',
              onPressed: _hideSelectedMessages,
              icon: const Icon(Icons.delete_outline, color: kAccentRed),
            )
          else ...[
            IconButton(
              tooltip: _timerEnabled
                  ? 'Zamanlayıcı açık (kapat)'
                  : 'Zamanlayıcı kapalı (aç)',
              onPressed: _toggleTimer,
              icon: Icon(
                _timerEnabled ? Icons.timer : Icons.timer_off_outlined,
                color: _timerEnabled ? kAccentGreen : kTextSecondary,
              ),
            ),
            IconButton(
              tooltip: 'Mesajları temizle',
              onPressed: _confirmClearMessages,
              icon: const Icon(Icons.delete_sweep_outlined, color: kAccentRed),
            ),
          ],
        ],
      ),
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _onUserActivity(),
        onPointerMove: (_) => _onUserActivity(),
        onPointerSignal: (_) => _onUserActivity(),
        child: Column(
          children: [
            if (_isConversationClosed)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kBombBody,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kBombBorder),
                ),
                child: Text(
                  'Bu sohbet kapatıldı. Tekrar yazışmak için yeni davet gönderin.',
                  style:
                      GoogleFonts.orbitron(color: kTextSecondary, fontSize: 11),
                ),
              ),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: kAccentRed),
                    )
                  : visibleMessages.isEmpty
                      ? Center(
                          child: Text(
                            'Henüz mesaj yok.\nBir şeyler yaz!',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.orbitron(
                              color: kTextSecondary,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          itemCount: visibleMessages.length,
                          itemBuilder: (context, index) {
                            final msg = visibleMessages[index];
                            final messageId = (msg['id'] ?? '').toString();
                            final payload = _MessagePayload.decode(
                              (msg['content'] ?? '').toString(),
                            );
                            final senderVaultId = (msg['sender_vault_id'] ?? '')
                                .toString()
                                .trim();
                            final myVaultId =
                                (_myVaultId ?? widget.activeVaultId ?? '')
                                    .toString()
                                    .trim();
                            final senderId =
                                (msg['sender_id'] ?? '').toString().trim();
                            final myId = (_activeUserId ?? '').trim();
                            final isMe = (senderVaultId.isNotEmpty &&
                                    myVaultId.isNotEmpty)
                                ? senderVaultId == myVaultId
                                : (myId.isNotEmpty &&
                                    senderId.isNotEmpty &&
                                    senderId == myId);
                            final isSelected =
                                _selectedMessageIds.contains(messageId);

                            return GestureDetector(
                              onLongPress: () => _onMessageLongPress(messageId),
                              onTap: () => _onMessageTap(
                                messageId: messageId,
                                payload: payload,
                                isMe: isMe,
                              ),
                              child: _MessageBubble(
                                payload: payload,
                                isMe: isMe,
                                isSelected: isSelected,
                                timestamp: msg['created_at'] as String?,
                              ),
                            );
                          },
                        ),
            ),
            _buildInputBar(),
            _buildQuickLockButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: kBackground,
        border: Border(
          top: BorderSide(color: kBombBorder, width: 1),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              onPressed: (_isSending || _isConversationClosed)
                  ? null
                  : _showAttachmentActions,
              icon: const Icon(Icons.attach_file, color: kTextSecondary),
              style: IconButton.styleFrom(
                backgroundColor: kBombBody,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _messageController,
              focusNode: _messageFocus,
              enabled: !_isConversationClosed,
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                fontSize: 14,
              ),
              decoration: const InputDecoration(
                hintText: 'Mesaj yaz...',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                if (!_isConversationClosed) _sendMessage();
              },
              maxLines: null,
              keyboardType: TextInputType.multiline,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            height: 48,
            child: _isSending
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: kAccentRed,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                : IconButton(
                    onPressed: _isConversationClosed ? null : _sendMessage,
                    icon: const Icon(Icons.send, color: kAccentRed),
                    style: IconButton.styleFrom(
                      backgroundColor: kBombBody,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickLockButton() {
    return Container(
      width: double.infinity,
      color: kBackground,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      child: SizedBox(
        height: 58,
        child: ElevatedButton.icon(
          onPressed: () {
            _leavingForBackground = true;
            context.go('/game');
          },
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

class _MessageBubble extends StatelessWidget {
  final _MessagePayload payload;
  final bool isMe;
  final bool isSelected;
  final String? timestamp;

  const _MessageBubble({
    required this.payload,
    required this.isMe,
    required this.isSelected,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    String timeStr = '';
    if (timestamp != null) {
      try {
        final dt = DateTime.parse(timestamp!).toLocal();
        timeStr =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.76,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? kAccentGreen.withAlpha(80)
              : (isMe ? kAccentRed.withAlpha(200) : kBombBody),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMe ? 14 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 14),
          ),
          border: Border.all(
            color: isSelected
                ? kAccentGreen
                : (isMe ? kAccentRed.withAlpha(80) : kBombBorder),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (payload.isText)
              Text(
                payload.text,
                style: GoogleFonts.orbitron(
                  color: kTextPrimary,
                  fontSize: 13,
                ),
              ),
            if (payload.isImage && payload.url != null) ...[
              Container(
                width: 160,
                height: 90,
                decoration: BoxDecoration(
                  color: kBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: payload.oneTime
                        ? kAccentRed.withAlpha(180)
                        : kBombBorder,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      payload.oneTime
                          ? Icons.timer_outlined
                          : Icons.image_outlined,
                      color: payload.oneTime ? kAccentRed : kTextSecondary,
                      size: 28,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      payload.oneTime ? 'Tek seferlik foto' : 'Foto',
                      style: GoogleFonts.orbitron(
                        color: payload.oneTime ? kAccentRed : kTextSecondary,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      'dokun → aç',
                      style: GoogleFonts.orbitron(
                        color: kTextSecondary,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (payload.isFile && payload.url != null) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file,
                      color: kTextSecondary, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      payload.fileName ?? 'Dosya',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.orbitron(
                        color: kTextPrimary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Dosya linki için dokun',
                style: GoogleFonts.orbitron(
                  color: kTextSecondary,
                  fontSize: 10,
                ),
              ),
            ],
            if (timeStr.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                timeStr,
                style: GoogleFonts.orbitron(
                  color: kTextPrimary.withAlpha(120),
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MessagePayload {
  static const prefix = '__boomyou_payload_v1__';
  static const typeText = 'text';
  static const typeImage = 'image';
  static const typeFile = 'file';

  final String type;
  final String text;
  final String? url;
  final String? fileName;
  final String? mimeType;
  final bool oneTime;

  const _MessagePayload({
    required this.type,
    required this.text,
    this.url,
    this.fileName,
    this.mimeType,
    this.oneTime = false,
  });

  bool get isText => type == typeText;
  bool get isImage => type == typeImage;
  bool get isFile => type == typeFile;

  String encode() {
    return '$prefix${jsonEncode({
          'type': type,
          'text': text,
          'url': url,
          'fileName': fileName,
          'mimeType': mimeType,
          'oneTime': oneTime,
        })}';
  }

  static _MessagePayload decode(String raw) {
    if (!raw.startsWith(prefix)) {
      return _MessagePayload(type: typeText, text: raw);
    }
    try {
      final data =
          jsonDecode(raw.substring(prefix.length)) as Map<String, dynamic>;
      return _MessagePayload(
        type: (data['type'] ?? typeText).toString(),
        text: (data['text'] ?? '').toString(),
        url: data['url']?.toString(),
        fileName: data['fileName']?.toString(),
        mimeType: data['mimeType']?.toString(),
        oneTime: data['oneTime'] == true,
      );
    } catch (_) {
      return _MessagePayload(type: typeText, text: raw);
    }
  }
}
