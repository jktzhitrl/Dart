import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/board_tablets.dart';
import '../../data/models.dart';

class BoardTabletControls extends StatefulWidget {
  final BoardTablets tablets;
  final TournamentRecord tournament;
  final Uri appUri;
  const BoardTabletControls({
    super.key,
    required this.tablets,
    required this.tournament,
    required this.appUri,
  });

  @override
  State<BoardTabletControls> createState() => _BoardTabletControlsState();
}

class _BoardTabletControlsState extends State<BoardTabletControls> {
  late final _stations = widget.tablets.watchBoards(widget.tournament.id);
  final _busy = <String>{};

  Future<void> _showCode(BoardInfo board, int index) async {
    await _run(board, () async {
      final tournamentId = widget.tournament.id;
      final appUri = widget.appUri;
      final code = await widget.tablets.issueCode(
        tournamentId,
        board.id,
        index,
      );
      if (!mounted) return;
      final url = appUri
          .replace(
            queryParameters: {
              ...appUri.queryParameters,
              'tablet': tournamentId,
              'board': board.id,
              'slot': '$index',
              'pair': code,
            },
          )
          .toString();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Tablet für ${board.name} koppeln'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'QR-Code mit dem Tablet scannen. Er ist zehn Minuten gültig und nur einmal verwendbar.',
                ),
                const SizedBox(height: 16),
                Container(
                  width: 220,
                  height: 220,
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: url),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Schließen'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.copy),
              label: const Text('Kopplungslink kopieren'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _run(BoardInfo board, Future<void> Function() action) async {
    setState(() => _busy.add(board.id));
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gerätezuordnung konnte nicht geändert werden.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(board.id));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<BoardTablet>>(
    stream: _stations,
    builder: (context, snapshot) {
      final stations = {
        for (final s in snapshot.data ?? <BoardTablet>[]) s.boardId: s,
      };
      final boards = widget.tournament.boards;
      return Card(
        child: Column(
          children: [
            const ListTile(title: Text('Board-Tablets')),
            if (snapshot.hasError)
              const ListTile(
                title: Text('Gerätezuordnungen konnten nicht geladen werden.'),
              ),
            if (snapshot.hasData)
              for (var i = 0; i < boards.length; i++)
                _boardTile(boards[i], i, stations[boards[i].id]),
          ],
        ),
      );
    },
  );

  Widget _boardTile(BoardInfo board, int index, BoardTablet? station) {
    final paired = station?.deviceUid != null;
    return ListTile(
      title: Text(board.name),
      subtitle: Text(paired ? 'Tablet gekoppelt' : 'Kein Tablet gekoppelt'),
      trailing: TextButton(
        onPressed: _busy.contains(board.id)
            ? null
            : () {
                if (paired) {
                  _run(
                    board,
                    () => widget.tablets.revoke(widget.tournament.id, board.id),
                  );
                } else {
                  _showCode(board, index);
                }
              },
        child: Text(paired ? 'Tablet trennen' : 'QR-Code'),
      ),
    );
  }
}
