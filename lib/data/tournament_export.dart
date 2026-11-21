import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/tournament/tournament_plan.dart';
import 'models.dart';

class TournamentExport {
  final TournamentRecord tournament;
  final List<List<String>> _placements = [];
  final List<List<String>> _results = [];

  static const _placementHeader = [
    'Bereich',
    'Platz',
    'Spieler',
    'Siege',
    'Niederlagen',
    'Punkte',
  ];
  static const _resultHeader = [
    'Runde',
    'Spieler A',
    'Spieler B',
    'Legs A',
    'Legs B',
    'Sieger',
  ];

  TournamentExport(this.tournament) {
    final plan = tournament.plan;
    if (plan == null || !plan.isComplete || !tournament.published) {
      throw StateError('Der Export ist nach Abschluss des Turniers verfügbar.');
    }
    final names = plan.names;
    final tables = plan.tables();
    for (var i = 0; i < tables.length; i++) {
      for (final row in tables[i]) {
        _placements.add([
          plan.groups.isEmpty ? 'Gesamt' : 'Gruppe ${plan.groups[i].name}',
          '${row.rank}',
          names[row.playerId] ?? row.playerId,
          '${row.wins}',
          '${row.losses}',
          '${row.points}',
        ]);
      }
    }
    if (plan.bracket case final bracket?) {
      final ranked = <String>{};
      void place(String? id, int rank) {
        if (id == null || !ranked.add(id)) return;
        _placements.add(['K.-o.', '$rank', names[id] ?? id, '', '', '']);
      }

      place(plan.championId, 1);
      final played = bracket.matches
          .where((m) => m.winnerId != null && !m.isBye)
          .toList();
      if (plan.format == TournamentFormat.doubleElimination) {
        final finals = played.where((m) => m.side == 'G');
        place(finals.lastOrNull?.loserId, 2);
      }
      final eliminations =
          played
              .where(
                (m) =>
                    plan.format != TournamentFormat.doubleElimination ||
                    m.side == 'L',
              )
              .toList()
            ..sort((a, b) => b.round.compareTo(a.round));
      var lastRound = -1;
      var rank = ranked.length + 1;
      for (final match in eliminations) {
        if (plan.format == TournamentFormat.doubleElimination &&
            ranked.contains(match.loserId))
          continue;
        if (match.round != lastRound) {
          rank = ranked.length + 1;
          lastRound = match.round;
        }
        place(match.loserId, rank);
      }
      for (final match in played) {
        _results.add([
          bracket.roundLabel(match.side, match.round),
          names[match.a.playerId] ?? '',
          names[match.b.playerId] ?? '',
          match.scoreA?.toString() ?? '',
          match.scoreB?.toString() ?? '',
          names[match.winnerId] ?? '',
        ]);
      }
    }
    _results.insertAll(0, [
      for (final f in plan.fixtures.where((f) => f.isPlayed))
        [
          '${f.group == null ? '' : 'Gruppe ${plan.groups[f.group!].name} – '}Runde ${f.round}',
          names[f.homeId] ?? f.homeId,
          names[f.awayId] ?? f.awayId,
          f.homeLegs?.toString() ?? '',
          f.awayLegs?.toString() ?? '',
          names[f.winnerId] ?? '',
        ],
    ]);
  }

  String get filename {
    final name = tournament.name.replaceAll(
      RegExp(r'[^\p{L}\d_-]+', unicode: true),
      '-',
    );
    return name.replaceAll(RegExp(r'^-+|-+$'), '').isEmpty
        ? 'dart-turnier'
        : name;
  }

  Uint8List csv() {
    String cell(String value) {
      // Spreadsheet apps interpret formulas even in quoted CSV fields.
      if (RegExp(r'^\s*[=+\-@]').hasMatch(value)) value = "'$value";
      return '"${value.replaceAll('"', '""')}"';
    }

    final rows = [
      ['Turnier', 'Kategorie', ..._placementHeader, ..._resultHeader],
      for (final row in _placements)
        [
          tournament.name,
          'Platzierung',
          ...row,
          ...List.filled(_resultHeader.length, ''),
        ],
      for (final row in _results)
        [
          tournament.name,
          'Ergebnis',
          ...List.filled(_placementHeader.length, ''),
          ...row,
        ],
    ];
    return Uint8List.fromList(
      utf8.encode(
        '\uFEFF${rows.map((r) => r.map(cell).join(';')).join('\r\n')}\r\n',
      ),
    );
  }

  Future<Uint8List> pdf(ByteData fontData) {
    final font = pw.Font.ttf(fontData);
    final report = pw.Document(title: tournament.name);
    pw.Widget table(List<String> header, List<List<String>> data) =>
        pw.TableHelper.fromTextArray(
          headers: header,
          data: data,
          headerStyle: pw.TextStyle(
            font: font,
            color: PdfColors.white,
            fontSize: 9,
          ),
          headerDecoration: const pw.BoxDecoration(
            color: PdfColors.blueGrey800,
          ),
          cellStyle: pw.TextStyle(font: font, fontSize: 9),
          cellPadding: const pw.EdgeInsets.all(6),
          border: null,
          oddRowDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey50),
        );
    report.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        maxPages: _placements.length + _results.length + 3,
        theme: pw.ThemeData.withFont(base: font),
        header: (context) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 12),
          child: pw.Text(
            tournament.name,
            style: pw.TextStyle(font: font, fontSize: 20),
          ),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('${context.pageNumber} / ${context.pagesCount}'),
        ),
        build: (_) => [
          pw.Text('Platzierungen', style: const pw.TextStyle(fontSize: 14)),
          pw.SizedBox(height: 6),
          table(_placementHeader, _placements),
          pw.SizedBox(height: 18),
          pw.Text('Ergebnisse', style: const pw.TextStyle(fontSize: 14)),
          pw.SizedBox(height: 6),
          table(_resultHeader, _results),
        ],
      ),
    );
    return report.save();
  }
}
