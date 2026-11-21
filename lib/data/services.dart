import 'dart:math';

import '../core/auth/permissions.dart';
import '../core/models/ids.dart';
import '../core/models/rules.dart';
import '../core/stats/player_stats.dart';
import '../core/tournament/board_scheduler.dart';
import '../core/tournament/participant.dart';
import '../core/tournament/tournament_plan.dart';
import '../core/x01/x01_match.dart';
import '../core/games/around_the_clock.dart';
import '../core/games/cricket.dart';
import 'models.dart';
import 'repository.dart';

String _inviteCode({required bool isPublic}) {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // ohne verwechselbare Zeichen
  final r = Random.secure();
  return List.generate(isPublic ? 6 : 12, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

class ResultCorrection {
  final TournamentRecord _tournament;
  final MatchRecord _correctedMatch;
  final MatchRecord _originalMatch;
  final List<MatchRecord> invalidatedMatches;
  final List<String> changedPairings;

  ResultCorrection._(
    this._tournament,
    this._correctedMatch,
    this._originalMatch,
    Iterable<MatchRecord> invalidatedMatches,
    Iterable<String> changedPairings,
  ) : invalidatedMatches = List.unmodifiable(invalidatedMatches),
      changedPairings = List.unmodifiable(changedPairings);
}

/// Anwendungslogik rund um Turniere und Begegnungen. Alle Methoden prüfen die
/// Rolle des Aufrufers (zusätzlich zu den Security Rules auf dem Server).
class TournamentService {
  final AppRepository repo;
  TournamentService(this.repo);

  void _require(Role role, Permission p) {
    if (!can(role, p)) throw PermissionDenied('Fehlende Berechtigung: ${p.name}');
  }

  Future<void> _log(AppUser by, String action,
      {String? tournamentId, String? matchId, String detail = ''}) =>
      repo.audit(_auditEntry(by, action, tournamentId: tournamentId, matchId: matchId, detail: detail));

  AuditEntry _auditEntry(AppUser by, String action,
      {String? tournamentId, String? matchId, String detail = ''}) => AuditEntry(
        id: newId('a'),
        at: DateTime.now().toUtc(),
        uid: by.uid,
        action: action,
        tournamentId: tournamentId,
        matchId: matchId,
        detail: detail,
      );

  /// Neues Turnier; der Ersteller wird Turnierleiter.
  Future<TournamentRecord> create(
    AppUser by, {
    required String name,
    required TournamentFormat format,
    required GameType gameType,
    required X01Rules rules,
    bool isPublic = true,
    int boardCount = 2,
  }) async {
    _require(by.role, Permission.createTournament);
    final t = TournamentRecord(
      id: newId('t'),
      name: name.trim(),
      format: format,
      gameType: gameType,
      rules: rules,
      isPublic: isPublic,
      status: TournamentStatus.registration,
      inviteCode: _inviteCode(isPublic: isPublic),
      createdBy: by.uid,
      createdAt: DateTime.now().toUtc(),
      boards: [for (var i = 1; i <= boardCount; i++) BoardInfo('b$i', 'Board $i')],
    );
    final saved = await repo.saveTournament(t);
    await repo.setMember(saved.id, TournamentMember(by.uid, by.displayName, Role.director));
    await _log(by, 'tournament.create', tournamentId: saved.id, detail: saved.name);
    return saved;
  }

  Future<Role> roleIn(AppUser user, TournamentRecord t) async {
    final inT = await repo.memberRole(t.id, user.uid);
    return effectiveRole(user.role, inT);
  }

  /// Spieler tritt per Einladungscode bei (selbst) oder wird von der Leitung hinzugefügt.
  Future<TournamentRecord> join(AppUser by, TournamentRecord t, PlayerProfile player) async {
    final role = await roleIn(by, t);
    _require(role, Permission.joinTournament);
    if (player.id != by.playerId || player.uid != by.uid) throw PermissionDenied();
    if (t.status != TournamentStatus.registration) {
      throw StateError('Die Anmeldung ist geschlossen (Auslosung erfolgt).');
    }
    if (t.registrations.any((p) => p.id == player.id)) return t;
    final saved = await repo.saveTournament(t.copyWith(
        registrations: [...t.registrations, Participant(id: player.id, name: player.name)]));
    if (player.uid != null) {
      final existing = await repo.memberRole(t.id, player.uid!);
      if (existing == null) {
        await repo.setMember(t.id, TournamentMember(player.uid!, player.name, Role.player));
      }
    }
    await _log(by, 'tournament.join', tournamentId: t.id, detail: player.name);
    return saved;
  }

  Future<TournamentRecord> addParticipant(
      AppUser by, TournamentRecord t, Participant p) async {
    final role = await roleIn(by, t);
    _require(role, Permission.manageParticipants);
    if (t.registrations.any((x) => x.id == p.id)) return t;
    final saved = await repo.saveTournament(t.copyWith(registrations: [...t.registrations, p]));
    await _log(by, 'tournament.addParticipant', tournamentId: t.id, detail: p.name);
    return saved;
  }

  Future<TournamentRecord> removeParticipant(AppUser by, TournamentRecord t, String id) async {
    final role = await roleIn(by, t);
    _require(role, Permission.manageParticipants);
    if (t.status != TournamentStatus.registration) {
      throw StateError('Teilnehmer können nach der Auslosung nicht entfernt werden.');
    }
    final saved = await repo.saveTournament(
        t.copyWith(registrations: t.registrations.where((p) => p.id != id).toList()));
    await _log(by, 'tournament.removeParticipant', tournamentId: t.id, detail: id);
    return saved;
  }

  Future<TournamentRecord> setSeed(AppUser by, TournamentRecord t, String id, int? seed) async {
    final role = await roleIn(by, t);
    _require(role, Permission.manageParticipants);
    final list = [
      for (final p in t.registrations)
        if (p.id == id) p.copyWith(seed: seed, clearSeed: seed == null) else p
    ];
    return repo.saveTournament(t.copyWith(registrations: list));
  }

  /// Auslosung erstellen (Entwurf - noch nicht veröffentlicht).
  Future<TournamentRecord> draw(AppUser by, TournamentRecord t,
      {PlanOptions options = const PlanOptions(), Random? rng}) async {
    final role = await roleIn(by, t);
    _require(role, Permission.runDraw);
    final plan = TournamentPlan.draw(t.format, t.registrations, options: options, rng: rng);
    final saved = await repo.saveTournament(
        t.copyWith(plan: plan, status: TournamentStatus.drawn, published: false));
    await _log(by, 'tournament.draw', tournamentId: t.id);
    return saved;
  }

  /// Auslosung manuell anpassen (nur vor Veröffentlichung).
  Future<TournamentRecord> savePlanEdit(
      AppUser by, TournamentRecord t, void Function(TournamentPlan plan) edit) async {
    final role = await roleIn(by, t);
    _require(role, Permission.runDraw);
    if (t.published) throw StateError('Die Auslosung ist bereits veröffentlicht.');
    final plan = TournamentPlan.fromJson(t.plan!.toJson());
    edit(plan);
    final saved = await repo.saveTournament(t.copyWith(plan: plan));
    await _log(by, 'tournament.editDraw', tournamentId: t.id);
    return saved;
  }

  Future<TournamentRecord> redraw(AppUser by, TournamentRecord t) async {
    final role = await roleIn(by, t);
    _require(role, Permission.runDraw);
    if (t.published) throw StateError('Die Auslosung ist bereits veröffentlicht.');
    return repo.saveTournament(
        t.copyWith(clearPlan: true, status: TournamentStatus.registration));
  }

  Future<TournamentRecord> publish(AppUser by, TournamentRecord t) async {
    final role = await roleIn(by, t);
    _require(role, Permission.publishDraw);
    if (t.plan == null) throw StateError('Es wurde noch nicht ausgelost.');
    final saved = await repo.saveTournament(
        t.copyWith(published: true, status: TournamentStatus.running));
    await _log(by, 'tournament.publish', tournamentId: t.id);
    return saved;
  }

  /// Startet eine Begegnung des Turniers (legt die Begegnung an, belegt das Board).
  Future<MatchRecord> startMatch(
    AppUser by,
    TournamentRecord t,
    PlanMatch pm, {
    String? boardId,
    String? scorerUid,
    int firstStarter = 0,
  }) async {
    final role = await roleIn(by, t);
    _require(role, Permission.startMatch);
    final fresh = await repo.watchTournament(t.id).first;
    if (fresh == null || !fresh.published || fresh.plan == null) {
      throw StateError('Die Auslosung ist noch nicht veröffentlicht.');
    }
    t = fresh;
    final planned = t.plan!.playable.where((m) => m.id == pm.id).firstOrNull;
    if (planned == null || planned.aId != pm.aId || planned.bId != pm.bId) {
      throw VersionConflict('Die Begegnung hat sich geändert.');
    }
    final names = t.plan!.names;
    final existing = await repo.watchMatches(tournamentId: t.id).first;
    if (existing.any((m) => m.planMatchId == pm.id && m.status != MatchStatus.confirmed)) {
      throw StateError('Diese Begegnung läuft bereits.');
    }
    if (boardId != null && !t.boards.any((b) => b.id == boardId && b.currentMatchId == null)) {
      throw StateError('Dieses Board ist belegt oder existiert nicht.');
    }
    final players = [for (final id in pm.playerIds) MatchPlayer(id, names[id] ?? id)];
    final now = DateTime.now().toUtc();
    final m = MatchRecord(
      id: newId('m'),
      tournamentId: t.id,
      planMatchId: pm.id,
      gameType: t.gameType,
      players: players,
      status: MatchStatus.live,
      boardId: boardId,
      scorerUid: scorerUid ?? by.uid,
      version: 0,
      createdAt: now,
      updatedAt: now,
      isPublic: t.isPublic,
      x01: t.gameType.isX01
          ? X01Match(
              rules: t.rules.copyWith(startScore: t.gameType.startScore),
              playerIds: players.map((p) => p.id).toList(),
              firstStarter: firstStarter)
          : null,
      cricket: t.gameType == GameType.cricket
          ? CricketMatch(playerIds: players.map((p) => p.id).toList())
          : null,
      clock: t.gameType == GameType.aroundTheClock
          ? AroundTheClockMatch(playerIds: players.map((p) => p.id).toList())
          : null,
    );
    await repo.commitTournamentMatches(
      t.copyWith(boards: [
        for (final board in t.boards)
          if (board.id == boardId) BoardInfo(board.id, board.name, currentMatchId: m.id) else board,
      ]),
      create: [m],
      audit: _auditEntry(by, 'match.start', tournamentId: t.id, matchId: m.id),
    );
    return m;
  }

  /// Schlägt Begegnungen für freie Boards vor (Spielpausen werden beachtet).
  Future<List<BoardAssignment>> suggestAssignments(
    TournamentRecord t, {
    Duration minRest = const Duration(minutes: 5),
    DateTime? now,
  }) async {
    final plan = t.plan;
    if (plan == null || !t.published) return const [];
    final matches = await repo.watchMatches(tournamentId: t.id).first;
    final running = matches.where((m) => m.status != MatchStatus.confirmed).toList();
    final runningPlanIds = running.map((m) => m.planMatchId).toSet();
    final playingNow = running.expand((m) => m.players.map((p) => p.id)).toSet();
    final lastFinished = <String, DateTime>{};
    for (final m in matches.where((m) => m.status == MatchStatus.confirmed)) {
      for (final p in m.players) {
        final prev = lastFinished[p.id];
        if (prev == null || m.updatedAt.isAfter(prev)) lastFinished[p.id] = m.updatedAt;
      }
    }
    final ready = [
      for (final pm in plan.playable)
        if (!runningPlanIds.contains(pm.id)) PendingMatch(pm.id, pm.round, pm.playerIds)
    ];
    return BoardScheduler(minRest: minRest).assign(
      ready: ready,
      boards: [for (final b in t.boards) Board(id: b.id, name: b.name, currentMatchId: b.currentMatchId)],
      playingNow: playingNow,
      lastFinished: lastFinished,
      now: now,
    );
  }

  /// Schreiber übermittelt das Ergebnis zur Bestätigung.
  Future<MatchRecord> submitResult(AppUser by, MatchRecord m) async {
    final tRole = m.tournamentId == null ? null : await repo.memberRole(m.tournamentId!, by.uid);
    _require(effectiveRole(by.role, tRole), Permission.submitResult);
    final saved = await repo.updateMatch(m.id, (cur) {
      if (cur.status == MatchStatus.voided || cur.status == MatchStatus.confirmed) {
        throw StateError('Diese Begegnung kann nicht eingereicht werden.');
      }
      if (!cur.isFinished) throw StateError('Das Spiel ist noch nicht beendet.');
      return cur.copyWith(status: MatchStatus.awaitingConfirmation);
    }, expectedVersion: m.version);
    await _log(by, 'match.submit', tournamentId: m.tournamentId, matchId: m.id);
    return saved;
  }

  /// Turnierleitung bestätigt das Ergebnis; der Turnierfortschritt (nächste
  /// Runde, Qualifikation, Folgerunden) wird automatisch berechnet.
  Future<TournamentRecord?> confirmResult(AppUser by, MatchRecord m) async {
    final tid = m.tournamentId;
    final tRole = tid == null ? null : await repo.memberRole(tid, by.uid);
    _require(effectiveRole(by.role, tRole), Permission.confirmResult);
    if (!m.isFinished) throw StateError('Das Spiel ist noch nicht beendet.');
    if (m.status == MatchStatus.confirmed || m.status == MatchStatus.voided) {
      throw StateError('Das Ergebnis kann nicht bestätigt werden.');
    }

    final confirmed = m.copyWith(status: MatchStatus.confirmed);
    if (tid == null || m.planMatchId == null) {
      await repo.updateMatch(m.id, (_) => confirmed, expectedVersion: m.version);
      await _log(by, 'match.confirm', tournamentId: tid, matchId: m.id);
      return null;
    }

    final t = await repo.watchTournament(tid).first;
    if (t?.plan == null) throw StateError('Der Spielplan wurde nicht gefunden.');
    final plan = TournamentPlan.fromJson(t!.plan!.toJson());
    if (!plan.playable.any((p) => p.id == m.planMatchId &&
        p.aId == m.players[0].id && p.bId == m.players[1].id)) {
      throw VersionConflict('Die Begegnung steht nicht mehr so im Spielplan.');
    }
    final (legsA, legsB) = m.legsScore;
    plan.reportResult(m.planMatchId!, m.winnerId!, legsA: legsA, legsB: legsB);
    return repo.commitTournamentMatches(
      t.copyWith(
        plan: plan,
        boards: _releaseBoards(t, {m.id}),
        status: plan.isComplete ? TournamentStatus.finished : TournamentStatus.running,
      ),
      update: [confirmed],
      audit: _auditEntry(by, 'match.confirm', tournamentId: tid, matchId: m.id),
    );
  }

  /// Computes the effects without changing the draw, matches or score logs.
  Future<ResultCorrection> previewCorrection(
    AppUser by, MatchRecord match, OfficialResult result,
  ) async {
    final tid = match.tournamentId;
    if (tid == null || match.planMatchId == null) throw StateError('Kein Turnierspiel.');
    final t = await repo.watchTournament(tid).first;
    if (t?.plan == null || !t!.published) throw StateError('Kein veröffentlichter Spielplan.');
    _require(await roleIn(by, t), Permission.correctResult);
    final matches = await repo.watchMatches(tournamentId: tid).first;
    final current = matches.where((m) => m.id == match.id).firstOrNull;
    if (current?.version != match.version || current?.status != MatchStatus.confirmed) {
      throw VersionConflict('Das bestätigte Ergebnis hat sich geändert.');
    }
    if (match.players.length != 2 || result.winnerIndex < 0 || result.winnerIndex > 1 ||
        result.legsA < 0 || result.legsB < 0 ||
        result.legsA + result.legsB < 1 ||
        (match.x01?.rules.format.usesSets != true &&
            (result.winnerIndex == 0 ? result.legsA <= result.legsB : result.legsB <= result.legsA))) {
      throw ArgumentError('Bitte ein gültiges Ergebnis und den Sieger angeben.');
    }
    final corrected = current!.copyWith(correction: result);
    final original = t.plan!;
    final swissRound = original.format == TournamentFormat.swiss &&
            corrected.winnerId != match.winnerId
        ? original.fixtures.firstWhere((f) => f.id == match.planMatchId).round
        : null;
    final plan = original.resetResults(preserveSwissThrough: swissRound);
    final results = {
      for (final m in matches)
        if (m.planMatchId != null && m.status == MatchStatus.confirmed)
          m.planMatchId!: m.id == match.id ? corrected : m,
    };
    final applied = <String>{};
    final rng = Random(19);
    while (true) {
      final playable = plan.playable.where((p) {
        final m = results[p.id];
        return m != null && m.players.length == 2 &&
            m.players[0].id == p.aId && m.players[1].id == p.bId;
      }).toList();
      if (playable.isEmpty) break;
      for (final p in playable) {
        final m = results.remove(p.id)!;
        final (legsA, legsB) = m.legsScore;
        plan.reportResult(p.id, m.winnerId!, legsA: legsA, legsB: legsB, rng: rng);
        applied.add(m.id);
      }
    }
    if (!applied.contains(match.id)) throw StateError('Das Ergebnis passt nicht zum Spielplan.');

    final before = original.pairings;
    final after = plan.pairings;
    final invalidated = <MatchRecord>[
      for (final m in matches)
        if (m.planMatchId != null && !applied.contains(m.id) &&
            (m.status == MatchStatus.confirmed || m.players.length != 2 ||
                after[m.planMatchId] != (m.players[0].id, m.players[1].id))) m,
    ];
    String pairingName((String?, String?) pair) =>
        [pair.$1, pair.$2].map((id) => original.names[id] ?? 'offen').join(' – ');
    final changed = [
      for (final entry in before.entries)
        if (entry.key != match.planMatchId && entry.value != after[entry.key])
          '${pairingName(entry.value)} → ${after.containsKey(entry.key) ? pairingName(after[entry.key]!) : 'neu anzusetzen'}',
      for (final entry in after.entries)
        if (!before.containsKey(entry.key)) 'Neu: ${pairingName(entry.value)}',
    ];
    return ResultCorrection._(
      t.copyWith(
        plan: plan,
        boards: _releaseBoards(t, invalidated.map((m) => m.id).toSet()),
        status: plan.isComplete ? TournamentStatus.finished : TournamentStatus.running,
      ),
      corrected,
      current,
      invalidated,
      changed,
    );
  }

  Future<void> applyCorrection(AppUser by, ResultCorrection preview, {bool annulMatches = false}) async {
    final t = preview._tournament;
    final corrected = preview._correctedMatch;
    _require(await roleIn(by, t), Permission.correctResult);
    if (preview.invalidatedMatches.isNotEmpty && !annulMatches) {
      throw StateError('Betroffene Begegnungen müssen ausdrücklich annulliert werden.');
    }
    await repo.commitTournamentMatches(
      t,
      update: [
        corrected,
        for (final m in preview.invalidatedMatches) m.copyWith(status: MatchStatus.voided),
      ],
      audit: _auditEntry(by, 'match.correct', tournamentId: t.id, matchId: corrected.id,
        detail: '${preview._originalMatch.legsScore} → ${corrected.legsScore} · Sieger: ${preview._originalMatch.winnerId} → ${corrected.winnerId} · Annulliert: ${preview.invalidatedMatches.map((m) => m.id).join(', ')}'),
    );
  }

  List<BoardInfo> _releaseBoards(TournamentRecord t, Set<String> ids) => [
    for (final b in t.boards)
      if (ids.contains(b.currentMatchId)) BoardInfo(b.id, b.name) else b,
  ];
}

/// Erzeugt Begegnungen außerhalb von Turnieren (Freundschaftsspiel, Training).
class MatchFactory {
  static MatchRecord create({
    required GameType gameType,
    required List<MatchPlayer> players,
    X01Rules rules = const X01Rules(),
    int firstStarter = 0,
    bool cutThroat = false,
    bool skipAhead = false,
    String? scorerUid,
  }) {
    final ids = players.map((p) => p.id).toList();
    final now = DateTime.now().toUtc();
    return MatchRecord(
      id: newId('m'),
      gameType: gameType,
      players: players,
      status: MatchStatus.live,
      scorerUid: scorerUid,
      version: 0,
      createdAt: now,
      updatedAt: now,
      x01: gameType.isX01
          ? X01Match(
              rules: rules.copyWith(startScore: gameType.startScore),
              playerIds: ids,
              firstStarter: firstStarter)
          : null,
      cricket: gameType == GameType.cricket ? CricketMatch(playerIds: ids, cutThroat: cutThroat) : null,
      clock: gameType == GameType.aroundTheClock
          ? AroundTheClockMatch(playerIds: ids, skipAhead: skipAhead)
          : null,
    );
  }
}

/// Statistiken aus gespeicherten Begegnungen.
class StatsService {
  /// Leg-Aufzeichnungen eines X01-Matches.
  static List<LegRecord> legsOf(MatchRecord m) {
    final x = m.x01;
    if (x == null || m.correction != null) return const [];
    final byLeg = <int, List<dynamic>>{};
    for (final v in x.visits) {
      byLeg.putIfAbsent(v.legNo, () => []).add(v);
    }
    return [
      for (final e in byLeg.entries)
        LegRecord(
          legNo: e.key,
          visits: e.value.cast(),
          playerIds: x.playerIds,
          winnerId: x.state.legResults
              .where((r) => r.legNo == e.key)
              .map((r) => x.playerIds[r.winnerIndex])
              .firstOrNull,
          outMode: x.rules.outMode,
          inMode: x.rules.inMode,
        )
    ];
  }

  static MatchSummary summaryOf(MatchRecord m) {
    final x = m.x01;
    return MatchSummary(
      matchId: m.id,
      playerIds: m.players.map((p) => p.id).toList(),
      winnerId: m.winnerId,
      setsWon: x == null || m.correction != null
          ? const {}
          : {for (var i = 0; i < m.players.length; i++) m.players[i].id: x.state.setsWon[i]},
      officialLegsWon: m.correction == null
          ? const {}
          : {m.players[0].id: m.correction!.legsA, m.players[1].id: m.correction!.legsB},
      playedAt: m.updatedAt,
    );
  }

  /// Statistik eines Spielers über [matches] (Spiel, Turnier oder Karriere -
  /// je nachdem, welche Begegnungen übergeben werden). Laufende Begegnungen
  /// werden nur berücksichtigt, wenn [includeLive] gesetzt ist.
  static PlayerStats forPlayer(String playerId, Iterable<MatchRecord> matches,
      {bool includeLive = false}) {
    final used = matches.where((m) =>
        m.status != MatchStatus.voided &&
        m.players.any((p) => p.id == playerId) &&
        (includeLive || m.isFinished) &&
        m.gameType.isX01);
    return computePlayerStats(
      playerId,
      [for (final m in used) ...legsOf(m)],
      matches: [for (final m in used) summaryOf(m)],
    );
  }
}
