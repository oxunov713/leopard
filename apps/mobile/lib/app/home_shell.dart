import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// Bottom navigation around the four main sections.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: navigationShell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: navigationShell.currentIndex,
      onDestinationSelected: (index) => navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      ),
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
          icon: LeopardIcon(LeopardIcons.health),
          label: 'Health',
        ),
        NavigationDestination(
          icon: Icon(Icons.shield_outlined),
          selectedIcon: Icon(Icons.shield),
          label: 'Security',
        ),
      ],
    ),
  );
}
