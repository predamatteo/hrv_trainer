import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/session_repository.dart';
import '../training_plan/plan_models.dart';
import 'notification_service.dart';

/// Specifica del promemoria del piano da schedulare. null significa "nessun
/// promemoria" (piano assente/non attivo/senza orario/al traguardo).
class PlanReminderSpec {
  final int hour;
  final int minute;
  final String title;
  final String body;
  const PlanReminderSpec({
    required this.hour,
    required this.minute,
    required this.title,
    required this.body,
  });
}

/// Decide, in modo PURO, se e come deve suonare il promemoria del piano.
/// Estratto dalla parte di scheduling (che tocca il plugin) per poter essere
/// testato senza piattaforma.
///
/// Regole: nessun promemoria se non c'è un piano attivo, se l'utente non ha
/// scelto un orario, o se il traguardo è già stato raggiunto (il piano è finito,
/// resta solo la ri-valutazione). Altrimenti il corpo riflette la durata
/// consigliata della settimana corrente, in linea con "segui il cerchio, non un
/// numero".
PlanReminderSpec? planReminderSpec(TrainingPlan? plan, PlanProgress? progress) {
  if (plan == null || !plan.status.isActive) return null;
  final mins = plan.reminderMinuteOfDay;
  if (mins == null) return null;
  if (progress != null && progress.reachedGraduation) return null;

  final durationMin =
      progress?.recommendedDurationMin ?? plan.ladder.first.durationMin;
  return PlanReminderSpec(
    hour: mins ~/ 60,
    minute: mins % 60,
    title: 'La tua sessione di oggi',
    body: 'È il momento del respiro guidato del piano · circa $durationMin min. '
        'Segui il cerchio.',
  );
}

/// Tiene allineato il promemoria del piano allo stato del piano attivo. Va
/// chiamato `reconcile()` all'avvio, al resume e dopo ogni cambiamento del
/// piano (creazione, abbandono, sessione completata, modifica orario).
class PlanReminderController {
  PlanReminderController(this.ref);
  final Ref ref;

  Future<void> reconcile({DateTime? now}) async {
    final repo = ref.read(sessionRepositoryProvider);
    final service = ref.read(notificationServiceProvider);

    final plan = await repo.getActivePlan();
    PlanProgress? progress;
    if (plan != null && plan.id != null) {
      final times = await repo.planSessionTimes(plan.id!);
      progress = computePlanProgress(plan, times, now ?? DateTime.now());
    }

    final spec = planReminderSpec(plan, progress);
    if (spec == null) {
      await service.cancelPlanReminders();
      return;
    }
    await service.schedulePlanReminder(
      hour: spec.hour,
      minute: spec.minute,
      title: spec.title,
      body: spec.body,
    );
  }
}

final planReminderControllerProvider =
    Provider<PlanReminderController>((ref) => PlanReminderController(ref));
