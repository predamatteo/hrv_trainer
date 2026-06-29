import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';
import '../../history/history_screen.dart' show sessionsListProvider;
import '../../hrv_dashboard/state/hrv_dashboard_providers.dart';

/// Registra una sessione di "Respiro libero" (pacer) così il gesto quotidiano
/// LASCIA TRACCIA: durata + pattern alimentano lo storico e la cronaca cronica
/// `/hrv` come pratica svolta, anche senza orologio.
///
/// Niente metriche HRV: il pacer da solo è un timer, non ingerisce RR — la
/// coerenza/HRV arriva solo dal flusso con watch (training). Per questo si
/// persiste con [HrvMetrics.empty] (`samples == 0`): il discriminatore
/// watch-less ⟺ con-watch è intrinseco e la dashboard esclude già queste righe
/// dai trend (coherence/RMSSD filtrano `> 0`), pur contandole tra le sessioni.
///
/// È volutamente SEPARATO da `PacerController`: quel controller è condiviso col
/// training (lo riusa per l'orb), quindi mettere qui la persistenza evita il
/// doppio-save. Modellato su `MorningCheckInController.save()`.
class BreathSessionRecorder {
  BreathSessionRecorder(this._ref);

  final Ref _ref;

  /// Sotto questa durata non si salva: pochi secondi sono un "aperto e chiuso",
  /// non una pratica — eviterebbe solo di intasare lo storico.
  static const Duration minDuration = Duration(seconds: 30);

  /// Salva la sessione di respiro. Ritorna l'id, o `null` se troppo breve (sotto
  /// [minDuration]) — così il chiamante può ignorare le aperture accidentali.
  Future<int?> record({
    required DateTime startedAt,
    required DateTime endedAt,
    required BreathingPattern pattern,
  }) async {
    if (endedAt.difference(startedAt) < minDuration) return null;

    final session = Session(
      kind: SessionKind.freestyle,
      tag: SessionTag.general,
      startedAt: startedAt,
      endedAt: endedAt,
      pattern: pattern,
      metrics: HrvMetrics.empty,
    );
    // RR vuoti → insert della sola riga header (nessun rr_samples).
    final id = await _ref
        .read(sessionRepositoryProvider)
        .saveSession(session, const []);

    // Storico e cruscotto cronico vedono subito la nuova pratica.
    _ref.invalidate(sessionsListProvider);
    _ref.invalidate(hrvDashboardSessionsProvider);
    return id;
  }
}

final breathSessionRecorderProvider =
    Provider<BreathSessionRecorder>((ref) => BreathSessionRecorder(ref));
