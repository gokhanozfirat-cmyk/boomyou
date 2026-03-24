import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/supabase_client.dart';
import 'auth_service.dart';

class VaultService {
  static final VaultService _instance = VaultService._internal();
  factory VaultService() => _instance;
  VaultService._internal();

  final AuthService _auth = AuthService();

  String _normalizeRumus(String rumus) => rumus.trim().toLowerCase();

  Future<void> _ensureUserProfile({String? fallbackRumus}) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final existing = await supabase
        .from('user_profiles')
        .select('id')
        .eq('id', userId)
        .maybeSingle();

    if (existing != null) return;

    final normalizedFallback =
        fallbackRumus == null ? null : _normalizeRumus(fallbackRumus);

    if (normalizedFallback == null || normalizedFallback.isEmpty) return;

    await supabase.from('user_profiles').insert({
      'id': userId,
      'rumus': normalizedFallback,
    });
  }

  String hashVaultCode(String code) {
    final bytes = utf8.encode(code);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> initDefaultVault() async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final existing =
        await supabase.from('vaults').select('id').eq('user_id', userId);

    if ((existing as List).isEmpty) {
      await supabase.from('vaults').insert({
        'user_id': userId,
        'code_hash': hashVaultCode('909090'),
        'is_setup': false,
      });
    }
  }

  Future<String?> checkCode(String code) async {
    final userId = _auth.currentUserId;
    if (userId == null) return null;

    final codeHash = hashVaultCode(code);

    final ownVault = await supabase
        .from('vaults')
        .select('id, created_at')
        .eq('user_id', userId)
        .eq('code_hash', codeHash)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (ownVault != null) {
      return ownVault['id'] as String?;
    }

    try {
      final access = await supabase
          .from('vault_access')
          .select('vault_id, created_at')
          .eq('user_id', userId)
          .eq('code_hash', codeHash)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (access != null) {
        return access['vault_id'] as String?;
      }
    } catch (_) {
      // Backward compatibility: vault_access may not exist yet.
    }

    return null;
  }

  Future<bool> isVaultSetup(String vaultId) async {
    final result = await supabase
        .from('vaults')
        .select('is_setup')
        .eq('id', vaultId)
        .maybeSingle();

    if (result == null) return false;
    return result['is_setup'] as bool? ?? false;
  }

  Future<String?> getCurrentUserRumus() async {
    final userId = _auth.currentUserId;
    if (userId == null) return null;

    final result = await supabase
        .from('user_profiles')
        .select('rumus')
        .eq('id', userId)
        .maybeSingle();

    return result?['rumus'] as String?;
  }

  Future<bool> isRumusTaken(String rumus) async {
    final normalized = _normalizeRumus(rumus);

    try {
      final vaultResult = await supabase
          .from('vaults')
          .select('id')
          .eq('rumus', normalized)
          .maybeSingle();
      if (vaultResult != null) return true;
    } catch (_) {
      // Backward compatibility: older schema may not have vault-level rumus yet.
    }

    final result = await supabase
        .from('user_profiles')
        .select('id')
        .eq('rumus', normalized)
        .maybeSingle();

    return result != null;
  }

  Future<void> setupVault(String vaultId, String rumus, String newCode) async {
    final normalizedRumus = _normalizeRumus(rumus);
    Map<String, dynamic>? duplicate;
    try {
      duplicate = await supabase
          .from('vaults')
          .select('id')
          .eq('rumus', normalizedRumus)
          .neq('id', vaultId)
          .maybeSingle();
    } catch (_) {
      // Backward compatibility: if rumus column does not exist, we continue.
    }
    if (duplicate != null) {
      throw Exception('Bu rumus zaten alınmış.');
    }

    try {
      await supabase.from('vaults').update({
        'rumus': normalizedRumus,
        'code_hash': hashVaultCode(newCode),
        'is_setup': true,
      }).eq('id', vaultId);
    } catch (_) {
      await supabase.from('vaults').update({
        'code_hash': hashVaultCode(newCode),
        'is_setup': true,
      }).eq('id', vaultId);
    }

    // Backward compatibility: only create profile if missing, do not overwrite
    // a previously chosen global rumus.
    await _ensureUserProfile(fallbackRumus: normalizedRumus);
  }

  Future<void> createVault(String code) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    await supabase.from('vaults').insert({
      'user_id': userId,
      'code_hash': hashVaultCode(code),
      'is_setup': false,
    });
  }

  Future<String> createVaultWithSetup(String rumus, String code) async {
    final userId = _auth.currentUserId;
    if (userId == null) {
      throw Exception('Kullanıcı bulunamadı.');
    }

    final normalizedRumus = _normalizeRumus(rumus);
    if (await isRumusTaken(normalizedRumus)) {
      throw Exception('Bu rumus zaten alınmış.');
    }

    Map<String, dynamic> created;
    try {
      created = await supabase
          .from('vaults')
          .insert({
            'user_id': userId,
            'rumus': normalizedRumus,
            'code_hash': hashVaultCode(code),
            'is_setup': true,
          })
          .select('id')
          .single();
    } catch (_) {
      // Backward compatibility: older schema without vaults.rumus column.
      created = await supabase
          .from('vaults')
          .insert({
            'user_id': userId,
            'code_hash': hashVaultCode(code),
            'is_setup': true,
          })
          .select('id')
          .single();
    }

    await _ensureUserProfile(fallbackRumus: normalizedRumus);
    return created['id'] as String;
  }

  Future<String> loginToExistingVault(String rumus, String code) async {
    final userId = _auth.currentUserId;
    if (userId == null) {
      throw Exception("Kullanıcı bulunamadı.");
    }

    final normalizedRumus = _normalizeRumus(rumus);
    final codeHash = hashVaultCode(code);

    try {
      final response = await supabase.rpc("login_existing_vault", params: {
        "input_rumus": normalizedRumus,
        "input_code": code,
      });

      if (response == null) {
        throw Exception("Rumus veya şifre yanlış.");
      }

      return response.toString();
    } catch (_) {
      // Backward compatibility fallback when RPC does not exist yet.
      final ownVault = await supabase
          .from("vaults")
          .select("id")
          .eq("user_id", userId)
          .eq("rumus", normalizedRumus)
          .eq("code_hash", codeHash)
          .maybeSingle();

      if (ownVault != null) {
        return ownVault["id"] as String;
      }

      throw Exception("Rumus veya şifre yanlış.");
    }
  }

  Future<String?> getVaultRumus(String vaultId) async {
    try {
      final result = await supabase
          .from('vaults')
          .select('rumus')
          .eq('id', vaultId)
          .maybeSingle();

      final vaultRumus = result?['rumus'] as String?;
      if (vaultRumus != null && vaultRumus.trim().isNotEmpty) {
        return vaultRumus;
      }
    } catch (_) {
      // Backward compatibility: older schema may not have vault rumus.
    }

    return getCurrentUserRumus();
  }

  Future<void> changeVaultCode(String vaultId, String newCode) async {
    await supabase.from('vaults').update({
      'code_hash': hashVaultCode(newCode),
    }).eq('id', vaultId);
  }

  Future<void> deleteVault(String vaultId) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    // Get conversations for this vault (either as initiator or participant)
    final convos = await supabase
        .from('conversations')
        .select('id')
        .or('initiator_vault_id.eq.$vaultId,participant_vault_id.eq.$vaultId');

    final convoIds = (convos as List).map((c) => c['id'] as String).toList();

    // Delete messages for those conversations
    if (convoIds.isNotEmpty) {
      await supabase
          .from('messages')
          .delete()
          .inFilter('conversation_id', convoIds);

      await supabase.from('conversations').delete().inFilter('id', convoIds);
    }

    // Delete vault row
    await supabase.from('vaults').delete().eq('id', vaultId);

    // Re-create default vault so user still has one
    await supabase.from('vaults').insert({
      'user_id': userId,
      'code_hash': hashVaultCode('909090'),
      'is_setup': false,
    });
  }

  Future<List<Map<String, dynamic>>> getVaults() async {
    final userId = _auth.currentUserId;
    if (userId == null) return [];

    final result = await supabase
        .from('vaults')
        .select('*')
        .eq('user_id', userId)
        .order('created_at');

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> getConversations(String vaultId) async {
    final result = await supabase
        .from('conversations')
        .select('*')
        .or('initiator_vault_id.eq.$vaultId,participant_vault_id.eq.$vaultId')
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<Map<String, int>> getUnreadCounts(
    String vaultId,
    List<String> conversationIds,
  ) async {
    final userId = _auth.currentUserId;
    if (userId == null) return <String, int>{};

    final normalizedConversationIds = conversationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (normalizedConversationIds.isEmpty) return <String, int>{};

    final unread = <String, int>{
      for (final id in normalizedConversationIds) id: 0,
    };

    final lastReadByConversation = <String, DateTime>{};
    try {
      final readRows = await supabase
          .from('conversation_reads')
          .select('conversation_id, last_read_at')
          .eq('vault_id', vaultId)
          .inFilter('conversation_id', normalizedConversationIds);

      for (final row in List<Map<String, dynamic>>.from(readRows as List)) {
        final conversationId = (row['conversation_id'] ?? '').toString();
        final readAt = _parseTimestamp(row['last_read_at']);
        if (conversationId.isEmpty || readAt == null) continue;
        lastReadByConversation[conversationId] = readAt;
      }
    } catch (_) {
      // Backward compatibility: table may not exist yet.
    }

    final rows = await supabase
        .from('messages')
        .select('conversation_id, created_at, sender_id, sender_vault_id')
        .inFilter('conversation_id', normalizedConversationIds)
        .order('created_at');

    for (final row in List<Map<String, dynamic>>.from(rows as List)) {
      final conversationId = (row['conversation_id'] ?? '').toString();
      if (conversationId.isEmpty || !unread.containsKey(conversationId)) {
        continue;
      }

      final createdAt = _parseTimestamp(row['created_at']);
      if (createdAt == null) continue;

      final lastRead = lastReadByConversation[conversationId];
      if (lastRead != null && !createdAt.isAfter(lastRead)) continue;

      final senderVaultId = (row['sender_vault_id'] ?? '').toString().trim();
      final senderId = (row['sender_id'] ?? '').toString().trim();
      final isMine = senderVaultId.isNotEmpty
          ? senderVaultId == vaultId
          : (senderId.isNotEmpty && senderId == userId);
      if (isMine) continue;

      unread[conversationId] = (unread[conversationId] ?? 0) + 1;
    }

    return unread;
  }

  Future<void> markConversationRead(
    String conversationId,
    String vaultId, {
    DateTime? readAt,
  }) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final now = (readAt ?? DateTime.now()).toUtc().toIso8601String();
    try {
      await supabase.from('conversation_reads').upsert(
        {
          'conversation_id': conversationId,
          'vault_id': vaultId,
          'user_id': userId,
          'last_read_at': now,
          'updated_at': now,
        },
        onConflict: 'conversation_id,vault_id',
      );
    } catch (_) {
      // Backward compatibility: table may not exist yet.
    }
  }

  Future<void> upsertPushToken(
    String token, {
    required String platform,
    required bool notificationsEnabled,
  }) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await supabase.from('device_push_tokens').upsert(
        {
          'token': normalizedToken,
          'user_id': userId,
          'platform': platform,
          'notifications_enabled': notificationsEnabled,
          'updated_at': now,
        },
        onConflict: 'token',
      );
    } catch (_) {
      // Backward compatibility: table may not exist yet.
    }
  }

  Future<void> clearPushTokensForCurrentUser() async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await supabase.from('device_push_tokens').update({
        'notifications_enabled': false,
        'updated_at': now,
      }).eq('user_id', userId);
    } catch (_) {
      // Backward compatibility: table may not exist yet.
    }
  }

  Future<String?> getRumusByUserId(String userId) async {
    final result = await supabase
        .from('user_profiles')
        .select('rumus')
        .eq('id', userId)
        .maybeSingle();

    final profileRumus = result?['rumus'] as String?;
    if (profileRumus != null && profileRumus.trim().isNotEmpty) {
      return profileRumus;
    }

    final fallbackVault = await supabase
        .from('vaults')
        .select('rumus')
        .eq('user_id', userId)
        .order('created_at')
        .limit(1)
        .maybeSingle();

    return fallbackVault?['rumus'] as String?;
  }

  Future<List<Map<String, dynamic>>> getPendingInvites(
      {String? vaultId}) async {
    final rumus = vaultId == null
        ? await getCurrentUserRumus()
        : await getVaultRumus(vaultId);
    if (rumus == null) return [];

    final result = await supabase
        .from('invites')
        .select('*')
        .eq('to_rumus', rumus)
        .eq('status', 'pending')
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> sendInvite(String toRumus, {String? fromVaultId}) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;
    final fromRumus = fromVaultId == null
        ? await getCurrentUserRumus()
        : await getVaultRumus(fromVaultId);
    if (fromRumus == null) return;

    try {
      await supabase.from('invites').insert({
        'from_user_id': userId,
        'from_vault_id': fromVaultId,
        'from_rumus': fromRumus,
        'to_rumus': _normalizeRumus(toRumus),
        'status': 'pending',
      });
    } catch (_) {
      await supabase.from('invites').insert({
        'from_user_id': userId,
        'from_rumus': fromRumus,
        'to_rumus': _normalizeRumus(toRumus),
        'status': 'pending',
      });
    }
  }

  Future<void> acceptInvite(
      String inviteId, String vaultId, String fromUserId) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    Map<String, dynamic>? invite;
    try {
      invite = await supabase
          .from('invites')
          .select('from_vault_id, from_user_id')
          .eq('id', inviteId)
          .maybeSingle();
    } catch (_) {
      invite = await supabase
          .from('invites')
          .select('from_user_id')
          .eq('id', inviteId)
          .maybeSingle();
    }

    final resolvedFromUserId = invite?['from_user_id'] as String? ?? fromUserId;
    final fromVaultId = invite?['from_vault_id'] as String?;

    // Create conversation
    final conv = await supabase
        .from('conversations')
        .insert({
          'initiator_id': resolvedFromUserId,
          'participant_id': userId,
          'initiator_vault_id': fromVaultId,
          'participant_vault_id': vaultId,
        })
        .select('id')
        .single();

    // Update invite with conversation_id and mark accepted
    await supabase.from('invites').update({
      'status': 'accepted',
      'conversation_id': conv['id'],
    }).eq('id', inviteId);
  }

  Future<void> declineInvite(String inviteId) async {
    await supabase.from('invites').update({
      'status': 'declined',
    }).eq('id', inviteId);
  }

  Future<List<Map<String, dynamic>>> getMessages(String conversationId) async {
    final result = await supabase
        .from('messages')
        .select('*')
        .eq('conversation_id', conversationId)
        .order('created_at')
        .order('id');

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<String?> checkMyConversationVault(String conversationId) async {
    final userId = _auth.currentUserId;
    if (userId == null) return null;

    final conv = await supabase
        .from('conversations')
        .select(
            'initiator_id, participant_id, initiator_vault_id, participant_vault_id')
        .eq('id', conversationId)
        .maybeSingle();

    if (conv == null) return null;

    final initiatorId = conv['initiator_id'] as String?;
    final participantId = conv['participant_id'] as String?;
    if (initiatorId == userId) {
      return conv['initiator_vault_id'] as String?;
    }
    if (participantId == userId) {
      return conv['participant_vault_id'] as String?;
    }
    return null;
  }

  Future<bool> isConversationClosed(String conversationId) async {
    try {
      final conv = await supabase
          .from('conversations')
          .select('is_closed')
          .eq('id', conversationId)
          .maybeSingle();

      return conv?['is_closed'] as bool? ?? false;
    } catch (_) {
      // Backward compatibility: older schema may not have is_closed.
      return false;
    }
  }

  Future<void> closeConversation(String conversationId, String vaultId) async {
    await supabase.from('conversations').update({
      'is_closed': true,
      'closed_at': DateTime.now().toUtc().toIso8601String(),
      'closed_by_vault_id': vaultId,
    }).eq('id', conversationId);
  }

  Future<void> sendMessage(
    String conversationId,
    String content, {
    String? senderVaultId,
  }) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final closed = await isConversationClosed(conversationId);
    if (closed) {
      throw Exception('SOHBET_KAPALI');
    }

    final resolvedVaultId =
        senderVaultId ?? await checkMyConversationVault(conversationId);

    final payload = <String, dynamic>{
      'conversation_id': conversationId,
      'sender_id': userId,
      'content': content,
      if (resolvedVaultId != null) 'sender_vault_id': resolvedVaultId,
    };

    try {
      await supabase.from('messages').insert(payload);
      unawaited(
        _triggerPushNotification(
          conversationId: conversationId,
          senderVaultId: resolvedVaultId,
          messagePreview: content,
        ),
      );
    } catch (e) {
      // Backward compatibility: older schema may not have sender_vault_id.
      if (payload.containsKey('sender_vault_id')) {
        final fallbackPayload = Map<String, dynamic>.from(payload)
          ..remove('sender_vault_id');
        await supabase.from('messages').insert(fallbackPayload);
        unawaited(
          _triggerPushNotification(
            conversationId: conversationId,
            senderVaultId: resolvedVaultId,
            messagePreview: content,
          ),
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _triggerPushNotification({
    required String conversationId,
    required String? senderVaultId,
    required String messagePreview,
  }) async {
    final trimmedPreview = messagePreview.trim();
    final preview = trimmedPreview.length > 160
        ? '${trimmedPreview.substring(0, 160)}...'
        : trimmedPreview;

    try {
      await supabase.functions.invoke(
        'send-message-push',
        body: <String, dynamic>{
          'conversationId': conversationId,
          'senderVaultId': senderVaultId,
          'messagePreview': preview,
        },
      );
    } catch (_) {
      // Push is best-effort and should never block chat send.
    }
  }

  DateTime? _parseTimestamp(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return null;
    try {
      return DateTime.parse(raw).toUtc();
    } catch (_) {
      return null;
    }
  }
}
