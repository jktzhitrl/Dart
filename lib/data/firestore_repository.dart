import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:rxdart/rxdart.dart';

import '../core/auth/permissions.dart';
import 'models.dart';
import 'repository.dart';

/// Firestore-Implementierung mit Echtzeit-Streams.
///
/// Datenmodell (siehe docs/DATA_MODEL.md):
///  * `users/{uid}`, `players/{id}`
///  * `tournaments/{id}` mit Subcollection `members/{uid}`
///  * `matches/{id}` - enthält das vollständige Event-Log (Aufnahmen/Darts),
///    damit eine Eingabe atomar und gegen Konflikte versioniert ist
///  * `audit_logs/{id}`
///
/// Schreibzugriffe laufen über Transaktionen mit Versionsprüfung; die
/// Security Rules erzwingen zusätzlich Rolle und `version == alt + 1`.
/// Firestore speichert Offline-Änderungen lokal und synchronisiert sie nach
/// Wiederherstellung der Verbindung (Persistenz ist standardmäßig aktiv).
class FirestoreRepository implements AppRepository {
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  FirestoreRepository({FirebaseFirestore? firestore, FirebaseAuth? firebaseAuth})
      : db = firestore ?? FirebaseFirestore.instance,
        auth = firebaseAuth ?? FirebaseAuth.instance;

  @override
  bool get isRemote => true;

  CollectionReference<Map<String, dynamic>> get _tournaments => db.collection('tournaments');
  CollectionReference<Map<String, dynamic>> get _matches => db.collection('matches');
  CollectionReference<Map<String, dynamic>> get _players => db.collection('players');
  CollectionReference<Map<String, dynamic>> get _users => db.collection('users');
  CollectionReference<Map<String, dynamic>> get _audit => db.collection('audit_logs');

  CollectionReference<Map<String, dynamic>> get _invites =>
      db.collection('tournament_invites');

  Stream<bool> _isAdmin(String uid) => _users.doc(uid)
      .snapshots(includeMetadataChanges: true)
      .where((d) => !d.metadata.isFromCache)
      .map((d) => d.data()?['role'] == 'admin')
      .distinct();

  Stream<List<String>> _membershipIds(String uid) => db.collectionGroup('members')
      .where('uid', isEqualTo: uid)
      .snapshots(includeMetadataChanges: true)
      .where((s) => !s.metadata.isFromCache)
      .map((s) => s.docs.map((d) => d.reference.parent.parent!.id).toList()..sort())
      .distinct((a, b) => a.length == b.length && a.join('/') == b.join('/'));

  @override
  Stream<List<TournamentRecord>> watchTournaments() {
    final public = _tournaments.where('isPublic', isEqualTo: true)
        .snapshots().map((s) => s.docs.map((d) => TournamentRecord.fromJson(d.data())).toList());
    final user = auth.currentUser;
    final visible = user == null || user.isAnonymous
        ? public
        : _isAdmin(user.uid).startWith(false).switchMap((admin) {
            if (admin) {
              return _tournaments.snapshots(includeMetadataChanges: true)
                  .where((s) => !s.metadata.isFromCache)
                  .map((s) => s.docs.map((d) => TournamentRecord.fromJson(d.data())).toList());
            }
            return _membershipIds(user.uid).startWith(const []).switchMap((ids) => Rx.combineLatestList([
              public,
              for (final id in ids) watchTournament(id)
                  .map((t) => t == null ? <TournamentRecord>[] : [t]),
            ]).map((lists) => {for (final t in lists.expand((l) => l)) t.id: t}.values.toList()));
          });
    return visible.map((ts) => ts..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  @override
  Stream<TournamentRecord?> watchTournament(String id) => _tournaments.doc(id)
      .snapshots(includeMetadataChanges: true)
      .where((d) => !d.metadata.isFromCache || d.data()?['isPublic'] == true)
      .map((d) => d.exists ? TournamentRecord.fromJson(d.data()!) : null);

  @override
  Future<TournamentRecord?> findTournamentByInvite(String code) async {
    final q = await _tournaments
        .where('isPublic', isEqualTo: true)
        .where('inviteCode', isEqualTo: code.trim().toUpperCase())
        .limit(1)
        .get(const GetOptions(source: Source.server));
    return q.docs.isEmpty ? null : TournamentRecord.fromJson(q.docs.first.data());
  }

  @override
  Future<void> indexInvite(TournamentRecord t) =>
      _invites.doc(t.inviteCode).set({'tournamentId': t.id});

  @override
  Future<String?> resolveInvite(AppUser user, String code, {String? tournamentId}) async {
    code = code.trim().toUpperCase();
    if (!RegExp(r'^(?:[A-Z0-9]{6}|[A-Z0-9]{12})$').hasMatch(code)) return null;
    if (tournamentId == null) {
      final public = await findTournamentByInvite(code);
      if (public != null) return public.id;
      if (user.role == Role.spectator) throw PermissionDenied('Für private Turniere ist ein Konto nötig.');
      final invite = await _invites.doc(code).get(const GetOptions(source: Source.server));
      tournamentId = invite.data()?['tournamentId'] as String?;
      if (tournamentId == null) return null;
    }
    final tournamentRef = _tournaments.doc(tournamentId);
    try {
      final t = await tournamentRef.get(const GetOptions(source: Source.server));
      return t.exists ? tournamentId : null;
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
    }
    if (user.role == Role.spectator) throw PermissionDenied('Für private Turniere ist ein Konto nötig.');
    final ref = tournamentRef.collection('members').doc(user.uid);
    try {
      await db.runTransaction((tx) async {
        if ((await tx.get(ref)).exists) return;
        tx.set(ref, {
          ...TournamentMember(user.uid, user.displayName, Role.player).toJson(),
          'inviteCode': code,
        });
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw PermissionDenied('Der Einladungslink ist ungültig.');
      }
      rethrow;
    }
    return tournamentId;
  }

  @override
  Future<TournamentRecord> saveTournament(TournamentRecord t) async {
    final ref = _tournaments.doc(t.id);
    return db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists && (snap.data()!['version'] as num).toInt() != t.version) {
        throw VersionConflict('Das Turnier wurde zwischenzeitlich geändert.');
      }
      final saved = t.copyWith(version: t.version + 1);
      tx.set(ref, saved.toJson());
      if (!snap.exists && !saved.isPublic) {
        tx.set(_invites.doc(saved.inviteCode), {'tournamentId': saved.id});
      }
      return saved;
    });
  }

  @override
  Future<TournamentRecord> commitTournamentMatches(
    TournamentRecord t, {
    List<MatchRecord> create = const [],
    List<MatchRecord> update = const [],
    required AuditEntry audit,
  }) => db.runTransaction((tx) async {
    final tournament = _tournaments.doc(t.id);
    final current = await tx.get(tournament);
    if (current.data()?['version'] != t.version) throw VersionConflict();
    for (final m in create) {
      // New match IDs are random, and the tournament version serializes starts.
      // A read of a nonexistent private document would be denied by the rules.
      if (m.version != 0) throw VersionConflict();
    }
    for (final m in update) {
      final current = await tx.get(_matches.doc(m.id));
      if (current.data()?['version'] != m.version) throw VersionConflict();
    }
    final saved = t.copyWith(version: t.version + 1);
    final now = DateTime.now().toUtc();
    tx.set(tournament, saved.toJson());
    for (final m in create) {
      tx.set(_matches.doc(m.id), m.toJson());
    }
    for (final m in update) {
      tx.set(_matches.doc(m.id), m.copyWith(version: m.version + 1, updatedAt: now).toJson());
    }
    tx.set(_audit.doc(audit.id), audit.toJson());
    return saved;
  });

  @override
  Stream<List<TournamentMember>> watchMembers(String tournamentId) =>
      _tournaments.doc(tournamentId).collection('members').snapshots().map(
          (s) => [for (final d in s.docs) TournamentMember.fromJson(d.data())]);

  @override
  Future<void> setMember(String tournamentId, TournamentMember member) =>
      _tournaments.doc(tournamentId).collection('members').doc(member.uid).set(member.toJson());

  @override
  Future<void> removeMember(String tournamentId, String uid) =>
      _tournaments.doc(tournamentId).collection('members').doc(uid).delete();

  @override
  Future<Role?> memberRole(String tournamentId, String uid) async {
    final d = await _tournaments.doc(tournamentId).collection('members').doc(uid).get();
    return d.exists ? Role.values.byName(d.data()!['role'] as String) : null;
  }

  @override
  Stream<List<MatchRecord>> watchMatches({String? tournamentId, bool liveOnly = false}) {
    Stream<List<MatchRecord>> read(Query<Map<String, dynamic>> q, {bool public = false}) {
      if (liveOnly) q = q.where('status', whereIn: ['live', 'paused']);
      return q.snapshots(includeMetadataChanges: !public)
          .where((s) => public || !s.metadata.isFromCache)
          .map((s) => [
            for (final d in s.docs)
              if (d.data()['status'] != MatchStatus.voided.name) MatchRecord.fromJson(d.data()),
          ]);
    }

    final scope = tournamentId == null
        ? _matches
        : _matches.where('tournamentId', isEqualTo: tournamentId);
    final public = read(scope.where('isPublic', isEqualTo: true), public: true);
    final user = auth.currentUser;
    final visible = user == null || user.isAnonymous
        ? public
        : _isAdmin(user.uid).switchMap((admin) {
            if (admin) return read(scope);
            return _membershipIds(user.uid).switchMap((ids) {
              if (tournamentId != null) return ids.contains(tournamentId) ? read(scope) : public;
              return Rx.combineLatestList([
                public,
                read(_matches.where('scorerUid', isEqualTo: user.uid)
                    .where('tournamentId', isNull: true)),
                for (final id in ids) read(_matches.where('tournamentId', isEqualTo: id)),
              ]).map((lists) => {for (final m in lists.expand((l) => l)) m.id: m}.values.toList());
            });
          });
    return visible.map((ms) => ms..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
  }

  @override
  Stream<MatchRecord?> watchMatch(String id) => _matches.doc(id)
      .snapshots(includeMetadataChanges: true)
      .where((d) => !d.metadata.isFromCache || d.data()?['isPublic'] == true)
      .map((d) => d.exists ? MatchRecord.fromJson(d.data()!) : null);

  @override
  Future<MatchRecord> createMatch(MatchRecord m) async {
    await _matches.doc(m.id).set(m.toJson());
    return m;
  }

  @override
  Future<MatchRecord> updateMatch(
    String id,
    MatchRecord Function(MatchRecord current) mutate, {
    int? expectedVersion,
  }) {
    final ref = _matches.doc(id);
    return db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('Begegnung $id nicht gefunden');
      final current = MatchRecord.fromJson(snap.data()!);
      if (expectedVersion != null && expectedVersion != current.version) {
        throw VersionConflict();
      }
      final next = mutate(current)
          .copyWith(version: current.version + 1, updatedAt: DateTime.now().toUtc());
      tx.set(ref, next.toJson());
      return next;
    });
  }

  @override
  Stream<List<PlayerProfile>> watchPlayers() => auth.currentUser?.isAnonymous != false
      ? Stream.value(const [])
      : _players.snapshots().map((s) => [
        for (final d in s.docs) PlayerProfile.fromJson(d.data())
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));

  @override
  Future<PlayerProfile> savePlayer(PlayerProfile p) async {
    await _players.doc(p.id).set(p.toJson());
    return p;
  }

  @override
  Future<void> audit(AuditEntry e) => _audit.doc(e.id).set(e.toJson());

  @override
  Stream<List<AuditEntry>> watchAudit({String? tournamentId}) {
    Query<Map<String, dynamic>> q = _audit;
    if (tournamentId != null) q = q.where('tournamentId', isEqualTo: tournamentId);
    return q.snapshots().map((s) => [for (final d in s.docs) AuditEntry.fromJson(d.data())]
      ..sort((a, b) => b.at.compareTo(a.at)));
  }

  @override
  Future<AppUser?> getUser(String uid) async {
    final d = await _users.doc(uid).get();
    return d.exists ? AppUser.fromJson(d.data()!) : null;
  }

  @override
  Future<void> saveUser(AppUser u) => _users.doc(u.uid).set(u.toJson());

  @override
  Stream<List<AppUser>> watchUsers() =>
      _users.snapshots().map((s) => [for (final d in s.docs) AppUser.fromJson(d.data())]);
}
