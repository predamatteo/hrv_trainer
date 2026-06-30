import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/session_repository.dart';
import 'plan_models.dart';

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

// ===== Piano attivo + progresso ==============================================

/// Il piano attivo corrente (al più uno), oppure null. autoDispose così si
/// aggiorna rientrando nelle schermate; invalidato esplicitamente dal
/// PlanController ad ogni cambiamento.
final activePlanProvider =
    FutureProvider.autoDispose<TrainingPlan?>((ref) async {
  final repo = ref.watch(sessionRepositoryProvider);
  return repo.getActivePlan();
});

/// Timestamp d'inizio delle sessioni completate del piano attivo (per la vista
/// a calendario). Lista vuota se non c'è un piano attivo.
final planSessionTimesProvider =
    FutureProvider.autoDispose<List<DateTime>>((ref) async {
  final plan = await ref.watch(activePlanProvider.future);
  if (plan == null || plan.id == null) return const [];
  return ref.watch(sessionRepositoryProvider).planSessionTimes(plan.id!);
});

/// Stato derivato del piano attivo (livello, finestra, aderenza, traguardo),
/// calcolato dal motore puro sulle sessioni completate del piano. null se non
/// c'è un piano attivo.
final planProgressProvider =
    FutureProvider.autoDispose<PlanProgress?>((ref) async {
  final plan = await ref.watch(activePlanProvider.future);
  if (plan == null || plan.id == null) return null;
  final times = await ref.watch(planSessionTimesProvider.future);
  return computePlanProgress(plan, times, DateTime.now());
});

/// Costruisce la scaletta di default, opzionalmente sovrascrivendo il numero di
/// sessioni-obiettivo settimanale con la scelta dell'utente (clamp 3..7). La
/// progressione delle durate resta invariata.
List<PlanWeek> buildPlanLadder({int? sessionsPerWeek}) {
  if (sessionsPerWeek == null) return kDefaultPlanLadder;
  final n = sessionsPerWeek.clamp(3, 7);
  return kDefaultPlanLadder
      .map((w) => w.copyWith(targetSessions: n))
      .toList(growable: false);
}

/// Orchestratore del ciclo di vita del piano. Lo stato vive nel DB; il
/// controller espone i comandi e invalida i provider Future al cambiamento.
class PlanController {
  PlanController(this._ref);
  final Ref _ref;

  SessionRepository get _repo => _ref.read(sessionRepositoryProvider);

  void _invalidate() {
    _ref.invalidate(activePlanProvider);
    _ref.invalidate(planProgressProvider);
  }

  /// Crea (e attiva) un nuovo piano, abbandonando l'eventuale piano attivo
  /// precedente: ne esiste al più uno. Ritorna il piano salvato (con id).
  Future<TrainingPlan> createPlan({
    required PlanGoal goal,
    required double resonanceBpm,
    String? implementationIntention,
    int? reminderMinuteOfDay,
    int? sessionsPerWeek,
    DateTime? now,
  }) async {
    final existing = await _repo.getActivePlan();
    if (existing != null) {
      await _repo.updatePlan(
          existing.copyWith(status: PlanStatus.abandoned, endedAt: now));
    }
    final created = now ?? DateTime.now();
    final plan = TrainingPlan(
      goal: goal,
      createdAt: created,
      startedAt: created,
      ladder: buildPlanLadder(sessionsPerWeek: sessionsPerWeek),
      resonanceBpm: resonanceBpm,
      implementationIntention: implementationIntention,
      reminderMinuteOfDay: reminderMinuteOfDay,
    );
    final id = await _repo.savePlan(plan);
    _invalidate();
    return plan.copyWith(id: id);
  }

  /// Abbandona il piano attivo (interruzione volontaria dell'utente).
  Future<void> abandonActivePlan({DateTime? now}) async {
    final active = await _repo.getActivePlan();
    if (active == null) return;
    await _repo.updatePlan(
        active.copyWith(status: PlanStatus.abandoned, endedAt: now));
    _invalidate();
  }

  /// Aggiorna i metadati "soft" del piano attivo (intention/promemoria) senza
  /// toccarne lo stato.
  Future<void> updateActivePlanSettings({
    String? implementationIntention,
    int? reminderMinuteOfDay,
    bool clearReminder = false,
  }) async {
    final active = await _repo.getActivePlan();
    if (active == null) return;
    await _repo.updatePlan(active.copyWith(
      implementationIntention: implementationIntention,
      reminderMinuteOfDay: reminderMinuteOfDay,
      clearReminder: clearReminder,
    ));
    _invalidate();
  }

  /// Da chiamare dopo aver salvato una sessione del piano: ricalcola il
  /// progresso e, se è stato raggiunto il traguardo, marca il piano come
  /// completato (pronto per la ri-valutazione "diploma"). Ritorna true se il
  /// piano è appena passato a completato. Idempotente.
  Future<bool> onPlanSessionSaved({DateTime? now}) async {
    final active = await _repo.getActivePlan();
    if (active == null || active.id == null) {
      _invalidate();
      return false;
    }
    final times = await _repo.planSessionTimes(active.id!);
    final progress =
        computePlanProgress(active, times, now ?? DateTime.now());
    var graduated = false;
    if (progress.reachedGraduation && active.status == PlanStatus.active) {
      await _repo.updatePlan(active.copyWith(
        status: PlanStatus.completed,
        endedAt: now ?? DateTime.now(),
      ));
      graduated = true;
    }
    _invalidate();
    return graduated;
  }
}

final planControllerProvider =
    Provider<PlanController>((ref) => PlanController(ref));
