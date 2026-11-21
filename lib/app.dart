import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bootstrap.dart';
import 'data/auth_service.dart';
import 'core/auth/permissions.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/services.dart';
import 'ui/screens/home_shell.dart';
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
        return HomeShell(key: ValueKey(user.uid));
      },
    );
  }
}
