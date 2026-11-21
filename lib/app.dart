import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bootstrap.dart';
import 'data/auth_service.dart';
import 'core/auth/permissions.dart';
import 'data/models.dart';
import 'data/board_tablets.dart';
import 'data/repository.dart';
import 'data/services.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/board_tablet_screen.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/live_screen.dart';
import 'ui/screens/tournament_screens.dart';
import 'ui/widgets/board_call.dart';
import 'ui/theme.dart';

class DartsApp extends StatefulWidget {
  final AppServices services;
  const DartsApp({super.key, required this.services});

  @override
  State<DartsApp> createState() => _DartsAppState();
}

class _DartsAppState extends State<DartsApp> {
  final _navigator = GlobalKey<NavigatorState>();
  static const _signedOut = AppUser(uid: '', displayName: '', role: Role.spectator);

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        Provider<AppRepository>.value(value: services.repo),
        Provider<AuthService>.value(value: services.auth),
        Provider<TournamentService>.value(value: services.tournaments),
      ],
      child: MaterialApp(
        title: 'Darts Tournament Manager Pro',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Der angemeldete Benutzer wird oberhalb des Navigators bereitgestellt,
        // damit auch per Navigator.push geöffnete Seiten ihn lesen können.
        builder: (context, child) => StreamBuilder<AppUser?>(
          stream: services.auth.userStream,
          initialData: services.auth.currentUser,
          builder: (context, snap) {
            final user = snap.data;
            final playerId = user?.playerId;
            return Provider<AppUser>.value(
              value: user ?? _signedOut,
              child: Stack(
                children: [
                  child!,
                  if (playerId != null && user!.role != Role.spectator)
                    BoardCall(
                      key: ValueKey(user.uid),
                      repo: services.repo,
                      playerId: playerId,
                      openMatch: (id) => _navigator.currentState?.push(
                        MaterialPageRoute<void>(builder: (_) => LiveMatchScreen(matchId: id)),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        home: const AuthGate(),
      ),
    );
  }
}

/// Zeigt Anmeldung oder Hauptoberfläche je nach Anmeldestatus.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _showLogin = false;

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthService>();
    return StreamBuilder<AppUser?>(
      stream: auth.userStream,
      initialData: auth.currentUser,
      builder: (context, snap) {
        final user = snap.data;
        final link = kIsWeb ? Uri.base.queryParameters : const <String, String>{};
        final boardTournament = link['tablet'];
        final boardId = link['board'];
        final boardIndex = int.tryParse(link['slot'] ?? '');
        final code = link['pair'];
        if (context.read<AppServices>().tablets != null &&
            boardTournament != null && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(boardTournament) &&
            boardId != null && RegExp(r'^b[1-9][0-9]*$').hasMatch(boardId) &&
            boardIndex != null && boardIndex >= 0 && boardIndex < 16 &&
            code != null && RegExp(r'^[0-9a-v]{20}$').hasMatch(code)) {
          return BoardTabletScreen(
            tablet: BoardTablet(boardTournament, boardId, boardIndex, code: code),
          );
        }
        final tournamentId = link['tournament'];
        if (user == null) {
          if (!_showLogin && context.read<AppRepository>().isRemote &&
              tournamentId != null && tournamentId.isNotEmpty &&
              !tournamentId.contains('/') && !link.containsKey('invite')) {
            return TournamentDetailScreen(
              id: tournamentId,
              onSignIn: () => setState(() => _showLogin = true),
            );
          }
          return const LoginScreen();
        }
        if (user.role == Role.spectator && link.containsKey('invite')) {
          return const LoginScreen();
        }
        final tablets = context.read<AppServices>().tablets;
        if (tablets != null && user.role == Role.spectator && link.isEmpty) {
          return _GuestHome(key: ValueKey(user.uid), tablets: tablets, uid: user.uid);
        }
        return HomeShell(key: ValueKey(user.uid));
      },
    );
  }
}

class _GuestHome extends StatefulWidget {
  final BoardTablets tablets;
  final String uid;
  const _GuestHome({super.key, required this.tablets, required this.uid});

  @override
  State<_GuestHome> createState() => _GuestHomeState();
}

class _GuestHomeState extends State<_GuestHome> {
  late final _device = widget.tablets.watchDevice(widget.uid);

  @override
  Widget build(BuildContext context) => StreamBuilder<BoardTablet?>(
    stream: _device,
    builder: (context, snapshot) {
      final station = snapshot.data;
      return station == null
          ? HomeShell(key: ValueKey(widget.uid))
          : BoardTabletScreen(tablet: station);
    },
  );
}
