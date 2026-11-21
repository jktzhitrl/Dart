import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bootstrap.dart';
import '../../core/auth/permissions.dart';
import '../../data/auth_service.dart';
import '../../data/board_tablets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'home_shell.dart';
import 'login_screen.dart';
import 'scoring_screen.dart';

class BoardTabletScreen extends StatefulWidget {
  final BoardTablet tablet;
  const BoardTabletScreen({super.key, required this.tablet});

  @override
  State<BoardTabletScreen> createState() => _BoardTabletScreenState();
}

class _BoardTabletScreenState extends State<BoardTabletScreen> {
  bool _busy = false;
  bool _left = false;
  String? _uid;
  String? _error;
  Stream<BoardTablet?>? _station;

  BoardTablets get _tablets => context.read<AppServices>().tablets!;
  AuthService get _auth => context.read<AuthService>();

  bool _resumeTried = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final user = context.watch<AppUser>();
    if (!_resumeTried && user.uid.isNotEmpty && user.role == Role.spectator) {
      _resumeTried = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _pair(existingGuest: true),
      );
    }
  }

  Future<void> _pair({bool existingGuest = false}) async {
    if (!mounted || _busy || _left || _station != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final tablets = _tablets;
      final user = existingGuest && _auth.currentUser?.role == Role.spectator
          ? _auth.currentUser!
          : await _auth.signInAsSpectator();
      final tablet = widget.tablet;
      await tablets.pair(user.uid, tablet);
      if (!mounted) return;
      setState(() {
        _uid = user.uid;
        _station = tablets.watchBoard(tablet.tournamentId, tablet.boardId);
      });
    } catch (_) {
      if (mounted)
        setState(
          () => _error = widget.tablet.code == null
              ? 'Dieses Tablet ist keinem aktiven Board mehr zugeordnet.'
              : 'Kopplung fehlgeschlagen. Prüfe die Verbindung oder lass einen neuen QR-Code erstellen.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave({bool disconnect = false}) async {
    final auth = _auth;
    try {
      if (disconnect && _uid != null)
        await _tablets.disconnect(_uid!, widget.tablet);
      await auth.signOut();
      if (mounted) setState(() => _left = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Abmelden fehlgeschlagen.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AppUser>();
    if (_left) {
      return user.uid.isEmpty
          ? const LoginScreen()
          : HomeShell(key: ValueKey(user.uid));
    }
    if (_station != null) {
      return StreamBuilder<BoardTablet?>(
        stream: _station,
        builder: (context, snapshot) {
          final active = snapshot.data;
          if (snapshot.hasError ||
              (snapshot.connectionState == ConnectionState.active &&
                  active?.deviceUid != _uid)) {
            return _message(
              'Die Turnierleitung hat dieses Tablet getrennt.',
              action: TextButton(
                onPressed: () => _leave(),
                child: const Text('Board-Modus verlassen'),
              ),
            );
          }
          if (active == null) return _message('Board wird verbunden …');
          return _AssignedBoard(
            tablet: active,
            disconnect: () => _leave(disconnect: true),
          );
        },
      );
    }
    if (user.uid.isNotEmpty && user.role != Role.spectator) {
      return _message(
        'Dieses Gerät ist noch mit einem Spielerkonto angemeldet.',
        action: FilledButton(
          onPressed: () async {
            await _auth.signOut();
            if (mounted) await _pair();
          },
          child: const Text('Abmelden und Tablet koppeln'),
        ),
      );
    }
    if (_error != null && widget.tablet.code == null) {
      return _message(
        _error!,
        action: TextButton(
          onPressed: () => _leave(),
          child: const Text('Board-Modus verlassen'),
        ),
      );
    }
    return _message(
      _error ?? 'Dieses Tablet für die Punkteeingabe koppeln.',
      action: FilledButton(
        onPressed: _busy ? null : _pair,
        child: Text(_busy ? 'Verbindet …' : 'Tablet koppeln'),
      ),
    );
  }

  Widget _message(String message, {Widget? action}) => Scaffold(
    appBar: AppBar(title: const Text('Board-Tablet')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_score, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    ),
  );
}

class _AssignedBoard extends StatefulWidget {
  final BoardTablet tablet;
  final VoidCallback disconnect;
  const _AssignedBoard({required this.tablet, required this.disconnect});

  @override
  State<_AssignedBoard> createState() => _AssignedBoardState();
}

class _AssignedBoardState extends State<_AssignedBoard> {
  late final _tournament = context.read<AppRepository>().watchTournament(
    widget.tablet.tournamentId,
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<TournamentRecord?>(
    stream: _tournament,
    builder: (context, snapshot) {
      final tournament = snapshot.data;
      final board = tournament?.boards
          .where((b) => b.id == widget.tablet.boardId)
          .firstOrNull;
      final matchId = board?.currentMatchId;
      if (board != null && matchId != null && !snapshot.hasError) {
        return ScoringScreen(
          key: ValueKey(matchId),
          matchId: matchId,
          boardTablet: board.name,
        );
      }
      final closed = tournament?.status == TournamentStatus.finished;
      return Scaffold(
        appBar: AppBar(
          title: Text(board?.name ?? 'Board-Tablet'),
          actions: [
            TextButton(
              onPressed: widget.disconnect,
              child: const Text('Board-Modus verlassen'),
            ),
          ],
        ),
        body: Center(
          child: Text(
            snapshot.hasError
                ? 'Board nicht verfügbar.'
                : board == null
                ? 'Board wird geladen …'
                : closed
                ? 'Turnier beendet.'
                : 'Wartet auf die nächste Begegnung.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    },
  );
}
