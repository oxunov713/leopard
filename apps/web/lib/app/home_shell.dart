import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../core/session/session_cubit.dart';
import '../core/widgets/ui_parts.dart';
import '../features/vault/presentation/vault_cubit.dart';

/// Navigation around the signed-in sections.
///
/// From [HomeBreakpoints.sidebar] on a full sidebar (type filters, generator,
/// the idle countdown and "Lock now"); from [HomeBreakpoints.rail] on a
/// narrow icon strip; below that a bar at the bottom. Carries the warning
/// before the idle lock where there is no sidebar to show it.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final lock = context.read<SessionCubit>().logout;
    if (width >= HomeBreakpoints.sidebar) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(navigationShell: navigationShell, onLock: lock),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }
    if (width >= HomeBreakpoints.rail) {
      return Scaffold(
        body: Row(
          children: [
            _Rail(
              selectedIndex: navigationShell.currentIndex,
              onSelect: _select,
              onLock: lock,
            ),
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
    return Scaffold(
      body: Column(
        children: [
          const SafeArea(bottom: false, child: IdleLockWarning()),
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          if (index == 2) {
            lock();
          } else {
            _select(index);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: LeopardIcon(LeopardIcons.vault),
            label: 'Vault',
          ),
          NavigationDestination(
            icon: LeopardIcon(LeopardIcons.generator),
            label: 'Generator',
          ),
          NavigationDestination(
            key: Key('shell-logout'),
            icon: LeopardIcon(LeopardIcons.lock),
            label: 'Lock',
          ),
        ],
      ),
    );
  }
}

/// "4:12" for 252 seconds.
String formatCountdown(int seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.navigationShell, required this.onLock});

  final StatefulNavigationShell navigationShell;
  final VoidCallback onLock;

  static const List<(LeopardItemType?, String)> _filters = [
    (null, 'All items'),
    (LeopardItemType.login, 'Logins'),
    (LeopardItemType.card, 'Cards'),
    (LeopardItemType.wifi, 'Wi-Fi'),
    (LeopardItemType.apiKey, 'API keys'),
    (LeopardItemType.sshKey, 'SSH keys'),
    (LeopardItemType.secureNote, 'Notes'),
  ];

  @override
  Widget build(BuildContext context) {
    final vault = context.read<VaultCubit>();
    final inVault = navigationShell.currentIndex == 0;
    return Container(
      width: 240,
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
      decoration: const BoxDecoration(
        color: LeopardColors.sidebar,
        border: Border(right: BorderSide(color: LeopardColors.surfaceHigh)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
            child: Row(
              children: [
                const LeopardMark(size: 26),
                const SizedBox(width: 10),
                Text('Leopard', style: headingStyle(17)),
              ],
            ),
          ),
          BlocBuilder<VaultCubit, VaultState>(
            buildWhen: (before, after) =>
                before.entries != after.entries ||
                before.typeFilter != after.typeFilter,
            builder: (context, state) => Column(
              children: [
                for (final (type, label) in _filters)
                  _SidebarItem(
                    key: Key(
                      type == null ? 'filter-all' : 'filter-${type.typeName}',
                    ),
                    label: label,
                    dot: type == null
                        ? LeopardColors.primary
                        : LeopardTypeTint.of(type).foreground,
                    count: type == null
                        ? state.entries.length
                        : state.entries
                              .where((e) => e.item.type == type.typeName)
                              .length,
                    selected: inVault && state.typeFilter == type?.typeName,
                    onTap: () {
                      vault.setTypeFilter(type?.typeName);
                      navigationShell.goBranch(0);
                    },
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 12),
            child: Divider(),
          ),
          _SidebarItem(
            key: const Key('nav-generator'),
            label: 'Generator',
            icon: LeopardIcons.generator,
            selected: navigationShell.currentIndex == 1,
            onTap: () => navigationShell.goBranch(
              1,
              initialLocation: navigationShell.currentIndex == 1,
            ),
          ),
          const Spacer(),
          _LockCard(onLock: onLock),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
    this.icon,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;
  final LeopardIconData? icon;
  final int? count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: selected ? LeopardColors.surfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: LeopardColors.surfaceHigh.withValues(alpha: 0.6),
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                if (dot != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: dot,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                if (icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: LeopardIcon(
                      icon!,
                      size: 18,
                      color: selected
                          ? LeopardColors.text
                          : LeopardColors.textSoft,
                    ),
                  ),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: selected
                          ? LeopardColors.text
                          : LeopardColors.textSoft,
                    ),
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 12,
                      color: LeopardColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// "Locks after 5:00 idle", which turns into a countdown in the last minute
/// (that is all the session reports), and "Lock now".
class _LockCard extends StatelessWidget {
  const _LockCard({required this.onLock});

  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final idleLimit = context.read<SessionCubit>().idleLimit;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LeopardColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BlocBuilder<SessionCubit, SessionState>(
            buildWhen: (before, after) =>
                before.locksInSeconds != after.locksInSeconds,
            builder: (context, state) {
              final seconds = state.locksInSeconds;
              const base = TextStyle(
                fontSize: 12,
                color: LeopardColors.textMuted,
              );
              if (seconds == null) {
                return Text(
                  'Locks after ${formatCountdown(idleLimit.inSeconds)} idle',
                  style: base,
                );
              }
              return Text.rich(
                key: const Key('idle-warning'),
                TextSpan(
                  style: base,
                  children: [
                    const TextSpan(text: 'Locks in '),
                    TextSpan(
                      text: formatCountdown(seconds),
                      style: const TextStyle(
                        color: LeopardColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: ' if idle'),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            key: const Key('shell-logout'),
            onPressed: onLock,
            style: TextButton.styleFrom(
              backgroundColor: LeopardColors.surfaceHigh,
              foregroundColor: LeopardColors.text,
              minimumSize: const Size.fromHeight(36),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            icon: const LeopardIcon(LeopardIcons.lock, size: 16),
            label: const Text('Lock now'),
          ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.selectedIndex,
    required this.onSelect,
    required this.onLock,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) => Container(
    width: 72,
    padding: const EdgeInsets.symmetric(vertical: 20),
    decoration: const BoxDecoration(
      color: LeopardColors.sidebar,
      border: Border(right: BorderSide(color: LeopardColors.surfaceHigh)),
    ),
    child: Column(
      children: [
        const LeopardMark(size: 28),
        const SizedBox(height: 24),
        _RailButton(
          icon: LeopardIcons.vault,
          label: 'Vault',
          selected: selectedIndex == 0,
          onTap: () => onSelect(0),
        ),
        const SizedBox(height: 6),
        _RailButton(
          icon: LeopardIcons.generator,
          label: 'Generator',
          selected: selectedIndex == 1,
          onTap: () => onSelect(1),
        ),
        const Spacer(),
        _RailButton(
          key: const Key('shell-logout'),
          icon: LeopardIcons.lock,
          label: 'Lock now',
          selected: false,
          onTap: onLock,
        ),
      ],
    ),
  );
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final LeopardIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Material(
      color: selected ? LeopardColors.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: LeopardColors.surfaceHigh,
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: LeopardIcon(
              icon,
              size: 20,
              color: selected ? LeopardColors.primary : LeopardColors.textMuted,
            ),
          ),
        ),
      ),
    ),
  );
}

/// A strip that appears during the last minute before the idle lock, where
/// the sidebar's countdown is not shown. Any key press or pointer movement
/// dismisses it, because that is activity.
class IdleLockWarning extends StatelessWidget {
  const IdleLockWarning({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    buildWhen: (before, after) => before.locksInSeconds != after.locksInSeconds,
    builder: (context, state) {
      final seconds = state.locksInSeconds;
      if (seconds == null) {
        return const SizedBox.shrink();
      }
      return Material(
        key: const Key('idle-warning'),
        color: LeopardColors.surfaceHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const LeopardIcon(
                LeopardIcons.clock,
                size: 18,
                color: LeopardColors.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'No activity: locking in $seconds s',
                  style: const TextStyle(color: LeopardColors.primary),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
