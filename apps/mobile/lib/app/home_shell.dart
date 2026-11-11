import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
          icon: Icon(Icons.health_and_safety_outlined),
          selectedIcon: Icon(Icons.health_and_safety),
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
