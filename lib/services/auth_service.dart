import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  Future<void> ensureAnonymousAuth() async {
    final session = supabase.auth.currentSession;
    if (session == null) {
      await supabase.auth.signInAnonymously();
    }
  }

  String? get currentUserId => supabase.auth.currentUser?.id;

  User? get currentUser => supabase.auth.currentUser;
}
