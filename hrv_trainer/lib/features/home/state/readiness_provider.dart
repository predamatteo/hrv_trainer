import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/readiness.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';

final readinessProvider = FutureProvider.autoDispose<Readiness>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final since = DateTime.now().subtract(const Duration(days: 30));
  final sessions = await repo.listSessions(
    tag: SessionTag.morning,
    since: since,
    limit: 30,
  );
  return ReadinessCalculator.fromHistory(sessions);
});
