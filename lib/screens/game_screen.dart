import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/navigation_observer.dart';
import '../core/theme.dart';
import '../models/bomb.dart';
import '../services/vault_service.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final List<Bomb> _bombs = [];
  int _lives = 4;
  int _score = 0;
  bool _gameOver = false;
  bool _showSuccessFlash = false;
  bool _showFailFlash = false;

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final Random _random = Random();
  final VaultService _vaultService = VaultService();

  late Ticker _ticker;
  Duration? _previousTickDuration;
  Timer? _spawnTimer;
  int _bombIdCounter = 0;
  bool _loopPaused = false;
  ModalRoute<dynamic>? _route;

  static const double _bombWidth = 70.0;
  static const double _bombHeight = 70.0;

  int get _level => (_score ~/ 50) + 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ticker = createTicker(_onTick)..start();
    _scheduleNextSpawn();

    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _inputFocus.requestFocus();
    });
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
    _ticker.dispose();
    _spawnTimer?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  void didPushNext() {
    _pauseLoop();
  }

  @override
  void didPopNext() {
    _resumeLoop();
    _inputController.clear();
    Future.microtask(() {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || _gameOver) return;

    if (state == AppLifecycleState.resumed) {
      _resumeLoop();
      Future.microtask(() {
        if (mounted) _inputFocus.requestFocus();
      });
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pauseLoop();
    }
  }

  void _pauseLoop() {
    _loopPaused = true;
    _previousTickDuration = null;
    _ticker.muted = true;
    _spawnTimer?.cancel();
  }

  void _resumeLoop() {
    if (_gameOver) return;
    _loopPaused = false;
    _previousTickDuration = null;
    _ticker.muted = false;
    _spawnTimer?.cancel();
    _scheduleNextSpawn();
  }

  void _onTick(Duration elapsed) {
    if (_gameOver || _loopPaused) return;

    if (_previousTickDuration == null) {
      _previousTickDuration = elapsed;
      return;
    }

    final dt = (elapsed - _previousTickDuration!).inMicroseconds / 1000000.0;
    _previousTickDuration = elapsed;

    if (dt <= 0 || dt > 0.5) return;
    if (!mounted) return;

    setState(() {
      final toRemove = <String>[];
      for (final bomb in _bombs) {
        bomb.yPosition += bomb.speed * dt;
        if (bomb.yPosition >= 1.0) {
          toRemove.add(bomb.id);
          _lives--;
        }
      }
      _bombs.removeWhere((b) => toRemove.contains(b.id));
      if (_lives <= 0) {
        _lives = 0;
        _gameOver = true;
        _ticker.muted = true;
        _spawnTimer?.cancel();
      }
    });
  }

  void _scheduleNextSpawn() {
    final baseDelay = (2000 - (_level - 1) * 100).clamp(800, 2000);
    final delay = baseDelay + _random.nextInt(1001);
    _spawnTimer = Timer(Duration(milliseconds: delay), () {
      if (!_gameOver && mounted) {
        _spawnBomb();
        _scheduleNextSpawn();
      }
    });
  }

  void _spawnBomb() {
    final maxBombs = (5 + (_level - 1)).clamp(5, 8);
    if (_bombs.length >= maxBombs) return;

    final baseSpeed = 0.04 + (_level - 1) * 0.008;
    setState(() {
      _bombs.add(Bomb(
        id: 'bomb_${_bombIdCounter++}',
        number: 1 + _random.nextInt(9),
        yPosition: 0.0,
        xPosition: 0.05 + _random.nextDouble() * 0.80,
        speed: baseSpeed + _random.nextDouble() * 0.04,
      ));
    });
  }

  int get _bombSum => _bombs.fold(0, (sum, b) => sum + b.number);

  Future<void> _onSubmit() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    _inputController.clear();

    try {
      final vaultId = await _vaultService.checkCode(input);
      if (!mounted) return;

      if (vaultId != null) {
        _pauseLoop();
        bool isSetup = true;
        try {
          isSetup = await _vaultService.isVaultSetup(vaultId);
        } catch (_) {
          // If setup status lookup fails, still try to open the vault screen.
          isSetup = true;
        }
        if (!mounted) return;

        if (isSetup) {
          await context.push('/vault/$vaultId');
        } else {
          await context.push('/vault-setup/$vaultId');
        }

        if (mounted) {
          _resumeLoop();
          _inputFocus.requestFocus();
        }
        return;
      }
    } catch (_) {
      if (!mounted) return;
      _showFailFlashOnce();
      _inputFocus.requestFocus();
      return;
    }

    // If user entered a 6-digit number, treat it as vault code attempt.
    if (RegExp(r'^\d{6}$').hasMatch(input)) {
      _showFailFlashOnce();
      _inputFocus.requestFocus();
      return;
    }

    final typedValue = int.tryParse(input);
    if (typedValue != null && typedValue == _bombSum && _bombs.isNotEmpty) {
      final earned = _bombSum;
      setState(() {
        _score += earned;
        _bombs.clear();
        _showSuccessFlash = true;
      });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showSuccessFlash = false);
      });
      return;
    }

    _showFailFlashOnce();
    _inputFocus.requestFocus();
  }

  void _showFailFlashOnce() {
    setState(() => _showFailFlash = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showFailFlash = false);
    });
  }

  void _restartGame() {
    setState(() {
      _bombs.clear();
      _lives = 4;
      _score = 0;
      _gameOver = false;
      _showSuccessFlash = false;
      _showFailFlash = false;
      _previousTickDuration = null;
    });
    _resumeLoop();
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Color flashColor = kBackground;
    if (_showSuccessFlash) flashColor = kAccentGreen.withAlpha(60);
    if (_showFailFlash) flashColor = kAccentRed.withAlpha(60);

    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: flashColor,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildStatusBar(),
                Expanded(child: _buildGameArea()),
                _buildInputBar(),
                SizedBox(height: keyboardHeight),
              ],
            ),
            if (_gameOver) _buildGameOverOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: List.generate(4, (i) {
              final active = i < _lives;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.favorite,
                  color: active ? kHeartActive : kHeartInactive,
                  size: 26,
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
          Row(
            children: [
              _buildStatChip('LVL $_level', kAccentGreen),
              const SizedBox(width: 8),
              _buildStatChip('$_score PTS', kTextSecondary),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kBombBody,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: GoogleFonts.orbitron(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildGameArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: _bombs.map((bomb) {
            final left = bomb.xPosition * constraints.maxWidth - _bombWidth / 2;
            final top =
                bomb.yPosition * constraints.maxHeight - _bombHeight / 2;
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
              autofocus: false,
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
              const SizedBox(height: 12),
              Text(
                'SCORE: $_score',
                style: GoogleFonts.orbitron(
                  color: kAccentGreen,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'LEVEL: $_level',
                style: GoogleFonts.orbitron(
                  color: kTextSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _restartGame,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccentRed,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
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
            color:
                isClose ? kAccentRed.withAlpha(180) : kAccentRed.withAlpha(60),
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
