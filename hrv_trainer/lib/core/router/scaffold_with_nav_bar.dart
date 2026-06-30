import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Shell con bottom nav a 4 tab (Home · Sessione · Piano · Storico).
/// Renderizza il branch attivo ([StatefulNavigationShell]) e la
/// [NavigationBar] persistente. Il Profilo è uscito dalla barra: si raggiunge
/// con l'icona impostazioni in alto a destra (route `/settings` a sé). I flussi
/// immersivi (sessione, pacer, check-in, assessment) NON passano da qui: sono
/// route sul navigator root e coprono la barra.
class ScaffoldWithNavBar extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const ScaffoldWithNavBar({super.key, required this.navigationShell});

  void _onTap(int index) {
    // Tap sulla tab già attiva → torna alla radice del suo branch.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _onTap,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart_rounded),
            label: 'Sessione',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month_rounded),
            label: 'Piano',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: 'Storico',
          ),
        ],
      ),
    );
  }
}
