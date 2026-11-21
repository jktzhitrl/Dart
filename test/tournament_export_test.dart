import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:darts_tournament_manager/core/models/rules.dart';
import 'package:darts_tournament_manager/core/tournament/participant.dart';
import 'package:darts_tournament_manager/core/tournament/tournament_plan.dart';
import 'package:darts_tournament_manager/data/models.dart';
import 'package:darts_tournament_manager/data/tournament_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDF und CSV enthalten die abgeschlossene Turnierauswertung', () async {
    final plan = TournamentPlan.draw(TournamentFormat.singleElimination, const [
      Participant(id: 'a', name: '=A;B'),
      Participant(id: 'b', name: 'Bär'),
    ], rng: Random(1));
    plan.reportResult(plan.playable.single.id, 'a', legsA: 2, legsB: 1);
    final tournament = TournamentRecord(
      id: 't',
      name: 'Dart-Abend',
      format: plan.format,
      gameType: GameType.x501,
      rules: const X01Rules(),
      isPublic: true,
      status: TournamentStatus.finished,
      inviteCode: 'ABC234',
      createdBy: 'admin',
      createdAt: DateTime.utc(2026),
      plan: plan,
      published: true,
    );
    final export = TournamentExport(tournament);
    expect(export.filename, 'Dart-Abend');
    final csv = utf8.decode(export.csv());
    expect(csv, contains('Platzierung'));
    expect(csv, contains('Ergebnis'));
    expect(csv, contains('"\'=A;B"'));
    expect(csv, contains('Bär'));
    final font = File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync();
    final pdf = await export.pdf(ByteData.sublistView(font));
    expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
  });
}
