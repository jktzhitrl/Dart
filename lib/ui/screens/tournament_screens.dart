import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/auth/permissions.dart';
import '../../core/models/ids.dart';
import '../../core/models/rules.dart';
import '../../core/tournament/participant.dart';
import '../../core/tournament/tournament_plan.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../../data/services.dart';
import '../theme.dart';
import '../widgets/bracket_view.dart';
import '../widgets/standings_table.dart';
import '../widgets/tournament_export_button.dart';
import '../widgets/board_tablet_controls.dart';
import '../../bootstrap.dart';
import 'live_screen.dart';
import 'result_correction.dart';
import 'new_match_screen.dart';
import 'scoring_screen.dart';

const String _baseUrl = String.fromEnvironment('APP_BASE_URL');

/// Öffentliche Links öffnen die Ansicht; private Links geben eingeladenen
/// Konten Lesezugriff, unabhängig von der Anmeldung als Turnierteilnehmer.
Uri _appUri() {
  var base = _baseUrl;
  if (base.isEmpty && kIsWeb) base = Uri.base.origin + Uri.base.path;
  if (base.isEmpty) base = 'https://example.web.app/';
  return Uri.parse(base);
}

String inviteLink(TournamentRecord t) {
  final uri = _appUri();
  return uri.replace(queryParameters: {
    ...uri.queryParameters,
    'tournament': t.id,
    if (!t.isPublic) 'invite': t.inviteCode,
  }).toString();
}

String statusLabel(TournamentStatus s) => switch (s) {
      TournamentStatus.registration => 'Anmeldung',
      TournamentStatus.drawn => 'Ausgelost (Entwurf)',
      TournamentStatus.running => 'Läuft',
      TournamentStatus.finished => 'Beendet',
    };

class TournamentListScreen extends StatelessWidget {
  const TournamentListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AppRepository>();
    final user = context.watch<AppUser>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: can(user.role, Permission.createTournament)
          ? FloatingActionButton.extended(
              key: const Key('newTournament'),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const TournamentCreateScreen())),
              icon: const Icon(Icons.add),
              label: const Text('Neues Turnier'),
            )
          : null,
      body: StreamBuilder<List<TournamentRecord>>(
        stream: repo.watchTournaments(),
        builder: (context, snap) {
          if (snap.hasError) return const _Hint('Die Turnierliste konnte nicht geladen werden.');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!
              .where((t) => repo.isRemote || t.isPublic || t.createdBy == user.uid || user.role != Role.spectator)
              .toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(child: Text('Turniere', style: Theme.of(context).textTheme.headlineSmall)),
              if (user.role == Role.admin)
                IconButton(
                  tooltip: 'Turnier-Papierkorb',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute<void>(builder: (_) => const _TournamentTrashScreen())),
                ),
              OutlinedButton.icon(
                key: const Key('joinByCode'),
                onPressed: () => showJoinDialog(context),
                icon: const Icon(Icons.qr_code),
                label: const Text('Einladungscode'),
              ),
            ]),
            const SizedBox(height: 12),
            if (list.isEmpty)
              const Card(
                  child: ListTile(
                      leading: Icon(Icons.emoji_events_outlined),
                      title: Text('Noch keine Turniere'),
                      subtitle: Text('Lege ein Turnier an oder tritt per Einladungscode bei.'))),
            for (final t in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.emoji_events, color: AppColors.accent),
                    title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${t.format.label} · ${t.gameType.label} · ${statusLabel(t.status)} · ${t.plan?.participants.length ?? t.registrations.length} Teilnehmer'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => TournamentDetailScreen(id: t.id))),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class _TournamentTrashScreen extends StatefulWidget {
  const _TournamentTrashScreen();

  @override
  State<_TournamentTrashScreen> createState() => _TournamentTrashScreenState();
}

class _TournamentTrashScreenState extends State<_TournamentTrashScreen> {
  late final _trash = context.read<AppRepository>().watchTrash();
  final _busy = <String>{};

  Future<void> _restore(TournamentRecord tournament) async {
    if (!_busy.add(tournament.id)) return;
    setState(() {});
    final service = context.read<TournamentService>();
    final user = context.read<AppUser>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.restoreTournament(user, tournament);
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('„${tournament.name}“ wiederhergestellt.')));
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy.remove(tournament.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Turnier-Papierkorb')),
    body: StreamBuilder<List<TournamentRecord>>(
      stream: _trash,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _Hint('Der Papierkorb konnte nicht geladen werden.');
        final tournaments = snapshot.data;
        if (tournaments == null) return const Center(child: CircularProgressIndicator());
        if (tournaments.isEmpty) return const _Hint('Der Papierkorb ist leer.');
        final dates = MaterialLocalizations.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final tournament in tournaments)
              Card(child: ListTile(
                title: Text(tournament.name),
                subtitle: Text('Im Papierkorb seit ${dates.formatShortDate(tournament.trash!.movedAt.toLocal())}'),
                trailing: TextButton.icon(
                  key: Key('restore-${tournament.id}'),
                  icon: const Icon(Icons.restore),
                  label: const Text('Wiederherstellen'),
                  onPressed: _busy.contains(tournament.id) ? null : () => _restore(tournament),
                ),
              )),
          ],
        );
      },
    ),
  );
}

Future<void> openTournamentLink(BuildContext context, {String? id, String? code}) async {
  final repo = context.read<AppRepository>();
  final user = context.read<AppUser>();
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  try {
    if (code != null) id = await repo.resolveInvite(user, code, tournamentId: id);
    if (!context.mounted) return;
    if (id == null || id.isEmpty || id.contains('/')) {
      throw StateError('Kein Turnier zu dieser Einladung gefunden.');
    }
    nav.push(MaterialPageRoute(builder: (_) => TournamentDetailScreen(id: id!)));
  } catch (e) {
    if (context.mounted) messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<void> showJoinDialog(BuildContext context, {String? code}) async {
  final entered = await showDialog<String>(
    context: context,
    builder: (_) => _InviteCodeDialog(code: code),
  );
  if (context.mounted && entered != null) {
    await openTournamentLink(context, code: entered);
  }
}

class _InviteCodeDialog extends StatefulWidget {
  final String? code;
  const _InviteCodeDialog({this.code});

  @override
  State<_InviteCodeDialog> createState() => _InviteCodeDialogState();
}

class _InviteCodeDialogState extends State<_InviteCodeDialog> {
  late final _controller = TextEditingController(text: widget.code);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Turnier per Einladung öffnen'),
    content: TextField(
      key: const Key('inviteCode'),
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      decoration: const InputDecoration(labelText: 'Einladungscode'),
      onSubmitted: (code) => Navigator.pop(context, code),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      FilledButton(
        key: const Key('joinConfirm'),
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Öffnen'),
      ),
    ],
  );
}

class TournamentCreateScreen extends StatefulWidget {
  const TournamentCreateScreen({super.key});
  @override
  State<TournamentCreateScreen> createState() => _TournamentCreateScreenState();
}

class _TournamentCreateScreenState extends State<TournamentCreateScreen> {
  final _name = TextEditingController();
  TournamentFormat _format = TournamentFormat.singleElimination;
  GameType _game = GameType.x501;
  X01Rules _rules = const X01Rules();
  bool _public = true;
  bool _duo = false;
  int _boards = 2;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bitte einen Namen eingeben.')));
      return;
    }
    setState(() => _busy = true);
    try {
      final t = await context.read<TournamentService>().create(
            context.read<AppUser>(),
            name: _name.text,
            format: _format,
            gameType: _game,
            rules: _rules,
            isPublic: _public,
            boardCount: _boards,
            isDuo: _duo,
          );
      if (!mounted) return;
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => TournamentDetailScreen(id: t.id)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Neues Turnier')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(key: const Key('tournamentName'), controller: _name, decoration: const InputDecoration(labelText: 'Turniername')),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const Key('duoMode'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Duo-Turnier'),
          subtitle: const Text('Zufällige Zweier-Teams mit Gruppenphase und K.-o.'),
          value: _duo,
          onChanged: (value) => setState(() {
            _duo = value;
            if (value) {
              _format = TournamentFormat.groupsKnockout;
              if (!_game.isX01) _game = GameType.x501;
            }
          }),
        ),
        DropdownButtonFormField<TournamentFormat>(
          key: const Key('format'),
          value: _format,
          decoration: const InputDecoration(labelText: 'Turnierform'),
          items: [
            for (final f in TournamentFormat.values.where((f) => f != TournamentFormat.friendly))
              DropdownMenuItem(value: f, child: Text(f.label)),
          ],
          onChanged: _duo ? null : (f) => setState(() => _format = f ?? _format),
        ),
        const SizedBox(height: 16),
        RulesEditor(
          allowTraining: false,
          x01Only: _duo,
          gameType: _game,
          rules: _rules,
          onGameType: (g) => setState(() => _game = g),
          onRules: (r) => setState(() => _rules = r),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Expanded(child: Text('Anzahl Dartboards')),
          IconButton(onPressed: _boards > 1 ? () => setState(() => _boards--) : null, icon: const Icon(Icons.remove)),
          Text('$_boards', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          IconButton(onPressed: _boards < 16 ? () => setState(() => _boards++) : null, icon: const Icon(Icons.add)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Öffentlich (für Zuschauer sichtbar)'),
          value: _public,
          onChanged: (v) => setState(() => _public = v),
        ),
        const SizedBox(height: 12),
        FilledButton(key: const Key('createTournament'), onPressed: _busy ? null : _create, child: const Text('Turnier anlegen')),
      ]),
    );
  }
}

/// Detailansicht eines Turniers.
class TournamentDetailScreen extends StatefulWidget {
  final String id;
  final VoidCallback? onSignIn;
  const TournamentDetailScreen({super.key, required this.id, this.onSignIn});
  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen> {
  Role _role = Role.spectator;
  late final Stream<TournamentRecord?> _stream;

  @override
  void initState() {
    super.initState();
    _stream = context.read<AppRepository>().watchTournament(widget.id);
    _loadRole();
  }

  Future<void> _loadRole() async {
    final repo = context.read<AppRepository>();
    final user = context.read<AppUser>();
    if (user.uid.isEmpty) return;
    try {
      final inT = await repo.memberRole(widget.id, user.uid);
      if (mounted) setState(() => _role = effectiveRole(user.role, inT));
    } catch (_) {
      if (mounted) setState(() => _role = user.role);
    }
  }

  bool _movingToTrash = false;

  Future<void> _moveToTrash(TournamentRecord tournament) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turnier in den Papierkorb verschieben?'),
        content: Text('„${tournament.name}“ verschwindet aus den aktiven Listen. '
            'Spiele und Ergebnisse werden beim Wiederherstellen wieder angezeigt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
          FilledButton(
            key: const Key('confirmTournamentTrash'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('In den Papierkorb'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _movingToTrash) return;
    setState(() => _movingToTrash = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<TournamentService>().moveToTrash(context.read<AppUser>(), tournament);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('„${tournament.name}“ liegt im Papierkorb.')));
      if (nav.canPop()) nav.pop();
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _movingToTrash = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TournamentRecord?>(
      stream: _stream,
      builder: (context, snap) {
        final t = snap.data;
        if (snap.hasError || (snap.connectionState != ConnectionState.waiting && t == null)) {
          return Scaffold(
            appBar: AppBar(
              actions: [
                if (widget.onSignIn != null)
                  TextButton(onPressed: widget.onSignIn, child: const Text('Anmelden')),
              ],
            ),
            body: const Center(child: Text('Turnier nicht verfügbar. Prüfe den Einladungslink und deine Anmeldung.')),
          );
        }
        if (t == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        if (t.trash != null) {
          return Scaffold(appBar: AppBar(), body: const _Hint('Dieses Turnier liegt im Papierkorb.'));
        }
        final showDraw = t.plan != null && (t.published || can(_role, Permission.runDraw));
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            appBar: AppBar(
              title: Text(t.name),
              actions: [
                if (widget.onSignIn != null)
                  TextButton(onPressed: widget.onSignIn, child: const Text('Anmelden')),
                if (context.watch<AppUser>().role == Role.admin)
                  IconButton(
                    tooltip: 'Turnier in den Papierkorb',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _movingToTrash ? null : () => _moveToTrash(t),
                  ),
                if (t.status == TournamentStatus.finished && t.plan?.isComplete == true)
                  TournamentExportButton(tournament: t),
                if (t.isPublic || can(_role, Permission.runDraw)) IconButton(
                  key: const Key('inviteButton'),
                  tooltip: 'Einladung / QR-Code',
                  icon: const Icon(Icons.qr_code_2),
                  onPressed: () => showInvite(context, t),
                ),
              ],
              bottom: const TabBar(isScrollable: true, tabs: [
                Tab(text: 'Übersicht'),
                Tab(text: 'Spielplan'),
                Tab(text: 'Tabelle'),
                Tab(text: 'Spiele'),
              ]),
            ),
            body: TabBarView(children: [
              _Overview(t: t, role: _role, onChanged: _loadRole, onSignIn: widget.onSignIn),
              showDraw ? _Schedule(t: t, role: _role) : const _Hint('Die Auslosung wurde noch nicht veröffentlicht.'),
              showDraw ? _Tables(t: t) : const _Hint('Noch keine Tabelle.'),
              _MatchesTab(t: t, role: _role),
            ]),
          ),
        );
      },
    );
  }
}

Future<void> showInvite(BuildContext context, TournamentRecord t) async {
  if (!t.isPublic) {
    try {
      await context.read<AppRepository>().indexInvite(t);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Der Einladungscode konnte nicht bereitgestellt werden.')),
      );
      return;
    }
  }
  if (!context.mounted) return;
  final link = inviteLink(t);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Turnierlink teilen'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        // Feste Größe: QrImageView nutzt einen LayoutBuilder, der in AlertDialogs
        // keine intrinsischen Maße liefern kann.
        Container(
          width: 244,
          height: 244,
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: QrImageView(data: link, size: 220),
        ),
        const SizedBox(height: 12),
        SelectableText('Code: ${t.inviteCode}',
            key: const Key('inviteCodeText'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 4)),
        const SizedBox(height: 4),
        SelectableText(link, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
        FilledButton.icon(
          icon: const Icon(Icons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Turnierlink kopiert.')));
          },
          label: const Text('Link kopieren'),
        ),
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim))));
}

// ------------------------------------------------------------------ Übersicht

class _Overview extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  final VoidCallback onChanged;
  final VoidCallback? onSignIn;
  const _Overview({required this.t, required this.role, required this.onChanged, this.onSignIn});

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } on VersionConflict {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Das Turnier wurde gleichzeitig geändert – bitte erneut versuchen.')));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<TournamentService>();
    final repo = context.read<AppRepository>();
    final user = context.watch<AppUser>();
    final names = t.plan?.names ?? {for (final p in t.registrations) p.id: p.name};
    final staff = can(role, Permission.runDraw);
    final registered = t.registrations.any((p) => p.id == user.playerId);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.isDuo ? 'Duo · ${t.format.label}' : t.format.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${t.gameType.label}${t.gameType.isX01 ? ' · ${t.rules.label.split('·').last.trim()} · ${t.rules.format.label}' : ''}'),
            const SizedBox(height: 4),
            Text('Status: ${t.status == TournamentStatus.registration && t.duoTeams.isNotEmpty ? 'Duos ausgelost' : statusLabel(t.status)} · ${t.boards.length} Boards',
                style: const TextStyle(color: AppColors.textDim)),
            if (t.plan?.championId != null) ...[
              const SizedBox(height: 8),
              Text('🏆 Sieger: ${names[t.plan!.championId]}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (t.status == TournamentStatus.registration && t.duoTeams.isEmpty && onSignIn != null)
        FilledButton.icon(
          onPressed: onSignIn,
          icon: const Icon(Icons.how_to_reg),
          label: const Text('Zum Teilnehmen anmelden'),
        ),
      if (t.status == TournamentStatus.registration && t.duoTeams.isEmpty && can(role, Permission.joinTournament) && user.playerId != null && !registered)
        FilledButton.icon(
          key: const Key('registerSelf'),
          icon: const Icon(Icons.how_to_reg),
          label: const Text('Teilnehmen'),
          onPressed: () => _run(context, () async {
            final players = await repo.watchPlayers().first;
            final me = players.firstWhere((p) => p.id == user.playerId);
            await svc.join(user, t, me);
          }),
        ),
      if (registered && t.status == TournamentStatus.registration)
        const ListTile(leading: Icon(Icons.check_circle, color: AppColors.accent), title: Text('Du bist angemeldet.')),
      const SizedBox(height: 8),
      _Participants(t: t, role: role),
      const SizedBox(height: 16),
      if (staff) _DrawControls(t: t, role: role, run: (f) => _run(context, f)),
      if (can(role, Permission.manageRoles) || role == Role.director) ...[
        const SizedBox(height: 16),
        _Members(t: t, role: role),
      ],
    ]);
  }
}

class _Participants extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  const _Participants({required this.t, required this.role});

  @override
  Widget build(BuildContext context) {
    final svc = context.read<TournamentService>();
    final user = context.read<AppUser>();
    final manage = can(role, Permission.manageParticipants) &&
        t.status == TournamentStatus.registration && t.duoTeams.isEmpty;
    final list = t.isDuo
        ? t.registrations
        : t.status == TournamentStatus.registration ? t.registrations : (t.plan?.participants ?? t.registrations);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Teilnehmer (${list.length})', style: Theme.of(context).textTheme.titleMedium)),
            if (manage)
              TextButton.icon(
                key: const Key('addParticipant'),
                icon: const Icon(Icons.person_add),
                label: const Text('Hinzufügen'),
                onPressed: () => _add(context, svc, user),
              ),
          ]),
          if (list.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Noch keine Teilnehmer.', style: TextStyle(color: AppColors.textDim))),
          for (final p in list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.accentDim,
                  child: Text((t.isDuo ? p.lotNumber : p.seed)?.toString() ?? '–', style: const TextStyle(fontSize: 12))),
              title: Text(p.name),
              trailing: manage
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: t.isDuo ? 'Losnummer eintragen' : 'Setzplatz',
                        icon: const Icon(Icons.format_list_numbered),
                        onPressed: () async {
                          final value = t.isDuo ? await _askLot(context, p) : await _askSeed(context, p);
                          if (value == null || !context.mounted) return;
                          try {
                            final number = value == 0 ? null : value;
                            if (t.isDuo) {
                              await svc.setLotNumber(user, t, p.id, number);
                            } else {
                              await svc.setSeed(user, t, p.id, number);
                            }
                          } catch (error) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$error')),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Entfernen',
                        icon: const Icon(Icons.close),
                        onPressed: () => svc.removeParticipant(user, t, p.id),
                      ),
                    ])
                  : null,
            ),
        ]),
      ),
    );
  }

  Future<void> _add(BuildContext context, TournamentService svc, AppUser user) async {
    final repo = context.read<AppRepository>();
    final players = await repo.watchPlayers().first;
    if (!context.mounted) return;
    final ctrl = TextEditingController();
    final result = await showDialog<Participant>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Teilnehmer hinzufügen'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(key: const Key('participantName'), controller: ctrl, decoration: const InputDecoration(labelText: 'Neuer Spieler (Name)')),
            const SizedBox(height: 12),
            if (players.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(shrinkWrap: true, children: [
                  for (final p in players.where((p) => !t.registrations.any((r) => r.id == p.id)))
                    ListTile(
                        dense: true,
                        title: Text(p.name),
                        onTap: () => Navigator.pop(ctx, Participant(id: p.id, name: p.name))),
                ]),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            key: const Key('participantAdd'),
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final p = await repo.savePlayer(PlayerProfile(id: newId('pl'), name: name));
              if (ctx.mounted) Navigator.pop(ctx, Participant(id: p.id, name: p.name));
            },
            child: const Text('Anlegen'),
          ),
        ],
      ),
    );
    if (result != null) {
      try {
        await svc.addParticipant(user, t, result);
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<int?> _askLot(BuildContext context, Participant player) => showDialog<int>(
    context: context,
    builder: (_) => _LotNumberDialog(player: player),
  );

  Future<int?> _askSeed(BuildContext context, Participant p) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Setzplatz für ${p.name}'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 0), child: const Text('Ungesetzt')),
          for (var i = 1; i <= t.registrations.length; i++)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, i), child: Text('Setzplatz $i')),
        ],
      ),
    );
  }
}

class _LotNumberDialog extends StatefulWidget {
  final Participant player;
  const _LotNumberDialog({required this.player});

  @override
  State<_LotNumberDialog> createState() => _LotNumberDialogState();
}

class _LotNumberDialogState extends State<_LotNumberDialog> {
  late final _number = TextEditingController(text: widget.player.lotNumber?.toString());
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, int.tryParse(_number.text) ?? 0);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Losnummer für ${widget.player.name}'),
    content: Form(
      key: _form,
      child: TextFormField(
        key: const Key('lotNumber'),
        autofocus: true,
        controller: _number,
        decoration: const InputDecoration(labelText: 'Gezogene Nummer'),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onFieldSubmitted: (_) => _save(),
        validator: (text) => text == null || text.isEmpty || (int.tryParse(text) ?? 0) > 0
            ? null : 'Bitte eine positive Zahl eingeben.',
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      if (widget.player.lotNumber != null)
        TextButton(onPressed: () => Navigator.pop(context, 0), child: const Text('Nummer entfernen')),
      FilledButton(key: const Key('saveLotNumber'), onPressed: _save, child: const Text('Speichern')),
    ],
  );
}

class _DrawControls extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  final Future<void> Function(Future<void> Function()) run;
  const _DrawControls({required this.t, required this.role, required this.run});

  @override
  Widget build(BuildContext context) {
    final svc = context.read<TournamentService>();
    final user = context.read<AppUser>();
    final plan = t.plan;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Auslosung', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (t.isDuo && t.duoTeams.isEmpty)
            FilledButton.icon(
              key: const Key('drawDuoTeams'),
              icon: const Icon(Icons.shuffle),
              label: const Text('Duos zufällig losen'),
              onPressed: () => run(() => svc.drawDuoTeams(user, t)),
            ),
          if (t.isDuo && t.duoTeams.isNotEmpty && plan == null) ...[
            const Text('Gezogene Duos'),
            for (final team in t.duoTeams)
              ListTile(
                leading: const Icon(Icons.group),
                title: Text(team.name),
                subtitle: Text(team.members.map((p) => 'Los ${p.lotNumber}').join(' und ')),
                dense: true,
              ),
            Wrap(spacing: 8, children: [
              TextButton(
                onPressed: () => run(() => svc.drawDuoTeams(user, t)),
                child: const Text('Duos neu losen'),
              ),
              TextButton(
                onPressed: () => run(() => svc.resetDuoTeams(user, t)),
                child: const Text('Zurück zur Teilnehmerliste'),
              ),
            ]),
          ],
          if (plan == null && (!t.isDuo || t.duoTeams.isNotEmpty))
            FilledButton.icon(
              key: const Key('drawButton'),
              icon: const Icon(Icons.shuffle),
              label: Text(t.isDuo ? 'Duos bestätigen und Gruppen auslosen' : 'Auslosen'),
              onPressed: !t.isDuo && t.registrations.length < 2
                  ? null
                  : () async {
                      final opts = await _askOptions(context, t);
                      if (opts == null) return;
                      await run(() => svc.draw(user, t, options: opts));
                    },
            ),
          if (plan != null && !t.published) ...[
            Text(t.isDuo
                ? 'Entwurf – zwei Duos antippen, um ihre Gruppenplätze zu tauschen.'
                : 'Entwurf – bitte prüfen. Zwei Spieler antippen, um sie zu tauschen.',
                style: const TextStyle(color: AppColors.warning)),
            const SizedBox(height: 8),
            _DrawPreview(t: t, plan: plan),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                key: const Key('publishButton'),
                icon: const Icon(Icons.publish),
                label: const Text('Veröffentlichen & starten'),
                onPressed: () => run(() => svc.publish(user, t)),
              ),
              OutlinedButton.icon(
                key: const Key('redrawButton'),
                icon: const Icon(Icons.refresh),
                label: Text(t.isDuo ? 'Gruppen neu auslosen' : 'Neu auslosen'),
                onPressed: () => run(() => svc.redraw(user, t)),
              ),
            ]),
          ],
          if (plan != null && t.published) const Text('Die Auslosung ist veröffentlicht.'),
        ]),
      ),
    );
  }

  Future<PlanOptions?> _askOptions(BuildContext context, TournamentRecord t) async {
    var useSeeds = t.registrations.any((p) => p.seed != null);
    var groupSize = 4;
    var advance = 2;
    var swissRounds = 0;
    final n = t.isDuo ? t.duoTeams.length : t.registrations.length;
    return showDialog<PlanOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Auslosung'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (!t.isDuo && (t.format == TournamentFormat.singleElimination ||
                  t.format == TournamentFormat.doubleElimination ||
                  t.format == TournamentFormat.groupsKnockout))
                SwitchListTile(
                  title: const Text('Gesetzte Spieler berücksichtigen'),
                  value: useSeeds,
                  onChanged: (v) => set(() => useSeeds = v),
                ),
              if (t.format == TournamentFormat.groupsKnockout) ...[
                ListTile(
                  title: Text(t.isDuo ? 'Duos je Gruppe' : 'Gruppengröße'),
                  trailing: DropdownButton<int>(
                    value: groupSize,
                    items: [for (var i = 3; i <= 8; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                    onChanged: (v) => set(() => groupSize = v ?? 4),
                  ),
                ),
                ListTile(
                  title: const Text('Qualifikanten je Gruppe'),
                  trailing: DropdownButton<int>(
                    value: advance,
                    items: [for (var i = 1; i <= 4; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                    onChanged: (v) => set(() => advance = v ?? 2),
                  ),
                ),
                Text('→ ${((n + groupSize - 1) ~/ groupSize)} Gruppen', style: const TextStyle(color: AppColors.textDim)),
              ],
              if (t.format == TournamentFormat.swiss)
                ListTile(
                  title: const Text('Runden'),
                  trailing: DropdownButton<int>(
                    value: swissRounds,
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('Automatisch')),
                      for (var i = 1; i <= 10; i++) DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) => set(() => swissRounds = v ?? 0),
                  ),
                ),
              if (t.format == TournamentFormat.singleElimination || t.format == TournamentFormat.doubleElimination)
                Text(
                    n.isOdd || (n & (n - 1)) != 0 ? 'Freilose werden automatisch vergeben.' : 'Keine Freilose nötig.',
                    style: const TextStyle(color: AppColors.textDim)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              key: const Key('drawConfirm'),
              onPressed: () => Navigator.pop(
                  ctx,
                  PlanOptions(
                    useSeeds: useSeeds,
                    groupSize: groupSize,
                    advancePerGroup: advance,
                    swissRounds: swissRounds == 0 ? null : swissRounds,
                  )),
              child: Text(t.isDuo ? 'Gruppen auslosen' : 'Auslosen'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vorschau der Auslosung mit manueller Anpassung (Tippen, Tippen = Tauschen).
class _DrawPreview extends StatefulWidget {
  final TournamentRecord t;
  final TournamentPlan plan;
  const _DrawPreview({required this.t, required this.plan});
  @override
  State<_DrawPreview> createState() => _DrawPreviewState();
}

class _DrawPreviewState extends State<_DrawPreview> {
  int? _selPos;
  String? _selId;

  Future<void> _swapPos(int a, int b) async {
    final svc = context.read<TournamentService>();
    try {
      await svc.savePlanEdit(context.read<AppUser>(), widget.t, (p) => p.swapPositions(a, b));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _swapIds(String a, String b) async {
    final svc = context.read<TournamentService>();
    try {
      await svc.savePlanEdit(context.read<AppUser>(), widget.t, (p) => p.swapGroupMembers(a, b));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final names = plan.names;
    if (plan.format == TournamentFormat.singleElimination || plan.format == TournamentFormat.doubleElimination) {
      return Column(children: [
        for (var i = 0; i < plan.positions.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              for (var s = 0; s < 2; s++) ...[
                if (s == 1) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('vs')),
                Expanded(
                  child: ChoiceChip(
                    key: Key('pos-${i + s}'),
                    label: SizedBox(
                        width: double.infinity,
                        child: Text(plan.positions[i + s] == null ? 'Freilos' : names[plan.positions[i + s]]!,
                            overflow: TextOverflow.ellipsis)),
                    selected: _selPos == i + s,
                    onSelected: plan.positions[i + s] == null && _selPos == null
                        ? null
                        : (_) {
                            if (_selPos == null) {
                              setState(() => _selPos = i + s);
                            } else {
                              final a = _selPos!;
                              setState(() => _selPos = null);
                              if (a != i + s) _swapPos(a, i + s);
                            }
                          },
                  ),
                ),
              ],
            ]),
          ),
      ]);
    }
    if (plan.format == TournamentFormat.groupsKnockout) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final g in plan.groups) ...[
          Text('Gruppe ${g.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Wrap(spacing: 6, children: [
            for (final id in g.playerIds)
              ChoiceChip(
                label: Text(names[id] ?? id),
                selected: _selId == id,
                onSelected: (_) {
                  if (_selId == null) {
                    setState(() => _selId = id);
                  } else {
                    final a = _selId!;
                    setState(() => _selId = null);
                    if (a != id) _swapIds(a, id);
                  }
                },
              ),
          ]),
          const SizedBox(height: 8),
        ],
      ]);
    }
    final rounds = plan.fixtures.map((f) => f.round).toSet().toList()..sort();
    return Text(
        '${plan.fixtures.length} Begegnungen in ${rounds.length} Runden${plan.format == TournamentFormat.swiss ? ' (Runde 1 gepaart, weitere automatisch)' : ''}.');
  }
}

class _Members extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  const _Members({required this.t, required this.role});
  @override
  Widget build(BuildContext context) {
    final repo = context.read<AppRepository>();
    return StreamBuilder<List<TournamentMember>>(
      stream: repo.watchMembers(t.id),
      builder: (context, snap) {
        final members = snap.data ?? const [];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Rollen im Turnier', style: Theme.of(context).textTheme.titleMedium),
              for (final m in members)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.name),
                  trailing: DropdownButton<Role>(
                    value: m.role,
                    items: [
                      for (final r in [Role.player, Role.scorer, Role.director])
                        if (canGrantRole(role, r) || r == m.role)
                          DropdownMenuItem(value: r, child: Text(r == Role.player ? 'Spieler' : r == Role.scorer ? 'Schreiber' : 'Turnierleitung')),
                    ],
                    onChanged: (r) {
                      if (r != null && canGrantRole(role, r) && canGrantRole(role, m.role)) {
                        repo.setMember(t.id, TournamentMember(m.uid, m.name, r));
                      }
                    },
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }
}

// ----------------------------------------------------------------- Spielplan

class _Schedule extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  const _Schedule({required this.t, required this.role});

  @override
  Widget build(BuildContext context) {
    final plan = t.plan!;
    final user = context.watch<AppUser>();
    final repo = context.read<AppRepository>();
    return StreamBuilder<List<MatchRecord>>(
      stream: repo.watchMatches(tournamentId: t.id),
      builder: (context, snap) {
        final matches = snap.data ?? const <MatchRecord>[];
        final running = {for (final m in matches.where((m) => m.status != MatchStatus.confirmed)) if (m.planMatchId != null) m.planMatchId!: m};
        final canStart = t.published && can(role, Permission.startMatch);

        Future<void> open(String planMatchId) async {
          final pm = plan.playable.where((p) => p.id == planMatchId).firstOrNull;
          final live = running[planMatchId];
          if (live != null) {
            Navigator.push(context, MaterialPageRoute(builder: (_) =>
              can(role, Permission.enterScores)
                  ? ScoringScreen(matchId: live.id)
                  : LiveMatchScreen(matchId: live.id)));
            return;
          }
          if (pm == null || !canStart) return;
          await _startDialog(context, t, pm);
        }

        return ListView(padding: const EdgeInsets.all(16), children: [
          if (plan.bracket != null)
            BracketView(
              bracket: plan.bracket!,
              names: plan.names,
              highlightPlayerId: plan.entryForPlayer(user.playerId),
              runningMatchIds: running.keys.toSet(),
              onTapMatch: (m) => open(m.id),
            ),
          if (plan.bracket == null || plan.format == TournamentFormat.groupsKnockout) ...[
            if (plan.bracket != null) const Divider(height: 32),
            _FixtureList(plan: plan, running: running, onTap: canStart || running.isNotEmpty ? open : null, me: plan.entryForPlayer(user.playerId)),
          ],
        ]);
      },
    );
  }

  Future<void> _startDialog(BuildContext context, TournamentRecord t, PlanMatch pm) async {
    final svc = context.read<TournamentService>();
    final user = context.read<AppUser>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final suggestions = await svc.suggestAssignments(t);
    String? boardId = suggestions.where((a) => a.matchId == pm.id).firstOrNull?.boardId ??
        t.boards.where((b) => b.currentMatchId == null).firstOrNull?.id;
    var starter = 0;
    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(pm.label),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.plan!.names[pm.aId]}  –  ${t.plan!.names[pm.bId]}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: boardId,
              decoration: const InputDecoration(labelText: 'Dartboard'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Kein Board')),
                for (final b in t.boards)
                  DropdownMenuItem(
                      value: b.id,
                      enabled: b.currentMatchId == null,
                      child: Text('${b.name}${b.currentMatchId != null ? ' (belegt)' : ''}')),
              ],
              onChanged: (v) => set(() => boardId = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: starter,
              decoration: const InputDecoration(labelText: 'Anwurf'),
              items: [
                DropdownMenuItem(value: 0, child: Text(t.plan!.names[pm.aId] ?? '')),
                DropdownMenuItem(value: 1, child: Text(t.plan!.names[pm.bId] ?? '')),
              ],
              onChanged: (v) => set(() => starter = v ?? 0),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(key: const Key('startConfirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Starten')),
          ],
        ),
      ),
    );
    if (go != true) return;
    try {
      final m = await svc.startMatch(user, t, pm, boardId: boardId, firstStarter: starter);
      nav.push(MaterialPageRoute(builder: (_) => ScoringScreen(matchId: m.id)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _FixtureList extends StatelessWidget {
  final TournamentPlan plan;
  final Map<String, MatchRecord> running;
  final void Function(String planMatchId)? onTap;
  final String? me;
  const _FixtureList({required this.plan, required this.running, required this.onTap, required this.me});

  @override
  Widget build(BuildContext context) {
    final rounds = plan.fixtures.map((f) => f.round).toSet().toList()..sort();
    final playableIds = {for (final p in plan.playable) p.id};
    final names = plan.names;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in rounds) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Text('Runde $r', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final f in plan.fixtures.where((f) => f.round == r))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Card(
              child: ListTile(
                key: Key('fixture-${f.id}'),
                dense: true,
                leading: Icon(
                    f.isPlayed
                        ? Icons.check_circle
                        : running.containsKey(f.id)
                            ? Icons.fiber_manual_record
                            : Icons.schedule,
                    color: f.isPlayed ? AppColors.accent : running.containsKey(f.id) ? AppColors.danger : AppColors.textDim),
                title: Text('${f.group != null ? '[${plan.groups[f.group!].name}] ' : ''}${names[f.homeId]}  –  ${names[f.awayId]}',
                    style: TextStyle(fontWeight: (f.homeId == me || f.awayId == me) ? FontWeight.w800 : FontWeight.w500)),
                trailing: f.isPlayed
                    ? Text('${f.homeLegs ?? '-'} : ${f.awayLegs ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))
                    : null,
                onTap: onTap != null && !f.isPlayed && (playableIds.contains(f.id) || running.containsKey(f.id))
                    ? () => onTap!(f.id)
                    : null,
              ),
            ),
          ),
      ],
    ]);
  }
}

// ------------------------------------------------------------------- Tabelle

class _Tables extends StatelessWidget {
  final TournamentRecord t;
  const _Tables({required this.t});
  @override
  Widget build(BuildContext context) {
    final plan = t.plan!;
    final me = plan.entryForPlayer(context.watch<AppUser>().playerId);
    final tables = plan.tables();
    if (tables.isEmpty) {
      return const _Hint('Bei K.-o.-Turnieren gibt es keine Tabelle – siehe Spielplan.');
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (var i = 0; i < tables.length; i++) ...[
        Text(plan.format == TournamentFormat.groupsKnockout ? 'Gruppe ${plan.groups[i].name}' : 'Rangliste',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: StandingsTable(
            rows: tables[i],
            names: plan.names,
            highlightPlayerId: me,
            showBuchholz: plan.format == TournamentFormat.swiss,
            qualifyCount: plan.format == TournamentFormat.groupsKnockout ? plan.options.advancePerGroup : null,
          ),
        ),
        const SizedBox(height: 16),
      ],
    ]);
  }
}

// -------------------------------------------------------------------- Spiele

class _MatchesTab extends StatelessWidget {
  final TournamentRecord t;
  final Role role;
  const _MatchesTab({required this.t, required this.role});
  @override
  Widget build(BuildContext context) {
    final repo = context.read<AppRepository>();
    final tablets = context.read<AppServices>().tablets;
    return StreamBuilder<List<MatchRecord>>(
      stream: repo.watchMatches(tournamentId: t.id),
      builder: (context, snap) {
        final list = snap.data ?? const <MatchRecord>[];
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (t.boards.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Dartboards', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  for (final b in t.boards)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.circle, size: 12, color: b.currentMatchId == null ? AppColors.accent : AppColors.danger),
                      title: Text(b.name),
                      subtitle: Text(b.currentMatchId == null
                          ? 'frei'
                          : list.where((m) => m.id == b.currentMatchId).map((m) => m.players.map((p) => p.name).join(' – ')).firstOrNull ?? 'belegt'),
                    ),
                ]),
              ),
            ),
          if (tablets != null && can(role, Permission.manageBoards))
            BoardTabletControls(tablets: tablets, tournament: t, appUri: _appUri()),
          const SizedBox(height: 12),
          if (list.isEmpty) const _Hint('Noch keine Begegnung gestartet.'),
          for (final m in list)
            MatchTile(
              match: m,
              onCorrect: can(role, Permission.correctResult) &&
                      m.status == MatchStatus.confirmed && m.players.length == 2
                  ? () => showResultCorrection(context, m)
                  : null,
            ),
        ]);
      },
    );
  }
}
