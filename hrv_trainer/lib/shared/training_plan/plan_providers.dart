import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/session_repository.dart';

/// Oltre questo orizzonte (giorni) la frequenza di risonanza misurata è
/// considerata "vecchia": può essersi spostata con l'allenamento, quindi il
/// piano consiglia una nuova valutazione. Non è un blocco — un assessment con
/// una RF usabile resta sufficiente per *avviare* un piano (richiesta
/// dell'utente: "necessario l'assessment"), ma più vecchio di così la UI invita
/// a rifarlo. La ri-valutazione finale del piano ("diploma") rinfresca comunque
/// questo valore.
const int kAssessmentValidityDays = 60;

/// Esito del gate di idoneità del piano rispetto all'assessment di risonanza.
/// Valore puro (l'età è calcolata a monte): facile da testare.
class AssessmentGate {
  /// Frequenza di risonanza misurata (respiri/min). null se non c'è alcun
  /// assessment, oppure se l'ultimo non ha prodotto una RF valida (dati
  /// insufficienti).
  final double? bpm;
  final DateTime? takenAt;

  /// Età dell'assessment in giorni (calcolata al build del provider). null se
  /// non esiste alcun assessment.
  final int? ageDays;

  const AssessmentGate({this.bpm, this.takenAt, this.ageDays});

  /// Nessun assessment salvato.
  static const none = AssessmentGate();

  bool get hasAssessment => takenAt != null;

  /// C'è una frequenza di risonanza utilizzabile per seminare il piano.
  bool get hasUsableRf => bpm != null;

  /// L'assessment è recente (entro [kAssessmentValidityDays]).
  bool get isFresh => ageDays != null && ageDays! <= kAssessmentValidityDays;

  /// Si può avviare un piano: serve solo una RF utilizzabile. La freschezza è
  /// un consiglio, non un blocco.
  bool get canStartPlan => hasUsableRf;

  /// La RF è usabile ma stantia → invita a rifare la valutazione.
  bool get recommendReassess => hasUsableRf && !isFresh;
}

/// Gate di idoneità del piano: legge l'ultimo assessment e ne calcola l'età.
/// autoDispose così si ricalcola rientrando nelle schermate del piano (dopo una
/// nuova valutazione il gate si sblocca da sé).
final assessmentGateProvider =
    FutureProvider.autoDispose<AssessmentGate>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final a = await repo.latestAssessment();
  if (a == null) return AssessmentGate.none;
  final age = DateTime.now().difference(a.takenAt).inDays;
  return AssessmentGate(bpm: a.bpm, takenAt: a.takenAt, ageDays: age);
});
