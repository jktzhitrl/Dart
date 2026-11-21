import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/services.dart';

Future<void> showResultCorrection(
  BuildContext context,
  MatchRecord match,
) async {
  final service = context.read<TournamentService>();
  final user = context.read<AppUser>();
  final messenger = ScaffoldMessenger.of(context);
  final result = await showDialog<OfficialResult>(
    context: context,
    builder: (_) => _ResultDialog(match: match),
  );
  if (result == null || !context.mounted) return;
  try {
    final preview = await service.previewCorrection(user, match, result);
    if (!context.mounted) return;
    final affected = preview.invalidatedMatches;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Auswirkungen der Korrektur'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Neues Ergebnis: ${result.legsA} : ${result.legsB} Legs. '
                  'Sieger: ${match.players[result.winnerIndex].name}.',
                ),
                const SizedBox(height: 12),
                if (preview.changedPairings.isEmpty)
                  const Text('Keine Folgepaarungen ändern sich.'),
                for (final change in preview.changedPairings) Text(change),
                if (affected.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Diese begonnenen oder bestätigten Spiele müssen annulliert werden. '
                    'Die Wurfprotokolle bleiben erhalten. Geänderte Paarungen werden neu angesetzt.',
                  ),
                  for (final m in affected)
                    Text('• ${m.players.map((p) => p.name).join(' – ')}'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              affected.isEmpty
                  ? 'Korrektur speichern'
                  : 'Annullieren und korrigieren',
            ),
          ),
        ],
      ),
    );
    if (approved != true) return;
    await service.applyCorrection(
      user,
      preview,
      annulMatches: affected.isNotEmpty,
    );
    if (context.mounted)
      messenger.showSnackBar(
        const SnackBar(content: Text('Ergebnis korrigiert.')),
      );
  } catch (e) {
    if (context.mounted) messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

class _ResultDialog extends StatefulWidget {
  final MatchRecord match;
  const _ResultDialog({required this.match});

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  final _form = GlobalKey<FormState>();
  late final _scoreA = TextEditingController(
    text: '${widget.match.legsScore.$1}',
  );
  late final _scoreB = TextEditingController(
    text: '${widget.match.legsScore.$2}',
  );
  late int _winner = widget.match.winnerIndex ?? 0;

  @override
  void dispose() {
    _scoreA.dispose();
    _scoreB.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final usesSets = match.x01?.rules.format.usesSets == true;
    return AlertDialog(
      title: const Text('Ergebnis korrigieren'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _scoreField(match.players[0].name, _scoreA),
              _scoreField(match.players[1].name, _scoreB),
              if (usesSets)
                DropdownButtonFormField<int>(
                  value: _winner,
                  decoration: const InputDecoration(
                    labelText: 'Sieger nach Sätzen',
                  ),
                  items: [
                    for (var i = 0; i < match.players.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(match.players[i].name),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _winner = value ?? _winner),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            final a = int.parse(_scoreA.text);
            final b = int.parse(_scoreB.text);
            Navigator.pop(
              context,
              OfficialResult(a, b, usesSets ? _winner : (a > b ? 0 : 1)),
            );
          },
          child: const Text('Auswirkungen prüfen'),
        ),
      ],
    );
  }

  Widget _scoreField(String name, TextEditingController controller) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: '$name – gewonnene Legs'),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (text) =>
            int.tryParse(text ?? '') == null ? 'Legs eingeben' : null,
      );
}
