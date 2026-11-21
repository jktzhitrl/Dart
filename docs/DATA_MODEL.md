# Datenmodell (Cloud Firestore)

| Collection | Dokument | Inhalt |
|---|---|---|
| `users/{uid}` | `AppUser` | `displayName`, `email`, **`role`** (`spectator`/`player`/`scorer`/`director`/`admin`), `playerId` |
| `players/{id}` | `PlayerProfile` | `name`, `uid` (oder `null` = Gast), `favoriteDouble` |
| `tournaments/{id}` | `TournamentRecord` | `name`, `format`, `gameType`, `rules`, `isPublic`, `status`, `inviteCode`, `registrations[]`, **`plan`** (Auslosung/Turnierstand), `published`, `boards[]`, `version` |
| `tournaments/{id}/members/{uid}` | `TournamentMember` | Rolle im Turnier (`player`/`scorer`/`director`) |
| `tournament_invites/{code}` | Einladungscode | `tournamentId`; einzelne Codes sind nur für angemeldete Konten abrufbar |
| `matches/{id}` | `MatchRecord` | `tournamentId`, `planMatchId`, `gameType`, `players[]`, `status`, `boardId`, `scorerUid`, `version`, `draft[]`, **`x01`** / `cricket` / `clock`, `winnerId`, `isPublic`, optionale `correction` mit offiziellem Leg-Ergebnis |
| `audit_logs/{id}` | `AuditEntry` | `at`, `uid`, `action`, `tournamentId`, `matchId`, `detail` – append-only |

## Zuordnung zur Anforderungsliste

| Anforderung | Umsetzung |
|---|---|
| `users`, `players`, `tournaments`, `tournament_members`, `matches`, `boards`, `audit_logs` | als Collections bzw. Subcollection `members`; **Boards** liegen als Liste `boards[]` im Turnier (`currentMatchId` = Belegung) |
| `legs`, `sets`, `visits`, `darts`, `checkout_attempts` | **eingebettet** in `matches/{id}.x01`: `visits[]` enthält je Aufnahme `legNo`, `darts[]`, `checkoutAttempts`; Legs/Sätze werden per Replay abgeleitet (`legResults`). Grund: atomare Versionierung, ein Listener, < 1 MB |
| `statistics` | wird **nicht** gespeichert, sondern aus den Matches berechnet (`StatsService`) – keine Inkonsistenz möglich |

## `x01` (im Match-Dokument)

```jsonc
{
  "rules": { "startScore": 501, "inMode": "straight", "outMode": "double",
             "format": { "legsToWinSet": 2, "setsToWin": 1 },
             "starterRule": "alternating", "bullOffForDecider": false },
  "playerIds": ["pl1", "pl2"], "firstStarter": 0, "starterOverrides": {},
  "visits": [{
    "id": "v…", "playerIndex": 0, "legNo": 1, "visitNo": 1,
    "startScore": 501, "scoreAfter": 321, "enteredTotal": 180, "points": 180,
    "bust": false, "checkout": false,
    "darts": [320, 320, 320],      // Modus A: multiplier*100+number (Miss=0, T20=320, Bull=225); Modus B: null
    "dartsThrown": 3, "checkoutAttempts": null,
    "mode": "perDart", "timestamp": "2025-01-01T20:00:00Z"
  }]
}
```

Darts sind als Zahl codiert, weil Firestore **keine verschachtelten Arrays** erlaubt.

## Security Rules (`firestore.rules`)

* **Rollen:** globale Rolle in `users/{uid}.role`, Turnierrolle in `members/{uid}`; es gilt die höhere.
* **Konten** starten immer als `player`; niemand kann sich selbst befördern, nur Admins ändern Rollen.
* **Turniere** legen nur Admins an. Die Turnierleitung ändert alles (außer unveränderlichen Feldern wie
  `inviteCode`), Spieler dürfen sich in der Anmeldephase genau einmal selbst eintragen, Schreiber ändern nur `boards`.
* **Begegnungen:** Eingabe nur Schreiber/Leitung des Turniers (Freundschaftsspiele: der Schreiber selbst);
  Bestätigung (`confirmed`) nur Turnierleitung; `players`, `tournamentId`, `gameType` unveränderlich;
  Plausibilität (Punkte 0–180, Darts 1–3, höchstens eine neue Aufnahme je Schreibvorgang).
* **Versionssperre:** Updates müssen `version == alt + 1` setzen.
* **Audit-Log:** nur anhängen, nur mit eigener `uid`.
* **Lesen:** Öffentliche Turniere und Spiele sind für Gäste lesbar. Private Turniere und ihre Spiele
  sehen nur Mitglieder und Admins. Anonyme Zuschauer erhalten keine Spielerprofile.
* **Korrekturen:** Bei geänderten Paarungen bleiben die annullierten Begegnungen samt Wurfprotokoll
  gespeichert. Der Spielplan, die betroffenen Begegnungen und der Audit-Eintrag ändern sich gemeinsam.
  Korrigierte Spiele zählen mit dem offiziellen Sieger; die daraus nicht zuverlässig ableitbaren
  Wurfstatistiken bleiben bei der Berechnung außen vor.

## Indizes

`firestore.indexes.json` enthält den Collection-Group-Index `members.uid` für die Suche nach
eigenen Turniermitgliedschaften sowie die Indizes für die vorhandenen Turnier- und Spielabfragen.
