import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/hrv_trend.dart';
import '../../../shared/hrv/readiness.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';

/// Letture morning su una finestra in giorni. Parametrico così la home card può
/// usare una finestra economica e la sezione dedicata una più ampia (per il
/// baseline cronico 60gg e il trend).
final morningReadingsProvider =
    FutureProvider.autoDispose.family<List<Session>, int>((ref, days) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final since = DateTime.now().subtract(Duration(days: days));
  return repo.listSessions(
    tag: SessionTag.morning,
    since: since,
    limit: days * 2,
  );
});

/// Readiness completa calcolata sulla finestra estesa (90gg) per la sezione.
final readinessSectionProvider =
    FutureProvider.autoDispose<Readiness>((ref) async {
  final sessions = await ref.watch(morningReadingsProvider(90).future);
  return ReadinessCalculator.fromHistory(sessions);
});

/// Serie trend (lnRMSSD + media mobile 7gg) per il grafico della sezione.
final readinessTrendProvider =
    FutureProvider.autoDispose<List<ReadinessTrendPoint>>((ref) async {
  final sessions = await ref.watch(morningReadingsProvider(90).future);
  return ReadinessCalculator.buildTrend(sessions);
});

/// Stato HRV generale/cronico (livello + direzione su settimane + stabilità)
/// per la card "Stato generale HRV" in home. Riusa [morningReadingsProvider]
/// (90gg): di conseguenza si auto-aggiorna quando il check-in lo invalida.
final hrvGeneralStatusProvider =
    FutureProvider.autoDispose<HrvGeneralStatus>((ref) async {
  final sessions = await ref.watch(morningReadingsProvider(90).future);
  return HrvTrendCalculator.fromMornings(sessions);
});
