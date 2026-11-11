import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/session/session_cubit.dart';
import 'theme.dart';

/// Navigation around the signed-in sections: a rail on a wide window, a bar
/// at the bottom on a narrow one. Carries the "Log out" button and the
/// warning before the idle lock.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// From this width up the navigation is a rail on the left.
  static const double wideFrom = 720;

  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideFrom;
    final logout = context.read<SessionCubit>().logout;
    if (!wide) {
      return Scaffold(
        body: Column(
          children: [
            const IdleLockWarning(),
            Expanded(child: navigationShell),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) {
            if (index == 2) {
              logout();
            } else {
              _select(index);
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.lock_outline),
              selectedIcon: Icon(Icons.lock),
              label: 'Vault',
            ),
            NavigationDestination(
              icon: Icon(Icons.casino_outlined),
              selectedIcon: Icon(Icons.casino),
              label: 'Generator',
            ),
            NavigationDestination(
              key: Key('shell-logout'),
              icon: Icon(Icons.logout),
              label: 'Log out',
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          ColoredBox(
            color: LeopardColors.surface,
            child: Column(
              children: [
                Expanded(
                  child: NavigationRail(
                    selectedIndex: navigationShell.currentIndex,
                    onDestinationSelected: _select,
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Icon(
                        Icons.lock_outline,
                        color: LeopardColors.brass,
                      ),
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.lock_outline),
                        selectedIcon: Icon(Icons.lock),
                        label: Text('Vault'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.casino_outlined),
                        selectedIcon: Icon(Icons.casino),
                        label: Text('Generator'),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('shell-logout'),
                  tooltip: 'Log out',
                  icon: const Icon(Icons.logout),
                  onPressed: logout,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                const IdleLockWarning(),
                Expanded(child: navigationShell),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A strip that appears during the last minute before the idle lock. Any
/// key press or pointer movement dismisses it, because that is activity.
class IdleLockWarning extends StatelessWidget {
  const IdleLockWarning({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SessionCubit, SessionState>(
        buildWhen: (before, after) =>
            before.locksInSeconds != after.locksInSeconds,
        builder: (context, state) {
          final seconds = state.locksInSeconds;
          if (seconds == null) {
            return const SizedBox.shrink();
          }
          return Material(
            key: const Key('idle-warning'),
            color: LeopardColors.surfaceHigh,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.lock_clock_outlined,
                      size: 18,
                      color: LeopardColors.warning,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'No activity: locking in $seconds s',
                        style: const TextStyle(color: LeopardColors.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
