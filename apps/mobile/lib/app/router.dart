import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/lock/app_lock_cubit.dart';
import '../core/widgets/page_scaffold.dart';
import '../features/generator/presentation/generator_cubit.dart';
import '../features/generator/presentation/generator_page.dart';
import '../features/health/presentation/health_cubit.dart';
import '../features/health/presentation/health_page.dart';
import '../features/qr_approve/presentation/qr_approve_cubit.dart';
import '../features/qr_approve/presentation/qr_approve_page.dart';
import '../features/sessions/presentation/activity_cubit.dart';
import '../features/sessions/presentation/activity_page.dart';
import '../features/sessions/presentation/security_page.dart';
import '../features/sessions/presentation/sessions_cubit.dart';
import '../features/sessions/presentation/sessions_page.dart';
import '../features/setup/presentation/setup_cubit.dart';
import '../features/setup/presentation/setup_page.dart';
import '../features/unlock/presentation/unlock_cubit.dart';
import '../features/unlock/presentation/unlock_page.dart';
import '../features/vault/presentation/item_detail_page.dart';
import '../features/vault/presentation/item_edit_page.dart';
import '../features/vault/presentation/vault_list_page.dart';
import 'dependencies.dart';
import 'home_shell.dart';

/// Where the app must be for a given lock state, or `null` to stay.
///
/// Every route outside `/`, `/setup` and `/unlock` shows vault content and
/// is reachable only while unlocked.
String? redirectFor(AppLockStatus status, String location) {
  switch (status) {
    case AppLockStatus.starting || AppLockStatus.storageError:
      return location == '/' ? null : '/';
    case AppLockStatus.needsSetup:
      return location == '/setup' ? null : '/setup';
    case AppLockStatus.locked:
      return location == '/unlock' ? null : '/unlock';
    case AppLockStatus.unlocked:
      return (location == '/' || location == '/setup' || location == '/unlock')
          ? '/vault'
          : null;
  }
}

/// Re-runs the router's redirect whenever the lock state changes.
class _LockListenable extends ChangeNotifier {
  _LockListenable(AppLockCubit cubit) {
    _subscription = cubit.stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<AppLockState> _subscription;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

GoRouter buildRouter({
  required AppLockCubit lock,
  required AppDependencies dependencies,
}) {
  final refresh = _LockListenable(lock);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) =>
        redirectFor(lock.state.status, state.matchedLocation),
    routes: [
      GoRoute(path: '/', builder: (context, state) => const _StartPage()),
      GoRoute(
        path: '/setup',
        builder: (context, state) => BlocProvider(
          create: (_) => SetupCubit(dependencies.setupRepository),
          child: const SetupPage(),
        ),
      ),
      GoRoute(
        path: '/unlock',
        builder: (context, state) => BlocProvider(
          create: (_) => UnlockCubit(dependencies.unlockRepository),
          child: const UnlockPage(),
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/health',
                builder: (context, state) => BlocProvider(
                  create: (_) => HealthCubit(),
                  child: const HealthPage(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/security',
                builder: (context, state) => const SecurityPage(),
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
        builder: (context, state) {
          final extra = state.extra;
          return ItemEditPage.create(
            type: state.pathParameters['type']!,
            initialPassword: extra is String ? extra : null,
          );
        },
      ),
      GoRoute(
        path: '/scan',
        builder: (context, state) => BlocProvider(
          create: (_) => QrApproveCubit(dependencies.qrLoginRepository),
          child: const QrApprovePage(),
        ),
      ),
      GoRoute(
        path: '/sessions',
        builder: (context, state) => BlocProvider(
          create: (_) => SessionsCubit(dependencies.sessionsRepository)..load(),
          child: const SessionsPage(),
        ),
      ),
      GoRoute(
        path: '/activity',
        builder: (context, state) => BlocProvider(
          create: (_) => ActivityCubit(dependencies.sessionsRepository)..load(),
          child: const ActivityPage(),
        ),
      ),
    ],
  );
}

/// Shown for the moment it takes to read local state, and when secure
/// storage cannot be read at all.
class _StartPage extends StatelessWidget {
  const _StartPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: BlocBuilder<AppLockCubit, AppLockState>(
      builder: (context, state) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LeopardMark(subtitle: state.message),
              if (state.status == AppLockStatus.storageError) ...[
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: context.read<AppLockCubit>().start,
                  child: const Text('TRY AGAIN'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
