import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/notifications/plan_reminder.dart';
import 'package:hrv_trainer/shared/training_plan/plan_models.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1);
  TrainingPlan plan({
    PlanStatus status = PlanStatus.active,
    int? reminderMinuteOfDay = 8 * 60 + 30,
  }) =>
      TrainingPlan(
        goal: PlanGoal.calm,
        status: status,
        createdAt: start,
        startedAt: start,
        resonanceBpm: 5.5,
        reminderMinuteOfDay: reminderMinuteOfDay,
      );

  PlanProgress progress({
    int level = 1,
    bool graduation = false,
  }) =>
      PlanProgress(
        currentLevel: level,
        currentWeek: kDefaultPlanLadder[level - 1],
        windowIndex: 0,
        completedThisWindow: 0,
        completedToday: 0,
        totalCompleted: 0,
        totalTarget: 19,
        reachedGraduation: graduation,
      );

  test('nessun piano → nessun promemoria', () {
    expect(planReminderSpec(null, null), isNull);
  });

  test('piano senza orario → nessun promemoria', () {
    expect(planReminderSpec(plan(reminderMinuteOfDay: null), progress()),
        isNull);
  });

  test('piano non attivo → nessun promemoria', () {
    expect(
        planReminderSpec(plan(status: PlanStatus.completed), progress()),
        isNull);
  });

  test('traguardo raggiunto → nessun promemoria', () {
    expect(planReminderSpec(plan(), progress(graduation: true)), isNull);
  });

  test('piano attivo → orario e durata della settimana corrente', () {
    final spec = planReminderSpec(plan(), progress(level: 2));
    expect(spec, isNotNull);
    expect(spec!.hour, 8);
    expect(spec.minute, 30);
    expect(spec.body, contains('8 min')); // durata della settimana 2
  });

  test('senza progress usa la durata della prima settimana', () {
    final spec = planReminderSpec(plan(), null);
    expect(spec!.body, contains('4 min'));
  });
}
