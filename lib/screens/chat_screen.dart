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
  final bool historyLocked;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.activeVaultId,
    this.historyLocked = false,
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
  final Set<String> _locallyConsumedOneTimeIds = {};

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
  bool _isExpiringMessages = false;

  static const Duration _idleTimeout = Duration(seconds: 10);
  static const Duration _expireDuration = Duration(hours: 1);

  String get _hiddenStoreKey =>
      'chat_hidden_${_myUserId ?? "anon"}_${widget.conversationId}';
  String get _oneTimeConsumedStoreKey =>
      'chat_one_time_consumed_${_myUserId ?? "anon"}_${widget.conversationId}';

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
    _startAutoExpireTimer();
    _loadInitialData();
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
    });

    _loadHiddenMessages();
    _startAutoExpireTimer();
    _loadInitialData();
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

    // last_read_at is already persisted in conversation_reads by markConversationRead above.
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

  void _startAutoExpireTimer() {
    if (widget.historyLocked) return;
    _autoExpireTimer?.cancel();
    // Check every minute
    _autoExpireTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _expireReadMessages();
    });
    // Also check immediately
    _expireReadMessages();
  }

  void _autoHideOpenedOneTimeMessages() {
    const prefix = _MessagePayload.prefix;
    final toHide = <String>[];
    for (final msg in _messages) {
      final id = (msg['id'] ?? '').toString();
      if (id.isEmpty || _hiddenMessageIds.contains(id)) continue;
      if (msg['is_opened'] != true) continue;
      final content = (msg['content'] ?? '').toString();
      if (!content.startsWith(prefix)) continue;
      try {
        final payload = _MessagePayload.decode(content);
        if (payload.oneTime) toHide.add(id);
      } catch (_) {}
    }
    if (toHide.isEmpty) return;
    setState(() => _hiddenMessageIds.addAll(toHide));
  }

  Future<void> _expireReadMessages() async {
    if (!mounted || _isExpiringMessages || widget.historyLocked) return;
    _isExpiringMessages = true;

    try {
      final currentVaultId = (_myVaultId ?? widget.activeVaultId ?? '').trim();
      final resolvedVaultId = currentVaultId.isNotEmpty
          ? currentVaultId
          : await _vaultService.checkMyConversationVault(widget.conversationId);
      if (resolvedVaultId == null || resolvedVaultId.isEmpty) return;
      _myVaultId ??= resolvedVaultId;

      final readAt = await _vaultService.getConversationLastReadAt(
        widget.conversationId,
        resolvedVaultId,
      );
      if (readAt == null) return;

      // Archive only messages that are both:
      // 1) already read in this vault, and
      // 2) older than one hour from now.
      final nowUtc = DateTime.now().toUtc();
      final oneHourAgo = nowUtc.subtract(_expireDuration);
      final archiveBefore = readAt.isBefore(oneHourAgo) ? readAt : oneHourAgo;

      final archivedCount = await _vaultService.archiveExpiredReadMessages(
        conversationId: widget.conversationId,
        vaultId: resolvedVaultId,
        readBefore: archiveBefore,
      );
      if (!mounted || archivedCount <= 0) return;

      // Refresh from DB so UI removes only what was actually archived.
      var refreshed = await _vaultService.getMessages(widget.conversationId);
      refreshed = refreshed
          .where((m) => !_locallyConsumedOneTimeIds
              .contains((m['id'] ?? '').toString().trim()))
          .toList();
      refreshed.sort(_compareMessageOrder);

      if (!mounted) return;
      final refreshedIds = refreshed
          .map((m) => (m['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();

      setState(() {
        _messages = refreshed;
        _hiddenMessageIds.removeWhere((id) => !refreshedIds.contains(id));
        _selectedMessageIds.removeWhere((id) => !refreshedIds.contains(id));
      });
    } finally {
      _isExpiringMessages = false;
    }
  }

  Future<void> _loadHiddenMessages() async {
    final vaultId = (widget.activeVaultId ?? _myVaultId ?? '').trim();
    if (vaultId.isEmpty) return;
    final ids = await _vaultService.loadHiddenMessageIds(vaultId);
    if (!mounted) return;
    setState(() {
      _hiddenMessageIds
        ..clear()
        ..addAll(ids);
    });
  }

  Future<void> _loadLocallyConsumedOneTimeMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final ids =
        prefs.getStringList(_oneTimeConsumedStoreKey) ?? const <String>[];
    _locallyConsumedOneTimeIds
      ..clear()
      ..addAll(ids.where((id) => id.trim().isNotEmpty).map((id) => id.trim()));
  }

  Future<void> _persistLocallyConsumedOneTimeMessages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _oneTimeConsumedStoreKey,
      _locallyConsumedOneTimeIds.toList(),
    );
  }

  Future<void> _consumeOneTimeLocally(String messageId) async {
    final normalized = messageId.trim();
    if (normalized.isEmpty) return;
    if (_locallyConsumedOneTimeIds.add(normalized)) {
      await _persistLocallyConsumedOneTimeMessages();
    }
  }

  Future<void> _persistHiddenMessages() async {
    final vaultId = (_myVaultId ?? widget.activeVaultId ?? '').trim();
    if (vaultId.isEmpty || _hiddenMessageIds.isEmpty) return;
    await _vaultService.hideMessagesForVault(
        vaultId, Set.from(_hiddenMessageIds));
  }

  Future<void> _loadInitialData() async {
    try {
      _myUserId = _activeUserId;
      await _loadLocallyConsumedOneTimeMessages();
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

      final historyLocked = widget.historyLocked;
      List<Map<String, dynamic>> msgs = <Map<String, dynamic>>[];
      if (!historyLocked) {
        msgs = await _vaultService.getMessages(widget.conversationId);
        msgs = msgs
            .where((m) => !_locallyConsumedOneTimeIds
                .contains((m['id'] ?? '').toString().trim()))
            .toList();
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
        _subscribeToMessages();
        _scrollToBottom();
        await _markConversationReadNow();
        await _loadHiddenMessages();
        if (!historyLocked) {
          _autoHideOpenedOneTimeMessages();
          unawaited(_expireReadMessages());
          for (final consumedId in _locallyConsumedOneTimeIds) {
            unawaited(_vaultService.archiveOneTimeMessage(consumedId));
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToMessages() {
    if (_subscription != null) return;
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
                final messageId = (newMessage['id'] ?? '').toString().trim();
                if (!exists &&
                    messageId.isNotEmpty &&
                    !_locallyConsumedOneTimeIds.contains(messageId)) {
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
    // With reverse:true the newest messages are at scroll offset 0.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients &&
          _scrollController.position.minScrollExtent <
              _scrollController.position.maxScrollExtent) {
        _scrollController.animateTo(
          _scrollController.position.minScrollExtent,
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

      final payload = _MessagePayload(
        type: type,
        text: '',
        path: objectPath,
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

  Future<void> _hideMessageLocally(
    String messageId, {
    bool consumeOneTime = false,
  }) async {
    if (messageId.isEmpty) return;
    if (consumeOneTime) {
      await _consumeOneTimeLocally(messageId);
      final archived = await _vaultService.archiveOneTimeMessage(messageId);
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => (m['id'] ?? '').toString() == messageId);
        _selectedMessageIds.remove(messageId);
        _hiddenMessageIds.add(messageId);
      });
      if (!archived) {
        await _persistHiddenMessages();
      }
      return;
    }

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
  }) async {
    if (_selectionMode) {
      _onMessageLongPress(messageId);
      return;
    }
    if (payload.isImage && payload.hasAttachmentRef) {
      if (payload.oneTime) {
        final opened = await _openImage(payload);
        if (opened) {
          await _hideMessageLocally(messageId, consumeOneTime: true);
        }
        return;
      }
      await _openImage(payload);
      return;
    }
    if (payload.isFile && payload.hasAttachmentRef) {
      await _openFileInfo(payload);
      return;
    }
    if (payload.oneTime) {
      await _hideMessageLocally(messageId, consumeOneTime: true);
    }
  }

  Future<String?> _createSignedAttachmentUrl(
    _MessagePayload payload, {
    int expiresInSeconds = 3600,
  }) async {
    final objectPath = payload.resolvedPath;
    if (objectPath == null || objectPath.isEmpty) return null;
    try {
      return await supabase.storage
          .from(_MessagePayload.attachmentBucket)
          .createSignedUrl(objectPath, expiresInSeconds);
    } catch (e) {
      debugPrint('Signed URL create failed for $objectPath: $e');
      return null;
    }
  }

  Future<bool> _openImage(_MessagePayload payload) async {
    if (!mounted) return false;
    final objectPath = payload.resolvedPath;
    if (objectPath == null || objectPath.isEmpty) {
      _showSnack('Görsel yolu bulunamadı.');
      return false;
    }

    Uint8List? bytes;
    try {
      bytes = await supabase.storage
          .from(_MessagePayload.attachmentBucket)
          .download(objectPath);
    } catch (e) {
      debugPrint('Attachment download failed for $objectPath: $e');
    }

    if (bytes != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              InteractiveViewer(
                child: Image.memory(
                  bytes!,
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
      return true;
    }

    final signedUrl = await _createSignedAttachmentUrl(
      payload,
      expiresInSeconds: 900,
    );
    if (!mounted || signedUrl == null) {
      _showSnack('Görsele erişilemedi.');
      return false;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(
                signedUrl,
                fit: BoxFit.contain,
                errorBuilder: (_, err, __) {
                  final detail = err.toString();
                  return Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Görsel yüklenemedi.\n$detail',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.orbitron(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  );
                },
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
    return false;
  }

  Future<void> _openFileInfo(_MessagePayload payload) async {
    if (!mounted) return;
    final signedUrl = await _createSignedAttachmentUrl(payload);
    if (!mounted || signedUrl == null) {
      _showSnack('Dosyaya erişilemedi.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBombBody,
        title: Text(
          payload.fileName ?? 'Dosya',
          style: GoogleFonts.orbitron(color: kTextPrimary),
        ),
        content: SelectableText(
          signedUrl,
          style: GoogleFonts.orbitron(color: kTextSecondary, fontSize: 11),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: signedUrl));
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
    final visibleMessages = _messages.where((m) {
      final id = (m['id'] ?? '').toString().trim();
      return !_hiddenMessageIds.contains(id) &&
          !_locallyConsumedOneTimeIds.contains(id);
    }).toList();

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
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          itemCount: visibleMessages.length,
                          itemBuilder: (context, index) {
                            final msg = visibleMessages[
                                visibleMessages.length - 1 - index];
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
            if (payload.isImage && payload.hasAttachmentRef) ...[
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
            if (payload.isFile && payload.hasAttachmentRef) ...[
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
  static const attachmentBucket = 'chat_attachments';
  static const typeText = 'text';
  static const typeImage = 'image';
  static const typeFile = 'file';

  final String type;
  final String text;
  final String? url;
  final String? path;
  final String? fileName;
  final String? mimeType;
  final bool oneTime;

  const _MessagePayload({
    required this.type,
    required this.text,
    this.url,
    this.path,
    this.fileName,
    this.mimeType,
    this.oneTime = false,
  });

  bool get isText => type == typeText;
  bool get isImage => type == typeImage;
  bool get isFile => type == typeFile;
  bool get hasAttachmentRef =>
      (resolvedPath?.isNotEmpty ?? false) || (url?.trim().isNotEmpty ?? false);

  String? get resolvedPath {
    final direct = (path ?? '').trim();
    if (direct.isNotEmpty) return direct;

    final rawUrl = (url ?? '').trim();
    if (rawUrl.isEmpty) return null;

    try {
      final parsed = Uri.parse(rawUrl);
      final marker = '/$attachmentBucket/';
      final fullPath = parsed.path;
      final markerIndex = fullPath.indexOf(marker);
      if (markerIndex == -1) return null;
      final extracted = fullPath.substring(markerIndex + marker.length).trim();
      if (extracted.isEmpty) return null;
      return Uri.decodeComponent(extracted);
    } catch (_) {
      return null;
    }
  }

  String encode() {
    return '$prefix${jsonEncode({
          'type': type,
          'text': text,
          'url': url,
          'path': path,
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
        path: data['path']?.toString(),
        fileName: data['fileName']?.toString(),
        mimeType: data['mimeType']?.toString(),
        oneTime: data['oneTime'] == true,
      );
    } catch (_) {
      return _MessagePayload(type: typeText, text: raw);
    }
  }
}
