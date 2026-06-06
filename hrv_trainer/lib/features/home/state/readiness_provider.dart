import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/readiness.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';

final readinessProvider = FutureProvider.autoDispose<Readiness>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  // 90 giorni così il baseline cronico (fino a 60gg) ha abbastanza storia;
  // il calcolo usa comunque solo le letture morning più recenti.
  final since = DateTime.now().subtract(const Duration(days: 90));
  final sessions = await repo.listSessions(
    tag: SessionTag.morning,
    since: since,
    limit: 120,
  );
  return ReadinessCalculator.fromHistory(sessions);
});

/// `true` se OGGI (giorno solare locale) è già stata salvata almeno una lettura
/// morning. Guida la card-promemoria in cima alla home: appare quando è `false`
/// e sparisce appena il check-in del giorno è completato.
///
/// Confronto per giorno solare (non finestra rolling 24h): una lettura fatta
/// ieri sera NON conta come "fatta oggi". `since` = mezzanotte locale, così la
/// query torna solo le letture odierne; basta `limit: 1` per sapere se esiste.
///
/// autoDispose: si ricalcola rientrando in home (nav o pull-to-refresh) e viene
/// invalidato esplicitamente al salvataggio del check-in
/// (MorningCheckInController.save). Non si auto-aggiorna allo scoccare della
/// mezzanotte ad app aperta: caso di bordo accettabile (stesso limite di
/// [readinessProvider]), risolto al primo rebuild successivo.
final morningCheckInDoneTodayProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final now = DateTime.now();
  final startOfDay = DateTime(now.year, now.month, now.day);
  final todays = await repo.listSessions(
    tag: SessionTag.morning,
    since: startOfDay,
    limit: 1,
  );
  return todays.isNotEmpty;
});
