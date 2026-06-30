import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/training_plan/plan_models.dart';

void main() {
  // Tutte le date in UTC per rendere deterministica l'aritmetica delle finestre.
  final start = DateTime.utc(2026, 1, 1);
  TrainingPlan planAt(DateTime s) => TrainingPlan(
        goal: PlanGoal.calm,
        createdAt: s,
        startedAt: s,
        resonanceBpm: 5.5,
      );
  List<DateTime> daysAfter(List<int> ds) =>
      ds.map((d) => start.add(Duration(days: d))).toList();

  group('scaletta di default', () {
    test('4 settimane, ramp 4→18 min, frequenza 4→5', () {
      expect(kDefaultPlanLadder.length, 4);
      expect(kDefaultPlanLadder.first.durationMin, 4);
      expect(kDefaultPlanLadder.last.durationMin, 18);
      expect(kDefaultPlanLadder.map((w) => w.targetSessions).toList(),
          [4, 5, 5, 5]);
    });

    test('totale sessioni-obiettivo = somma dei target', () {
      expect(planAt(start).totalTargetSessions, 4 + 5 + 5 + 5);
    });

    test('soglia di avanzamento = ceil(80% del target), min 1', () {
      expect(planAdvanceThreshold(4), 4); // ceil(3.2)
      expect(planAdvanceThreshold(5), 4); // ceil(4.0)
      expect(planAdvanceThreshold(1), 1);
      expect(planAdvanceThreshold(0), 1); // mai zero
    });
  });

  group('computePlanProgress — avanzamento adattivo', () {
    test('piano fresco senza sessioni → livello 1, propone oggi', () {
      final p = computePlanProgress(planAt(start), const [], start);
      expect(p.currentLevel, 1);
      expect(p.windowIndex, 0);
      expect(p.completedThisWindow, 0);
      expect(p.recommendToday, isTrue);
      expect(p.reachedGraduation, isFalse);
      expect(p.recommendedDurationMin, 4);
    });

    test('completata la settimana 1 (≥soglia) → sale a livello 2 nella finestra '
        'successiva', () {
      // 4 sessioni nella finestra 0 (giorni 0..6), poi siamo nella finestra 1.
      final p = computePlanProgress(
        planAt(start),
        daysAfter([0, 2, 4, 6]),
        start.add(const Duration(days: 8)),
      );
      expect(p.currentLevel, 2);
      expect(p.currentWeek.durationMin, 8);
      expect(p.windowIndex, 1);
    });

    test('settimana saltata → il livello TIENE (niente punizione)', () {
      // Solo 1 sessione nella finestra 0 (sotto soglia 4): non si avanza.
      final p = computePlanProgress(
        planAt(start),
        daysAfter([1]),
        start.add(const Duration(days: 9)),
      );
      expect(p.currentLevel, 1);
      expect(p.windowIndex, 1);
    });

    test('percorso completo → traguardo (graduation) raggiunto', () {
      // finestra0:4 (→liv2), finestra1:5 (→liv3), finestra2:5 (→liv4),
      // finestra3:5 (liv4 ultimo, ≥soglia → graduation).
      final completions = <DateTime>[
        ...daysAfter([0, 1, 2, 3]), // window 0
        ...daysAfter([7, 8, 9, 10, 11]), // window 1
        ...daysAfter([14, 15, 16, 17, 18]), // window 2
        ...daysAfter([21, 22, 23, 24, 25]), // window 3
      ];
      final p = computePlanProgress(
        planAt(start),
        completions,
        start.add(const Duration(days: 30)),
      );
      expect(p.currentLevel, 4);
      expect(p.reachedGraduation, isTrue);
      expect(p.totalCompleted, 19);
    });

    test('graduation rilevata anche dentro la finestra corrente all\'ultimo '
        'livello', () {
      // Avanza a livello 4 entro le finestre 0,1,2, poi nella finestra 3
      // (corrente) raggiungi la soglia → graduation senza aspettare il confine.
      final completions = <DateTime>[
        ...daysAfter([0, 1, 2, 3]),
        ...daysAfter([7, 8, 9, 10]),
        ...daysAfter([14, 15, 16, 17]),
        ...daysAfter([21, 22, 23, 24]), // finestra 3, corrente
      ];
      final p = computePlanProgress(
        planAt(start),
        completions,
        start.add(const Duration(days: 24)),
      );
      expect(p.currentLevel, 4);
      expect(p.completedThisWindow, 4);
      expect(p.reachedGraduation, isTrue);
    });
  });

  group('computePlanProgress — proposta di oggi', () {
    test('già allenato oggi → non insiste', () {
      final now = start.add(const Duration(days: 3));
      final p = computePlanProgress(planAt(start), [now], now);
      expect(p.completedToday, 1);
      expect(p.recommendToday, isFalse);
    });

    test('quota settimanale raggiunta → non insiste (ma niente streak persa)',
        () {
      final now = start.add(const Duration(days: 3));
      // 4 sessioni nei giorni 0..2 (finestra corrente), nessuna oggi.
      final p = computePlanProgress(
        planAt(start),
        daysAfter([0, 0, 1, 2]),
        now,
      );
      expect(p.windowComplete, isTrue);
      expect(p.completedToday, 0);
      expect(p.recommendToday, isFalse);
    });

    test('piano già marcato completed → graduation a prescindere', () {
      final p = computePlanProgress(
        planAt(start).copyWith(status: PlanStatus.completed),
        const [],
        start,
      );
      expect(p.reachedGraduation, isTrue);
    });
  });

  group('serializzazione', () {
    test('TrainingPlan round-trip JSON conserva i campi', () {
      final plan = TrainingPlan(
        goal: PlanGoal.stress,
        status: PlanStatus.active,
        createdAt: start,
        startedAt: start,
        resonanceBpm: 5.5,
        implementationIntention: 'Dopo la sveglia',
        reminderMinuteOfDay: 8 * 60 + 30,
      );
      final back = TrainingPlan.fromJson(plan.toJson());
      expect(back.goal, PlanGoal.stress);
      expect(back.resonanceBpm, 5.5);
      expect(back.implementationIntention, 'Dopo la sveglia');
      expect(back.reminderHour, 8);
      expect(back.reminderMinute, 30);
      expect(back.ladder.length, 4);
    });

    test('copyWith clearReminder/clearEndedAt azzerano i campi', () {
      final plan = planAt(start).copyWith(
        reminderMinuteOfDay: 600,
        endedAt: start,
      );
      expect(plan.copyWith(clearReminder: true).reminderMinuteOfDay, isNull);
      expect(plan.copyWith(clearEndedAt: true).endedAt, isNull);
    });
  });

  group('PostSessionReport', () {
    test('calmDelta confronta calma finale con calma iniziale stimata', () {
      // tensione pre 7 → calma pre stimata 3; calma post 8 → delta +5.
      const r = PostSessionReport(tensionPre: 7, calmPost: 8);
      expect(r.calmDelta, 5);
    });

    test('calmDelta null se manca un estremo', () {
      expect(const PostSessionReport(calmPost: 8).calmDelta, isNull);
      expect(const PostSessionReport(tensionPre: 5).calmDelta, isNull);
    });

    test('round-trip JSON con sensazioni e nota', () {
      const r = PostSessionReport(
        tensionPre: 6,
        calmPost: 9,
        mood: 4,
        sensations: [BodySensation.slowerBreath, BodySensation.stillTense],
        note: 'meglio del solito',
      );
      final back = PostSessionReport.fromJson(r.toJson());
      expect(back.tensionPre, 6);
      expect(back.calmPost, 9);
      expect(back.mood, 4);
      expect(back.sensations, [
        BodySensation.slowerBreath,
        BodySensation.stillTense,
      ]);
      expect(back.note, 'meglio del solito');
    });

    test('isEmpty true quando nulla è compilato', () {
      expect(const PostSessionReport().isEmpty, isTrue);
      expect(const PostSessionReport(mood: 3).isEmpty, isFalse);
    });

    test('fromJson scarta sensazioni sconosciute senza crash', () {
      final back = PostSessionReport.fromJson({
        'sens': ['slowerBreath', 'gibberish'],
      });
      expect(back.sensations, [BodySensation.slowerBreath]);
    });
  });
}
