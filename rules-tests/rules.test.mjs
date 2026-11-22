// Tests für ../firestore.rules - laufen gegen den Firestore-Emulator:
//   npm test   (startet den Emulator automatisch über firebase emulators:exec)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, addDoc, collection, collectionGroup, deleteDoc, deleteField, getDocs, query, where, writeBatch } from 'firebase/firestore';

let env;

const user = (uid, role = 'player', playerId = `pl-${uid}`) => ({
  uid, displayName: uid, email: `${uid}@example.org`, role, playerId,
});

function tournament(over = {}) {
  return {
    id: 't1', name: 'Test', format: 'singleElimination', gameType: 'x501',
    rules: {}, isPublic: false, status: 'registration', inviteCode: 'ABC234',
    createdBy: 'admin', createdAt: '2025-01-01T00:00:00Z', registrations: [],
    plan: null, published: false, boards: [], version: 1, ...over,
  };
}

function visit(over = {}) {
  return { id: 'v', playerIndex: 0, legNo: 1, visitNo: 1, startScore: 501, scoreAfter: 441,
    enteredTotal: 60, points: 60, bust: false, checkout: false, darts: null,
    dartsThrown: 3, checkoutAttempts: null, mode: 'total', timestamp: '2025-01-01T00:00:00Z', ...over };
}

function match(over = {}) {
  return {
    id: 'm1', tournamentId: 't1', planMatchId: 'W-r1-m0', gameType: 'x501',
    players: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }], playerIds: ['a', 'b'],
    status: 'live', boardId: null, scorerUid: 'scorer', version: 1,
    createdAt: '2025-01-01T00:00:00Z', updatedAt: '2025-01-01T00:00:00Z', isPublic: false,
    winnerId: null, x01: { rules: {}, playerIds: ['a', 'b'], visits: [] }, draft: [], cricket: null, clock: null,
    ...over,
  };
}

const db = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();
const guest = () => env.authenticatedContext('guest', {
  firebase: { sign_in_provider: 'anonymous' },
}).firestore();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-darts',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});
after(async () => { await env.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const f = ctx.firestore();
    for (const u of [user('admin', 'admin'), user('dir', 'player'), user('scorer', 'player'),
      user('pl', 'player'), user('other', 'player'), user('globalScorer', 'scorer')]) {
      await setDoc(doc(f, 'users', u.uid), u);
    }
    await setDoc(doc(f, 'tournaments/t1'), tournament());
    await setDoc(doc(f, 'tournaments/t1/members/dir'), { uid: 'dir', name: 'dir', role: 'director' });
    await setDoc(doc(f, 'tournaments/t1/members/scorer'), { uid: 'scorer', name: 'scorer', role: 'scorer' });
    await setDoc(doc(f, 'tournaments/t2'), tournament({ id: 't2', name: 'Anderes', isPublic: true, inviteCode: 'PUB234' }));
    await setDoc(doc(f, 'tournaments/t2/members/other'), { uid: 'other', name: 'other', role: 'scorer' });
    await setDoc(doc(f, 'matches/m1'), match());
  });
});

describe('Benutzer und Rollen', () => {
  it('neues Konto nur als player', async () => {
    await assertSucceeds(setDoc(doc(db('new1'), 'users/new1'), user('new1', 'player')));
    await assertFails(setDoc(doc(db('new2'), 'users/new2'), user('new2', 'admin')));
    await assertFails(setDoc(doc(db('new3'), 'users/new3'), user('new3', 'director')));
  });
  it('keine Selbstbeförderung, Admin darf Rollen ändern', async () => {
    await assertFails(updateDoc(doc(db('pl'), 'users/pl'), { role: 'admin' }));
    await assertSucceeds(updateDoc(doc(db('pl'), 'users/pl'), { displayName: 'Neu' }));
    await assertSucceeds(updateDoc(doc(db('admin'), 'users/pl'), { role: 'scorer' }));
  });
  it('fremde Benutzerprofile (E-Mail) sind nicht lesbar', async () => {
    await assertFails(getDoc(doc(db('pl'), 'users/other')));
    await assertSucceeds(getDoc(doc(db('pl'), 'users/pl')));
    await assertSucceeds(getDoc(doc(db('admin'), 'users/pl')));
  });
});

describe('Turniere', () => {
  it('nur Admins legen Turniere an', async () => {
    const t = tournament({ id: 'new', createdBy: 'pl' });
    await assertFails(setDoc(doc(db('pl'), 'tournaments/new'), t));
    await assertFails(setDoc(doc(db('dir'), 'tournaments/new'), { ...t, createdBy: 'dir' }));
    await assertSucceeds(setDoc(doc(db('admin'), 'tournaments/new'), { ...t, createdBy: 'admin' }));
    await assertFails(setDoc(doc(db('admin'), 'tournaments/new2'), { ...t, id: 'new2', createdBy: 'admin', version: 5 }));
  });
  it('Leitung darf ändern, aber nur mit Versionssprung +1', async () => {
    await assertSucceeds(updateDoc(doc(db('dir'), 'tournaments/t1'), { name: 'Neu', version: 2 }));
    await assertFails(updateDoc(doc(db('dir'), 'tournaments/t1'), { name: 'Neu2', version: 2 })); // veraltet
    await assertFails(updateDoc(doc(db('dir'), 'tournaments/t1'), { name: 'Neu3', version: 9 }));
  });
  it('unveränderliche Felder', async () => {
    await assertFails(updateDoc(doc(db('admin'), 'tournaments/t1'), { inviteCode: 'HACKED', version: 2 }));
    await assertFails(updateDoc(doc(db('admin'), 'tournaments/t1'), { createdBy: 'pl', version: 2 }));
  });
  it('Selbstanmeldung: genau man selbst, nur in der Anmeldephase', async () => {
    const me = { id: 'pl-pl', name: 'pl', seed: null };
    await assertFails(updateDoc(doc(db('pl'), 'tournaments/t1'), { registrations: [me], version: 2 }));
    await assertSucceeds(setDoc(doc(db('pl'), 'tournaments/t1/members/pl'),
      { uid: 'pl', name: 'pl', role: 'player', inviteCode: 'ABC234' }));
    await assertSucceeds(updateDoc(doc(db('pl'), 'tournaments/t1'), { registrations: [me], version: 2 }));
    // fremden Spieler eintragen
    await assertFails(updateDoc(doc(db('other'), 'tournaments/t1'), {
      registrations: [{ id: 'pl-pl', name: 'pl' }], version: 2 }));
    // zwei auf einmal
    await assertFails(updateDoc(doc(db('pl'), 'tournaments/t1'), {
      registrations: [me, { id: 'x', name: 'x' }], version: 2 }));
    // andere Felder gleichzeitig
    await assertFails(updateDoc(doc(db('pl'), 'tournaments/t1'), {
      registrations: [me], name: 'Hack', version: 2 }));
  });
  it('Selbstanmeldung nach Auslosung gesperrt', async () => {
    await env.withSecurityRulesDisabled((c) => updateDoc(doc(c.firestore(), 'tournaments/t1'), { status: 'drawn' }));
    await assertFails(updateDoc(doc(db('pl'), 'tournaments/t1'), {
      registrations: [{ id: 'pl-pl', name: 'pl' }], version: 2 }));
  });
  it('Schreiber ändert nur die Boardbelegung', async () => {
    await assertSucceeds(updateDoc(doc(db('scorer'), 'tournaments/t1'), { boards: [{ id: 'b1', name: 'B1', currentMatchId: 'm1' }], version: 2 }));
    await assertFails(updateDoc(doc(db('scorer'), 'tournaments/t1'), { published: true, version: 2 }));
    await assertFails(updateDoc(doc(db('scorer'), 'tournaments/t1'), { plan: { x: 1 }, version: 2 }));
  });
  it('Unbeteiligte Spieler und Zuschauer dürfen nichts ändern', async () => {
    await assertFails(updateDoc(doc(db('other'), 'tournaments/t1'), { name: 'x', version: 2 }));
    await assertFails(deleteDoc(doc(db('dir'), 'tournaments/t1')));
    await assertSucceeds(deleteDoc(doc(db('admin'), 'tournaments/t1')));
  });
  it('Öffentliche Listen funktionieren; private Daten sind nur für Mitglieder und Admins lesbar', async () => {
    for (const f of [db('pl'), guest(), anon()]) {
      await assertFails(getDoc(doc(f, 'tournaments/t1')));
      await assertFails(getDoc(doc(f, 'matches/m1')));
      await assertSucceeds(getDoc(doc(f, 'tournaments/t2')));
      const visible = await assertSucceeds(getDocs(query(collection(f, 'tournaments'),
        where('isPublic', '==', true))));
      assert.deepEqual(visible.docs.map((d) => d.id), ['t2']);
      await assertSucceeds(getDocs(query(collection(f, 'matches'), where('tournamentId', '==', 't2'),
        where('isPublic', '==', true))));
    }
    await assertFails(getDocs(collection(db('pl'), 'matches')));
    await assertSucceeds(getDoc(doc(db('admin'), 'tournaments/t1')));
    await assertSucceeds(getDoc(doc(db('dir'), 'tournaments/t1')));
    await assertSucceeds(getDocs(query(collection(db('dir'), 'matches'), where('tournamentId', '==', 't1'))));
    const memberships = await assertSucceeds(getDocs(query(collectionGroup(db('dir'), 'members'),
      where('uid', '==', 'dir'))));
    assert.deepEqual(memberships.docs.map((d) => d.ref.path), ['tournaments/t1/members/dir']);
    await assertFails(getDocs(query(collectionGroup(db('dir'), 'members'), where('uid', '==', 'scorer'))));
  });
  it('Anonyme können nie schreiben', async () => {
    await assertFails(setDoc(doc(anon(), 'tournaments/x'), tournament({ id: 'x' })));
    await assertFails(updateDoc(doc(anon(), 'tournaments/t2'), { name: 'x', version: 2 }));
  });
});

describe('Duo-Auslosung', () => {
  it('Losnummern und Teams ändert nur die Leitung; nach der Paarung schließt die Anmeldung', async () => {
    const t = doc(db('admin'), 'tournaments/duo');
    await assertFails(setDoc(t, tournament({ id: 'duo', isDuo: true })));
    await assertSucceeds(setDoc(t, tournament({
      id: 'duo', isDuo: true, format: 'groupsKnockout', isPublic: true,
    })));
    const pl = doc(db('pl'), 'tournaments/duo');
    const me = { id: 'pl-pl', name: 'pl', seed: null };
    await assertFails(updateDoc(pl, { registrations: [{ ...me, lotNumber: 4 }], version: 2 }));
    await assertSucceeds(updateDoc(pl, { registrations: [me], version: 2 }));
    await assertFails(updateDoc(pl, { duoTeams: [{ id: 'duo-1' }], version: 3 }));
    await assertSucceeds(updateDoc(t, { duoTeams: [{ id: 'duo-1' }], version: 3 }));
    await assertFails(updateDoc(doc(db('other'), 'tournaments/duo'), {
      registrations: [me, { id: 'pl-other', name: 'Other', seed: null }], version: 4,
    }));
    await assertFails(updateDoc(t, { isDuo: false, version: 4 }));
  });
});

describe('Turnier-Papierkorb', () => {
  it('nur Admins verschieben; Turnierlinks und Spiele werden beim Wiederherstellen erneut sichtbar', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'matches/public'),
      match({ id: 'public', tournamentId: 't2', isPublic: true })));
    const admin = db('admin');
    const t = doc(admin, 'tournaments/t2');
    const trash = { movedAt: '2026-11-22T12:00:00Z', wasPublic: true };
    const hidden = { trash, isPublic: false, version: 2 };
    const publicMatches = query(collection(anon(), 'matches'),
      where('tournamentId', '==', 't2'), where('isPublic', '==', true));
    await assertSucceeds(getDocs(publicMatches));
    await assertFails(updateDoc(doc(db('other'), 'tournaments/t2'), hidden));
    await assertFails(updateDoc(t, { ...hidden, trash: { ...trash, wasPublic: false } }));
    await assertFails(updateDoc(t, { ...hidden, name: 'Geändert' }));
    await assertSucceeds(updateDoc(t, hidden));
    await assertFails(getDoc(doc(anon(), 'tournaments/t2')));
    await assertFails(getDoc(doc(anon(), 'matches/public')));
    await assertFails(getDocs(publicMatches));
    await assertFails(getDoc(doc(db('other'), 'matches/public')));
    await assertFails(updateDoc(doc(admin, 'matches/public'), { draft: [320], version: 2 }));
    await assertFails(updateDoc(t, { trash: deleteField(), isPublic: false, version: 3 }));
    await assertSucceeds(updateDoc(t, { trash: deleteField(), isPublic: true, version: 3 }));
    await assertSucceeds(getDoc(doc(anon(), 'tournaments/t2')));
    const visible = await assertSucceeds(getDocs(publicMatches));
    assert.deepEqual(visible.docs.map((entry) => entry.id), ['public']);
  });

  it('private Turniere bleiben bei der Wiederherstellung privat', async () => {
    const t = doc(db('admin'), 'tournaments/t1');
    const trash = { movedAt: '2026-11-22T12:00:00Z', wasPublic: false };
    await assertSucceeds(updateDoc(t, { trash, version: 2 }));
    await assertFails(updateDoc(t, { trash: deleteField(), isPublic: true, version: 3 }));
    await assertSucceeds(updateDoc(t, { trash: deleteField(), version: 3 }));
    await assertFails(getDoc(doc(anon(), 'tournaments/t1')));
    await assertSucceeds(getDoc(doc(db('dir'), 'matches/m1')));
  });
});

describe('Turnier-Mitglieder', () => {
  it('Spieler kann sich nicht zum Schreiber machen', async () => {
    const player = { uid: 'pl', name: 'pl', role: 'player' };
    await assertFails(setDoc(doc(db('pl'), 'tournaments/t1/members/pl'), player));
    await assertFails(setDoc(doc(db('pl'), 'tournaments/t1/members/pl'), { ...player, inviteCode: 'WRONG1' }));
    await assertFails(setDoc(doc(guest(), 'tournaments/t1/members/guest'),
      { ...player, uid: 'guest', inviteCode: 'ABC234' }));
    await assertSucceeds(setDoc(doc(db('pl'), 'tournaments/t1/members/pl'),
      { ...player, inviteCode: 'ABC234' }));
    await assertSucceeds(getDoc(doc(db('pl'), 'tournaments/t1')));
    await assertSucceeds(getDoc(doc(db('pl'), 'matches/m1')));
    await assertFails(setDoc(doc(db('other'), 'tournaments/t1/members/other'), { uid: 'other', name: 'o', role: 'scorer' }));
    await assertFails(setDoc(doc(db('other'), 'tournaments/t1/members/other'), { uid: 'other', name: 'o', role: 'director' }));
  });
  it('Einladungsindex wird zusammen mit einem neuen Turnier angelegt und ist nicht auflistbar', async () => {
    const f = db('admin');
    const batch = writeBatch(f);
    batch.set(doc(f, 'tournaments/t3'), tournament({ id: 't3', inviteCode: 'NEW234' }));
    batch.set(doc(f, 'tournament_invites/NEW234'), { tournamentId: 't3' });
    await assertSucceeds(batch.commit());
    await assertFails(setDoc(doc(db('other'), 'tournament_invites/ABC234'), { tournamentId: 't1' }));
    await assertFails(setDoc(doc(f, 'tournament_invites/WRONG1'), { tournamentId: 't3' }));
    await assertFails(getDocs(collection(db('pl'), 'tournament_invites')));
    await assertFails(getDoc(doc(guest(), 'tournament_invites/NEW234')));
    await assertSucceeds(getDoc(doc(db('pl'), 'tournament_invites/NEW234')));
  });
  it('bestehende Rolle kann nicht selbst überschrieben werden', async () => {
    await assertFails(setDoc(doc(db('scorer'), 'tournaments/t1/members/scorer'), { uid: 'scorer', name: 's', role: 'player' }));
  });
  it('Leitung vergibt Schreiber, aber keine Leitung; Admin alles', async () => {
    await assertSucceeds(setDoc(doc(db('dir'), 'tournaments/t1/members/pl'), { uid: 'pl', name: 'pl', role: 'scorer' }));
    await assertFails(setDoc(doc(db('dir'), 'tournaments/t1/members/pl'), { uid: 'pl', name: 'pl', role: 'director' }));
    await assertSucceeds(setDoc(doc(db('admin'), 'tournaments/t1/members/pl'), { uid: 'pl', name: 'pl', role: 'director' }));
  });
});

describe('Begegnungen und gleichzeitige Eingaben', () => {
  it('Schreiber des Turniers darf eintragen (Version +1)', async () => {
    const v = visit();
    await assertSucceeds(updateDoc(doc(db('scorer'), 'matches/m1'), {
      x01: { rules: {}, playerIds: ['a', 'b'], visits: [v] }, version: 2 }));
  });
  it('zweiter Schreiber mit altem Stand wird abgewiesen', async () => {
    await assertSucceeds(updateDoc(doc(db('scorer'), 'matches/m1'), { draft: [320], version: 2 }));
    await assertFails(updateDoc(doc(db('dir'), 'matches/m1'), { draft: [120], version: 2 }));
    await assertSucceeds(updateDoc(doc(db('dir'), 'matches/m1'), { draft: [120], version: 3 }));
  });
  it('Spieler, Zuschauer und fremde Schreiber dürfen nicht eingeben', async () => {
    for (const uid of ['pl', 'other', 'nobody']) {
      await assertFails(updateDoc(doc(db(uid), 'matches/m1'), { draft: [120], version: 2 }));
    }
    await assertFails(updateDoc(doc(anon(), 'matches/m1'), { draft: [120], version: 2 }));
  });
  it('globaler Schreiber darf', async () => {
    await assertSucceeds(updateDoc(doc(db('globalScorer'), 'matches/m1'), { draft: [120], version: 2 }));
  });
  it('Bestätigen nur durch die Turnierleitung', async () => {
    await assertFails(updateDoc(doc(db('scorer'), 'matches/m1'), { status: 'confirmed', version: 2 }));
    await assertSucceeds(updateDoc(doc(db('scorer'), 'matches/m1'), { status: 'awaitingConfirmation', version: 2 }));
    await assertSucceeds(updateDoc(doc(db('dir'), 'matches/m1'), { status: 'confirmed', version: 3 }));
  });
  it('Korrektur und Annullierung bleiben der Turnierleitung vorbehalten', async () => {
    await env.withSecurityRulesDisabled((c) => updateDoc(doc(c.firestore(), 'matches/m1'),
      { status: 'confirmed', winnerId: 'a' }));
    const correction = { correction: { legsA: 0, legsB: 1, winnerIndex: 1 }, winnerId: 'b', version: 2 };
    await assertFails(updateDoc(doc(db('scorer'), 'matches/m1'), correction));
    await assertFails(updateDoc(doc(db('dir'), 'matches/m1'), { ...correction, winnerId: 'a' }));
    await assertSucceeds(updateDoc(doc(db('dir'), 'matches/m1'), correction));
    await assertFails(updateDoc(doc(db('scorer'), 'matches/m1'), { status: 'voided', version: 3 }));
    await assertSucceeds(updateDoc(doc(db('dir'), 'matches/m1'), { status: 'voided', version: 3 }));
    await assertFails(updateDoc(doc(db('dir'), 'matches/m1'), { status: 'confirmed', version: 4 }));
  });
  it('Plausibilität: Punkte 0..180, Darts 1..3, nur eine Aufnahme je Schreibvorgang', async () => {
    const ref = doc(db('scorer'), 'matches/m1');
    const wrap = (visits) => ({ x01: { rules: {}, playerIds: ['a', 'b'], visits }, version: 2 });
    await assertFails(updateDoc(ref, wrap([visit({ points: 181 })])));
    await assertFails(updateDoc(ref, wrap([visit({ points: -5 })])));
    await assertFails(updateDoc(ref, wrap([visit({ dartsThrown: 4 })])));
    await assertFails(updateDoc(ref, wrap([visit({ dartsThrown: 0 })])));
    await assertFails(updateDoc(ref, wrap([visit(), visit({ id: 'v2' })])));
    await assertSucceeds(updateDoc(ref, wrap([visit({ points: 180, dartsThrown: 3 })])));
  });
  it('unveränderliche Felder (Spieler, Turnier)', async () => {
    await assertFails(updateDoc(doc(db('dir'), 'matches/m1'), { players: [{ id: 'x', name: 'X' }], version: 2 }));
    await assertFails(updateDoc(doc(db('dir'), 'matches/m1'), { tournamentId: 't2', version: 2 }));
  });
  it('Turnier-Begegnung anlegen: nur Schreiber/Leitung', async () => {
    const m = match({ id: 'm2', version: 0, planMatchId: 'W-r1-m1' });
    await assertFails(setDoc(doc(db('pl'), 'matches/m2'), m));
    await assertSucceeds(setDoc(doc(db('scorer'), 'matches/m2'), m));
    await assertFails(setDoc(doc(db('scorer'), 'matches/m3'), { ...m, id: 'm3', version: 7 }));
  });
  it('Freundschaftsspiel: jeder Angemeldete, aber nur der Schreiber ändert', async () => {
    const f = match({ id: 'f1', tournamentId: null, planMatchId: null, version: 0, scorerUid: 'pl' });
    await assertSucceeds(setDoc(doc(db('pl'), 'matches/f1'), f));
    await assertFails(setDoc(doc(db('pl'), 'matches/f2'), { ...f, id: 'f2', scorerUid: 'other' }));
    await assertSucceeds(updateDoc(doc(db('pl'), 'matches/f1'), { draft: [120], version: 1 }));
    await assertFails(updateDoc(doc(db('other'), 'matches/f1'), { draft: [120], version: 2 }));
  });
  it('Cricket-Begegnung (ohne x01) ist schreibbar', async () => {
    await env.withSecurityRulesDisabled((c) => setDoc(doc(c.firestore(), 'matches/c1'),
      match({ id: 'c1', gameType: 'cricket', x01: null, cricket: { cutThroat: false, darts: [] } })));
    await assertSucceeds(updateDoc(doc(db('scorer'), 'matches/c1'),
      { cricket: { cutThroat: false, darts: [320] }, version: 2 }));
  });
  it('Lesen öffentlicher Spiele ohne Anmeldung', async () => {
    await env.withSecurityRulesDisabled((c) => updateDoc(doc(c.firestore(), 'matches/m1'), { isPublic: true, tournamentId: 't2' }));
    await assertSucceeds(getDoc(doc(anon(), 'matches/m1')));
  });
});

describe('Spieler und Audit-Log', () => {
  it('Spielerprofile: eigenes bearbeiten, fremdes nicht', async () => {
    await assertSucceeds(setDoc(doc(db('pl'), 'players/pl-pl'), { id: 'pl-pl', name: 'pl', uid: 'pl', favoriteDouble: null }));
    await assertFails(getDoc(doc(guest(), 'players/pl-pl')));
    await assertSucceeds(updateDoc(doc(db('pl'), 'players/pl-pl'), { favoriteDouble: 16 }));
    await assertFails(updateDoc(doc(db('other'), 'players/pl-pl'), { favoriteDouble: 20 }));
    await assertFails(setDoc(doc(db('other'), 'players/x'), { id: 'x', name: 'x', uid: 'pl' })); // fremde uid
    await assertSucceeds(setDoc(doc(db('other'), 'players/guest'), { id: 'guest', name: 'Gast', uid: null }));
  });
  it('Audit-Log ist append-only', async () => {
    const entry = { id: 'a1', at: '2025-01-01T00:00:00Z', uid: 'dir', action: 'x', tournamentId: 't1', matchId: null, detail: '' };
    await assertSucceeds(setDoc(doc(db('dir'), 'audit_logs/a1'), entry));
    await assertFails(setDoc(doc(db('dir'), 'audit_logs/a2'), { ...entry, id: 'a2', uid: 'someoneElse' })); // fremde uid
    await assertFails(updateDoc(doc(db('dir'), 'audit_logs/a1'), { action: 'y' }));
    await assertFails(deleteDoc(doc(db('admin'), 'audit_logs/a1')));
    await assertSucceeds(getDoc(doc(db('admin'), 'audit_logs/a1')));
    await assertSucceeds(getDoc(doc(db('dir'), 'audit_logs/a1')));
    await assertFails(getDoc(doc(db('pl'), 'audit_logs/a1')));
  });
  it('unbekannte Collections sind gesperrt', async () => {
    await assertFails(setDoc(doc(db('admin'), 'foo/bar'), { a: 1 }));
    await assertFails(getDoc(doc(db('admin'), 'foo/bar')));
  });
});

describe('Board-Tablet', () => {
  const code = 'abcdefghijklmnopqrst';
  const stationPath = 'tournaments/t1/tablets/b1';
  const location = { tournamentId: 't1', boardId: 'b1', boardIndex: 0 };

  async function prepare() {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const f = ctx.firestore();
      await updateDoc(doc(f, 'tournaments/t1'), {
        boards: [
          { id: 'b1', name: 'Board 1', currentMatchId: 'm1' },
          { id: 'b2', name: 'Board 2', currentMatchId: 'm2' },
        ],
      });
      await updateDoc(doc(f, 'matches/m1'), { boardId: 'b1' });
      await setDoc(doc(f, 'matches/m2'), match({ id: 'm2', boardId: 'b2' }));
    });
  }

  const station = (over = {}) => ({
    ...location, code, deviceUid: null, expiresAt: new Date(Date.now() + 600_000), ...over,
  });
  const tablet = (uid) => env.authenticatedContext(uid, {
    firebase: { sign_in_provider: 'anonymous' },
  }).firestore();
  function claim(f, uid, proof, place = location) {
    const batch = writeBatch(f);
    batch.set(doc(f, 'board_devices', uid), place);
    batch.update(doc(f, stationPath), { deviceUid: uid, proof });
    return batch.commit();
  }

  it('Kopplung erfordert gültigen Einmalcode, Geräte-ID und Board', async () => {
    await prepare();
    const f = tablet('pad');
    await assertFails(setDoc(doc(db('scorer'), stationPath), station()));
    await assertFails(setDoc(doc(db('dir'), stationPath), station({ boardIndex: 1 })));
    await assertSucceeds(setDoc(doc(db('dir'), stationPath), station()));
    await assertSucceeds(getDocs(collection(db('dir'), 'tournaments/t1/tablets')));
    await assertFails(getDoc(doc(f, stationPath)));
    await assertFails(getDocs(collection(f, 'tournaments/t1/tablets')));
    await assertFails(claim(f, 'pad', 'wrong'));
    await assertFails(claim(f, 'pad', code, { ...location, boardIndex: 1 }));
    await assertFails(claim(db('pl'), 'pl', code));
    await assertFails(setDoc(doc(f, 'board_devices/pad'), location));
    await assertSucceeds(claim(f, 'pad', code));
    await assertSucceeds(getDoc(doc(f, stationPath)));
    await assertSucceeds(getDoc(doc(f, 'tournaments/t1')));
    const t = doc(db('admin'), 'tournaments/t1');
    await assertSucceeds(updateDoc(t, {
      trash: { movedAt: '2026-11-22T12:00:00Z', wasPublic: false }, version: 2,
    }));
    await assertSucceeds(getDoc(doc(f, 'tournaments/t1')));
    await assertFails(updateDoc(doc(f, 'matches/m1'), { draft: [320], version: 2 }));
    await assertSucceeds(updateDoc(t, { trash: deleteField(), version: 3 }));
    await assertSucceeds(updateDoc(doc(f, 'matches/m1'), { draft: [320], version: 2 }));
    await assertFails(claim(tablet('pad2'), 'pad2', code));
    await assertFails(setDoc(doc(db('dir'), stationPath), station()));
  });

  it('Tablet schreibt nur aktuelle Begegnung und verliert Zugriff beim Trennen', async () => {
    await prepare();
    const f = tablet('pad');
    await assertSucceeds(setDoc(doc(db('dir'), stationPath), station()));
    await assertSucceeds(claim(f, 'pad', code));
    const current = doc(f, 'matches/m1');
    const other = doc(f, 'matches/m2');
    await assertSucceeds(getDoc(current));
    await assertFails(getDoc(other));
    await assertSucceeds(updateDoc(current, { draft: [320], version: 2 }));
    await assertFails(updateDoc(other, { draft: [320], version: 2 }));
    await assertFails(updateDoc(current, { status: 'confirmed', version: 3 }));
    await assertFails(updateDoc(current, { boardId: 'b2', version: 3 }));
    await assertSucceeds(updateDoc(current, { status: 'awaitingConfirmation', winnerId: 'a', version: 3 }));
    await assertSucceeds(updateDoc(doc(db('dir'), 'tournaments/t1'), {
      boards: [
        { id: 'b1', name: 'Board 1', currentMatchId: null },
        { id: 'b2', name: 'Board 2', currentMatchId: 'm2' },
      ],
      version: 2,
    }));
    await assertFails(updateDoc(current, { draft: [], version: 4 }));
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'matches/m3'),
      match({ id: 'm3', boardId: 'b1' })));
    await assertSucceeds(updateDoc(doc(db('dir'), 'tournaments/t1'), {
      boards: [
        { id: 'b1', name: 'Board 1', currentMatchId: 'm3' },
        { id: 'b2', name: 'Board 2', currentMatchId: 'm2' },
      ],
      version: 3,
    }));
    await assertSucceeds(updateDoc(doc(f, 'matches/m3'), { draft: [320], version: 2 }));
    await assertFails(updateDoc(current, { draft: [], version: 4 }));
    await assertSucceeds(deleteDoc(doc(db('dir'), stationPath)));
    await assertFails(getDoc(doc(f, 'tournaments/t1')));
    await assertSucceeds(setDoc(doc(db('dir'), stationPath), station({ code: 'bcdefghijklmnopqrstu' })));
    await assertSucceeds(claim(tablet('pad2'), 'pad2', 'bcdefghijklmnopqrstu'));
  });

  it('abgelaufene Kopplung wird abgewiesen und Tablet kann sich selbst trennen', async () => {
    await prepare();
    const f = tablet('pad');
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), stationPath), station({ expiresAt: new Date(Date.now() - 1000) }));
    });
    await assertFails(claim(f, 'pad', code));
    await assertSucceeds(setDoc(doc(db('dir'), stationPath), station()));
    await assertSucceeds(claim(f, 'pad', code));
    const batch = writeBatch(f);
    batch.delete(doc(f, 'board_devices/pad'));
    batch.delete(doc(f, stationPath));
    await assertSucceeds(batch.commit());
    await assertFails(getDoc(doc(f, 'matches/m1')));
    await assertFails(claim(f, 'pad', code));
  });
});
