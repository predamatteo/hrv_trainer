import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';

/// Finestra cronica (giorni) del cruscotto "Andamento HRV".
const int kHrvDashboardWindowDays = 90;

/// Tutte le sessioni nella finestra cronica, newest-first. È la sorgente unica
/// del cruscotto: trend lnRMSSD, coerenza nel training, RMSSD per tag e impatto
/// abitudini derivano tutti da qui con calcolo in-memory (sono poche centinaia
/// di righe al più in 90 giorni).
///
/// autoDispose: si riallinea ai dati correnti a ogni ingresso nella schermata
/// (l'utente ci arriva dalla card "Stato generale HRV" in home).
final hrvDashboardSessionsProvider =
    FutureProvider.autoDispose<List<Session>>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final since =
      DateTime.now().subtract(const Duration(days: kHrvDashboardWindowDays));
  return repo.listSessions(since: since, limit: 100000);
});
