import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/assessment/assessment_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/history/session_detail_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/hrv_dashboard/hrv_dashboard_screen.dart';
import '../../features/pacer/pacer_screen.dart';
import '../../features/readiness/morning_checkin_screen.dart';
import '../../features/readiness/readiness_screen.dart';
import '../../features/sessione/sessione_hub_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/training/training_screen.dart';
import '../../shared/hrv/session_models.dart';
import 'scaffold_with_nav_bar.dart';

/// Navigator root: i flussi immersivi (sessione/pacer/check-in/assessment) vi
/// si appoggiano via `parentNavigatorKey`, così coprono la bottom nav.
final _rootNavigatorKey = GlobalKey<NavigatorState>();

SessionTag _tagFromQuery(GoRouterState state) {
  final tagParam = state.uri.queryParameters['tag'];
  return tagParam == null
      ? SessionTag.general
      : SessionTag.values.firstWhere(
          (t) => t.name == tagParam,
          orElse: () => SessionTag.general,
        );
}

final appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  routes: [
    // Shell a 4 tab: ogni branch ha il proprio Navigator, così i push restano
    // nella tab e scroll/stato sopravvivono al cambio di tab (indexedStack).
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          ScaffoldWithNavBar(navigationShell: navigationShell),
      branches: [
        // Tab 1 — Home (+ dettagli Andamento HRV e Prontezza).
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const HomeScreen(),
              routes: [
                GoRoute(path: 'hrv', builder: (_, _) => const HrvDashboardScreen()),
                GoRoute(path: 'readiness', builder: (_, _) => const ReadinessScreen()),
              ],
            ),
          ],
        ),
        // Tab 2 — Sessione (hub delle pratiche).
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/sessione', builder: (_, _) => const SessioneHubScreen()),
          ],
        ),
        // Tab 3 — Storico (+ dettaglio sessione).
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/history',
              builder: (_, _) => const HistoryScreen(),
              routes: [
                GoRoute(
                  path: 'session/:id',
                  builder: (_, state) =>
                      SessionDetailScreen(sessionId: int.parse(state.pathParameters['id']!)),
                ),
              ],
            ),
          ],
        ),
        // Tab 4 — Profilo (impostazioni).
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          ],
        ),
      ],
    ),

    // Flussi immersivi: full-screen sul navigator root (nascondono la bottom nav).
    GoRoute(
      path: '/training',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, state) => TrainingScreen(initialTag: _tagFromQuery(state)),
    ),
    GoRoute(
      path: '/pacer',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, _) => const PacerScreen(),
    ),
    GoRoute(
      path: '/assessment',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, _) => const AssessmentScreen(),
    ),
    GoRoute(
      path: '/readiness/checkin',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (_, _) => const MorningCheckInScreen(),
    ),
  ],
);
