import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

class BoardTablet {
  final String tournamentId;
  final String boardId;
  final int boardIndex;
  final String? deviceUid;
  final String? code;

  const BoardTablet(
    this.tournamentId,
    this.boardId,
    this.boardIndex, {
    this.deviceUid,
    this.code,
  });

  factory BoardTablet.fromJson(Map<String, dynamic> data) => BoardTablet(
    data['tournamentId'] as String,
    data['boardId'] as String,
    (data['boardIndex'] as num).toInt(),
    deviceUid: data['deviceUid'] as String?,
    code: data['code'] as String?,
  );

  Map<String, Object?> get location => {
    'tournamentId': tournamentId,
    'boardId': boardId,
    'boardIndex': boardIndex,
  };
}

class BoardTablets {
  final FirebaseFirestore db;
  BoardTablets(this.db);

  DocumentReference<Map<String, dynamic>> _board(
    String tournamentId,
    String boardId,
  ) => db
      .collection('tournaments')
      .doc(tournamentId)
      .collection('tablets')
      .doc(boardId);

  DocumentReference<Map<String, dynamic>> _device(String uid) =>
      db.collection('board_devices').doc(uid);

  Stream<List<BoardTablet>> watchBoards(String tournamentId) => db
      .collection('tournaments')
      .doc(tournamentId)
      .collection('tablets')
      .snapshots()
      .map(
        (snapshot) => snapshot.docs
            .map((doc) => BoardTablet.fromJson(doc.data()))
            .toList(),
      );

  Stream<BoardTablet?> watchBoard(String tournamentId, String boardId) =>
      _board(tournamentId, boardId)
          .snapshots(includeMetadataChanges: true)
          .where((doc) => !doc.metadata.isFromCache)
          .map((doc) => doc.exists ? BoardTablet.fromJson(doc.data()!) : null);

  Stream<BoardTablet?> watchDevice(String uid) =>
      _device(uid)
          .snapshots()
          .map((doc) => doc.exists ? BoardTablet.fromJson(doc.data()!) : null);

  Future<String> issueCode(
    String tournamentId,
    String boardId,
    int boardIndex,
  ) async {
    final random = Random.secure();
    final code = List.generate(
      20,
      (_) => random.nextInt(32).toRadixString(32),
    ).join();
    await _board(tournamentId, boardId).set({
      ...BoardTablet(tournamentId, boardId, boardIndex).location,
      'deviceUid': null,
      'code': code,
      'expiresAt': DateTime.now().add(const Duration(minutes: 10)),
    });
    return code;
  }

  Future<void> revoke(String tournamentId, String boardId) =>
      _board(tournamentId, boardId).delete();

  Future<void> pair(String uid, BoardTablet tablet) async {
    final device = _device(uid);
    final board = _board(tablet.tournamentId, tablet.boardId);
    final existing = await device.get(const GetOptions(source: Source.server));
    final saved = existing.data();
    if (saved?['tournamentId'] == tablet.tournamentId &&
        saved?['boardId'] == tablet.boardId) {
      try {
        final active = await board.get(const GetOptions(source: Source.server));
        if (active.data()?['deviceUid'] == uid) return;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
      }
    }
    if (tablet.code == null)
      throw StateError('Diese Tablet-Zuordnung ist nicht mehr aktiv.');
    final batch = db.batch()
      ..set(device, tablet.location)
      ..update(board, {'deviceUid': uid, 'proof': tablet.code});
    await batch.commit();
  }

  Future<void> disconnect(String uid, BoardTablet tablet) async {
    final batch = db.batch()
      ..delete(_device(uid))
      ..delete(_board(tablet.tournamentId, tablet.boardId));
    await batch.commit();
  }
}
