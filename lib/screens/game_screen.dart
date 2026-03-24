import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme.dart';
import '../models/bomb.dart';
import '../services/vault_service.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with TickerProviderStateMixin {
  final List<Bomb> _bombs = [];
  int _lives = 4;
  bool _gameOver = false;
  bool _showSuccessFlash = false;
  bool _showFailFlash = false;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final Random _random = Random();
  final VaultService _vaultService = VaultService();

  late AnimationController _gameLoopController;
  Timer? _spawnTimer;
  DateTime? _lastFrameTime;
  int _bombIdCounter = 0;

  static const double _bombWidth = 70.0;
  static const double _bombHeight = 70.0;

  @override
  void initState() {
    super.initState();

    _gameLoopController = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    )..addListener(_onGameTick);

    _gameLoopController.forward();
    _scheduleNextSpawn();
  }

  @override
  void dispose() {
    _gameLoopController.dispose();
    _spawnTimer?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onGameTick() {
    if (_gameOver) return;

    final now = DateTime.now();
    if (_lastFrameTime == null) {
      _lastFrameTime = now;
      return;
    }

    final elapsed =
        now.difference(_lastFrameTime!).inMicroseconds / 1000000.0;
    _lastFrameTime = now;

    if (!mounted) return;

    setState(() {
      final toRemove = <String>[];
      for (final bomb in _bombs) {
        bomb.yPosition += bomb.speed * elapsed;
        if (bomb.yPosition >= 1.0) {
          toRemove.add(bomb.id);
          _lives--;
        }
      }
      _bombs.removeWhere((b) => toRemove.contains(b.id));
      if (_lives <= 0) {
        _lives = 0;
        _gameOver = true;
        _spawnTimer?.cancel();
      }
    });
  }

  void _scheduleNextSpawn() {
    final delay = 2000 + _random.nextInt(1001);
    _spawnTimer = Timer(Duration(milliseconds: delay), () {
      if (!_gameOver && mounted) {
        _spawnBomb();
        _scheduleNextSpawn();
      }
    });
  }

  void _spawnBomb() {
    if (_bombs.length >= 5) return;
    setState(() {
      _bombs.add(Bomb(
        id: 'bomb_${_bombIdCounter++}',
        number: 1 + _random.nextInt(9),
        yPosition: 0.0,
        xPosition: 0.05 + _random.nextDouble() * 0.80,
        speed: 0.04 + _random.nextDouble() * 0.06,
      ));
    });
  }

  int get _bombSum => _bombs.fold(0, (sum, b) => sum + b.number);

  Future<void> _onSubmit() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    _inputController.clear();

    // 1. Check vault codes first
    final vaultId = await _vaultService.checkCode(input);
    if (!mounted) return;
    if (vaultId != null) {
      _gameLoopController.stop();
      _spawnTimer?.cancel();
      final isSetup = await _vaultService.isVaultSetup(vaultId);
      if (!mounted) return;
      if (isSetup) {
        // ignore: use_build_context_synchronously
        await context.push('/vault/$vaultId');
      } else {
        // ignore: use_build_context_synchronously
        await context.push('/vault-setup/$vaultId');
      }
      if (mounted) {
        _lastFrameTime = null;
        _gameLoopController.forward();
        _scheduleNextSpawn();
        _inputFocus.requestFocus();
      }
      return;
    }

    // 2. Check sum of visible bombs
    final typedValue = int.tryParse(input);
    if (typedValue != null && typedValue == _bombSum && _bombs.isNotEmpty) {
      setState(() {
        _bombs.clear();
        _showSuccessFlash = true;
      });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() => _showSuccessFlash = false);
        }
      });
      return;
    }

    // 3. Fail flash
    setState(() => _showFailFlash = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _showFailFlash = false);
      }
    });
    _inputFocus.requestFocus();
  }

  void _restartGame() {
    setState(() {
      _bombs.clear();
      _lives = 4;
      _gameOver = false;
      _showSuccessFlash = false;
      _showFailFlash = false;
      _lastFrameTime = null;
    });
    _gameLoopController.forward();
    _scheduleNextSpawn();
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Color flashColor = kBackground;
    if (_showSuccessFlash) flashColor = kAccentGreen.withAlpha(60);
    if (_showFailFlash) flashColor = kAccentRed.withAlpha(60);

    return Scaffold(
      backgroundColor: flashColor,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeartsBar(),
                Expanded(child: _buildGameArea()),
                _buildInputBar(),
              ],
            ),
            if (_gameOver) _buildGameOverOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeartsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (i) {
          final active = i < _lives;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              Icons.favorite,
              color: active ? kHeartActive : kHeartInactive,
              size: 28,
              shadows: active
                  ? [
                      Shadow(
                        color: kHeartActive.withAlpha(180),
                        blurRadius: 8,
                      )
                    ]
                  : null,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildGameArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: _bombs.map((bomb) {
            final left = bomb.xPosition * constraints.maxWidth - _bombWidth / 2;
            final top = bomb.yPosition * constraints.maxHeight - _bombHeight / 2;
            final isClose = bomb.yPosition > 0.7;

            return Positioned(
              left: left.clamp(0.0, constraints.maxWidth - _bombWidth),
              top: top.clamp(0.0, constraints.maxHeight - _bombHeight),
              child: _BombWidget(
                number: bomb.number,
                isClose: isClose,
              ),
            );
          }).toList(),
        );
      },
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
              controller: _inputController,
              focusNode: _inputFocus,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: GoogleFonts.orbitron(
                color: kTextPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: '?',
                hintStyle: TextStyle(color: kTextSecondary),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              onSubmitted: (_) => _onSubmit(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _gameOver ? null : _onSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccentRed,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'OK',
                style: GoogleFonts.orbitron(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: kTextPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameOverOverlay() {
    return Positioned.fill(
      child: Container(
        color: kBackground.withAlpha(220),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'GAME OVER',
                style: GoogleFonts.orbitron(
                  color: kAccentRed,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      color: kAccentRed.withAlpha(180),
                      blurRadius: 20,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _restartGame,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccentRed,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  'RESTART',
                  style: GoogleFonts.orbitron(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: kTextPrimary,
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

class _BombWidget extends StatelessWidget {
  final int number;
  final bool isClose;

  const _BombWidget({required this.number, required this.isClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        color: kBombBody,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isClose ? kAccentRed : kBombBorder,
          width: isClose ? 2.5 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isClose
                ? kAccentRed.withAlpha(180)
                : kAccentRed.withAlpha(60),
            blurRadius: isClose ? 16 : 8,
            spreadRadius: isClose ? 2 : 0,
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$number',
          style: GoogleFonts.orbitron(
            color: isClose ? kAccentRed : kTextPrimary,
            fontSize: 26,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                color: isClose
                    ? kAccentRed.withAlpha(200)
                    : kTextPrimary.withAlpha(80),
                blurRadius: isClose ? 10 : 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
