import 'package:go_router/go_router.dart';

import '../../features/assessment/assessment_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/history/session_detail_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/hrv_dashboard/hrv_dashboard_screen.dart';
import '../../features/pacer/pacer_screen.dart';
import '../../features/readiness/morning_checkin_screen.dart';
import '../../features/readiness/readiness_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/training/training_screen.dart';
import '../../shared/hrv/session_models.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
    GoRoute(path: '/pacer', builder: (_, _) => const PacerScreen()),
    GoRoute(
      path: '/assessment',
      builder: (_, _) => const AssessmentScreen(),
    ),
    GoRoute(
      path: '/training',
      builder: (_, state) {
        final tagParam = state.uri.queryParameters['tag'];
        final tag = tagParam == null
            ? SessionTag.general
            : SessionTag.values.firstWhere(
                (t) => t.name == tagParam,
                orElse: () => SessionTag.general,
              );
        return TrainingScreen(initialTag: tag);
      },
    ),
    GoRoute(path: '/history', builder: (_, _) => const HistoryScreen()),
    GoRoute(path: '/hrv', builder: (_, _) => const HrvDashboardScreen()),
    GoRoute(path: '/readiness', builder: (_, _) => const ReadinessScreen()),
    GoRoute(
      path: '/readiness/checkin',
      builder: (_, _) => const MorningCheckInScreen(),
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(
      path: '/history/session/:id',
      builder: (_, state) {
        final id = int.parse(state.pathParameters['id']!);
        return SessionDetailScreen(sessionId: id);
      },
    ),
  ],
);
