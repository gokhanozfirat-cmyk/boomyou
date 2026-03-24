import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/vault_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;

  const ChatScreen({super.key, required this.conversationId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final VaultService _vaultService = VaultService();
  final AuthService _authService = AuthService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocus = FocusNode();
  List<Map<String, dynamic>> _messages = [];
  String? _myUserId;
  String? _otherRumus;
  RealtimeChannel? _subscription;
  bool _isLoading = true;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _myUserId = _authService.currentUserId;
    _loadInitialData();
    _subscribeToMessages();
  }

  @override
  void dispose() {
    _subscription?.unsubscribe();
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    try {
      final msgs = await _vaultService.getMessages(widget.conversationId);
      // Load other user's rumus
      final convResult = await supabase
          .from('conversations')
          .select('initiator_id, participant_id')
          .eq('id', widget.conversationId)
          .maybeSingle();

      String? otherRumus;
      if (convResult != null) {
        final initiatorId = convResult['initiator_id'] as String?;
        final participantId = convResult['participant_id'] as String?;
        final otherId = initiatorId == _myUserId ? participantId : initiatorId;
        if (otherId != null) {
          otherRumus = await _vaultService.getRumusByUserId(otherId);
        }
      }

      if (mounted) {
        setState(() {
          _messages = msgs;
          _otherRumus = otherRumus;
          _isLoading = false;
        });
        _scrollToBottom();
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
                // Avoid duplicates
                final exists = _messages.any(
                    (m) => m['id'] == newMessage['id']);
                if (!exists) _messages.add(newMessage);
              });
              _scrollToBottom();
            }
          },
        )
        .subscribe();
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
    final content = _messageController.text.trim();
    if (content.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      await _vaultService.sendMessage(widget.conversationId, content);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Mesaj gönderilemedi.',
              style: GoogleFonts.orbitron(color: kTextPrimary, fontSize: 13),
            ),
            backgroundColor: kBombBody,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: kBackground,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kTextPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text(
          _otherRumus != null ? '@$_otherRumus' : 'Mesajlar',
          style: GoogleFonts.orbitron(
            color: kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: kAccentRed))
                : _messages.isEmpty
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
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isMe =
                              msg['sender_id'] == _myUserId;
                          return _MessageBubble(
                            content: msg['content'] as String,
                            isMe: isMe,
                            timestamp: msg['created_at'] as String?,
                          );
                        },
                      ),
          ),
          _buildInputBar(),
        ],
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
          Expanded(
            child: TextField(
              controller: _messageController,
              focusNode: _messageFocus,
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
              onSubmitted: (_) => _sendMessage(),
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
                    onPressed: _sendMessage,
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
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isMe;
  final String? timestamp;

  const _MessageBubble({
    required this.content,
    required this.isMe,
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
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? kAccentRed.withAlpha(200) : kBombBody,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMe ? 14 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 14),
          ),
          border: Border.all(
            color: isMe ? kAccentRed.withAlpha(80) : kBombBorder,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              content,
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                fontSize: 13,
              ),
            ),
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
