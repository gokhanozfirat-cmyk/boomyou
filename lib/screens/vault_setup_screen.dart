import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme.dart';
import '../services/vault_service.dart';

class VaultSetupScreen extends StatefulWidget {
  final String vaultId;

  const VaultSetupScreen({super.key, required this.vaultId});

  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen> {
  final TextEditingController _rumusController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _codeConfirmController = TextEditingController();
  final VaultService _vaultService = VaultService();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _rumusController.dispose();
    _codeController.dispose();
    _codeConfirmController.dispose();
    super.dispose();
  }

  Future<void> _onSetup() async {
    final rumus = _rumusController.text.trim();
    final code = _codeController.text.trim();
    final codeConfirm = _codeConfirmController.text.trim();

    if (rumus.isEmpty) {
      setState(() => _errorMessage = 'Rumus boş olamaz.');
      return;
    }

    if (rumus.length < 3) {
      setState(() => _errorMessage = 'Rumus en az 3 karakter olmalı.');
      return;
    }

    if (code.length != 6) {
      setState(() => _errorMessage = 'Şifre 6 haneli olmalı.');
      return;
    }

    if (code != codeConfirm) {
      setState(() => _errorMessage = 'Şifreler eşleşmiyor.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final taken = await _vaultService.isRumusTaken(rumus);
      if (taken) {
        setState(() {
          _errorMessage = 'Bu rumus zaten alınmış. Başka bir tane seç.';
          _isLoading = false;
        });
        return;
      }

      await _vaultService.setupVault(widget.vaultId, rumus, code);

      if (mounted) {
        context.replace('/vault/${widget.vaultId}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Bir hata oluştu. Tekrar dene.';
        _isLoading = false;
      });
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
          onPressed: () => context.go('/game'),
        ),
        title: Text(
          'Alan Kurulumu',
          style: GoogleFonts.orbitron(
            color: kTextPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bu alan için bir rumus seç',
                style: GoogleFonts.orbitron(
                  color: kTextSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _rumusController,
                style: GoogleFonts.orbitron(color: kTextPrimary),
                decoration: const InputDecoration(
                  hintText: 'Rumus (takma ad)',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 24),
              Text(
                'Bu alana giriş şifren (6 haneli)',
                style: GoogleFonts.orbitron(
                  color: kTextSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _codeController,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                style: GoogleFonts.orbitron(
                  color: kTextPrimary,
                  letterSpacing: 8,
                  fontSize: 20,
                ),
                decoration: const InputDecoration(
                  hintText: '••••••',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _codeConfirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                style: GoogleFonts.orbitron(
                  color: kTextPrimary,
                  letterSpacing: 8,
                  fontSize: 20,
                ),
                decoration: const InputDecoration(
                  hintText: 'Şifre tekrar',
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _onSetup(),
              ),
              const SizedBox(height: 8),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _errorMessage!,
                    style: GoogleFonts.orbitron(
                      color: kAccentRed,
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _onSetup,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccentRed,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: kTextPrimary,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Kurulumu Tamamla',
                          style: GoogleFonts.orbitron(
                            color: kTextPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
