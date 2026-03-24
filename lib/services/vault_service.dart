import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/supabase_client.dart';
import 'auth_service.dart';

class VaultService {
  static final VaultService _instance = VaultService._internal();
  factory VaultService() => _instance;
  VaultService._internal();

  final AuthService _auth = AuthService();

  String hashVaultCode(String code) {
    final bytes = utf8.encode(code);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> initDefaultVault() async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    final existing = await supabase
        .from('vaults')
        .select('id')
        .eq('user_id', userId);

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
    final result = await supabase
        .from('vaults')
        .select('id')
        .eq('user_id', userId)
        .eq('code_hash', codeHash)
        .maybeSingle();

    if (result == null) return null;
    return result['id'] as String?;
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
    final result = await supabase
        .from('user_profiles')
        .select('id')
        .eq('rumus', rumus)
        .maybeSingle();

    return result != null;
  }

  Future<void> setupVault(
      String vaultId, String rumus, String newCode) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    // Upsert user profile with rumus
    await supabase.from('user_profiles').upsert({
      'id': userId,
      'rumus': rumus,
    });

    // Update vault: set new code hash, mark as setup
    await supabase.from('vaults').update({
      'code_hash': hashVaultCode(newCode),
      'is_setup': true,
    }).eq('id', vaultId);
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

      await supabase
          .from('conversations')
          .delete()
          .inFilter('id', convoIds);
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

  Future<List<Map<String, dynamic>>> getConversations(
      String vaultId) async {
    final userId = _auth.currentUserId;
    if (userId == null) return [];

    final result = await supabase
        .from('conversations')
        .select('*')
        .or('initiator_vault_id.eq.$vaultId,participant_vault_id.eq.$vaultId')
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<String?> getRumusByUserId(String userId) async {
    final result = await supabase
        .from('user_profiles')
        .select('rumus')
        .eq('id', userId)
        .maybeSingle();

    return result?['rumus'] as String?;
  }

  Future<List<Map<String, dynamic>>> getPendingInvites() async {
    final rumus = await getCurrentUserRumus();
    if (rumus == null) return [];

    final result = await supabase
        .from('invites')
        .select('*')
        .eq('to_rumus', rumus)
        .eq('status', 'pending')
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> sendInvite(String toRumus) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;
    final fromRumus = await getCurrentUserRumus();
    if (fromRumus == null) return;

    await supabase.from('invites').insert({
      'from_user_id': userId,
      'from_rumus': fromRumus,
      'to_rumus': toRumus,
      'status': 'pending',
    });
  }

  Future<void> acceptInvite(
      String inviteId, String vaultId, String fromUserId) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    // Create conversation
    final conv = await supabase.from('conversations').insert({
      'initiator_id': fromUserId,
      'participant_id': userId,
      'participant_vault_id': vaultId,
    }).select('id').single();

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

  Future<List<Map<String, dynamic>>> getMessages(
      String conversationId) async {
    final result = await supabase
        .from('messages')
        .select('*')
        .eq('conversation_id', conversationId)
        .order('created_at');

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> sendMessage(String conversationId, String content) async {
    final userId = _auth.currentUserId;
    if (userId == null) return;

    await supabase.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': userId,
      'content': content,
    });
  }
}
