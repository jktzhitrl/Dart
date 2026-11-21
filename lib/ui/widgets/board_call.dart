import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/repository.dart';

/// Shows live board assignments across the app while the player is signed in.
class BoardCall extends StatefulWidget {
  final AppRepository repo;
  final String playerId;
  final ValueChanged<String> openMatch;

  const BoardCall({
    super.key,
    required this.repo,
    required this.playerId,
    required this.openMatch,
  });

  @override
  State<BoardCall> createState() => _BoardCallState();
}

class _BoardCallState extends State<BoardCall> {
  late final _tournaments = widget.repo.watchTournaments();
  late final _matches = widget.repo.watchMatches();
  final _dismissed = <(String, String)>{};

  @override
  Widget build(BuildContext context) => StreamBuilder<List<TournamentRecord>>(
    stream: _tournaments,
    builder: (context, tournaments) {
      final boards = {
        for (final tournament in tournaments.data ?? <TournamentRecord>[])
          for (final board in tournament.boards)
            if (board.currentMatchId != null) board.currentMatchId!: board,
      };
      return StreamBuilder<List<MatchRecord>>(
        stream: _matches,
        builder: (context, matches) {
          for (final match in matches.data ?? <MatchRecord>[]) {
            final board = boards[match.id];
            if (board == null ||
                match.status != MatchStatus.live ||
                match.isFinished ||
                !match.players.any((p) => p.id == widget.playerId)) {
              continue;
            }
            final key = (match.id, board.id);
            if (_dismissed.contains(key)) continue;
            final opponent = match.players.firstWhere(
              (p) => p.id != widget.playerId,
            );
            void dismiss() => setState(() => _dismissed.add(key));
            final colors = Theme.of(context).colorScheme;
            return Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Material(
                        elevation: 8,
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        child: Semantics(
                          liveRegion: true,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            iconColor: colors.onPrimaryContainer,
                            textColor: colors.onPrimaryContainer,
                            leading: const Icon(Icons.notifications_active),
                            title: Text('Jetzt an ${board.name}'),
                            subtitle: Text('Gegen ${opponent.name}'),
                            onTap: () {
                              dismiss();
                              widget.openMatch(match.id);
                            },
                            trailing: IconButton(
                              tooltip: 'Spielaufruf schließen',
                              onPressed: dismiss,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        },
      );
    },
  );
}
