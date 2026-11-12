import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/session/session_cubit.dart';
import '../features/emergency_login/presentation/emergency_login_cubit.dart';
import '../features/emergency_login/presentation/emergency_login_page.dart';
import '../features/generator/presentation/generator_cubit.dart';
import '../features/generator/presentation/generator_page.dart';
import '../features/qr_login/presentation/login_page.dart';
import '../features/qr_login/presentation/qr_login_cubit.dart';
import '../features/vault/presentation/item_detail_page.dart';
import '../features/vault/presentation/item_edit_page.dart';
import '../features/vault/presentation/vault_list_page.dart';
import 'dependencies.dart';
import 'home_shell.dart';

/// Where the app must be for a given session state, or `null` to stay.
///
/// Everything under `/login` is public: the QR code, the emergency login and
/// the generator, which needs no vault. Every other route shows vault
/// content and is reachable only while signed in.
String? redirectFor(SessionStatus status, String location) {
  final public = location == '/login' || location.startsWith('/login/');
  switch (status) {
    case SessionStatus.signedOut:
      return public ? null : '/login';
    case SessionStatus.unlocked:
      return (public || location == '/') ? '/vault' : null;
  }
}

/// Re-runs the router's redirect whenever the session state changes.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(SessionCubit cubit) {
    _status = cubit.state.status;
    _subscription = cubit.stream.listen((state) {
      if (state.status != _status) {
        _status = state.status;
        notifyListeners();
      }
    });
  }

  late SessionStatus _status;
  late final StreamSubscription<SessionState> _subscription;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

GoRouter buildRouter({
  required SessionCubit session,
  required AppDependencies dependencies,
}) {
  final refresh = _SessionListenable(session);
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refresh,
    redirect: (context, state) =>
        redirectFor(session.state.status, state.matchedLocation),
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/login'),
      // The three public pages are siblings, not nested: leaving the QR page
      // disposes its cubit, which stops the polling and wipes the ephemeral
      // key.
      GoRoute(
        path: '/login',
        builder: (context, state) => BlocProvider(
          create: (_) => QrLoginCubit(
            dependencies.qrLoginRepository,
            now: dependencies.now,
          )..start(),
          child: const LoginPage(),
        ),
      ),
      GoRoute(
        path: '/login/emergency',
        builder: (context, state) => BlocProvider(
          create: (_) =>
              EmergencyLoginCubit(dependencies.emergencyLoginRepository),
          child: const EmergencyLoginPage(),
        ),
      ),
      GoRoute(
        path: '/login/generator',
        builder: (context, state) => BlocProvider(
          create: (_) => GeneratorCubit(),
          child: const GeneratorPage(canSave: false),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/vault',
                builder: (context, state) => const VaultListPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/generator',
                builder: (context, state) => BlocProvider(
                  create: (_) => GeneratorCubit(),
                  child: const GeneratorPage(),
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/vault/item/:id',
        builder: (context, state) =>
            ItemDetailPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/vault/edit/:id',
        builder: (context, state) =>
            ItemEditPage.edit(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/vault/new/:type',
        builder: (context, state) =>
            ItemEditPage.create(type: state.pathParameters['type']!),
      ),
    ],
  );
}
