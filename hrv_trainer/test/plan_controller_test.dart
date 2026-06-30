@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';
import 'package:hrv_trainer/shared/storage/database.dart';
import 'package:hrv_trainer/shared/storage/session_repository.dart';
import 'package:hrv_trainer/shared/training_plan/plan_models.dart';
import 'package:hrv_trainer/shared/training_plan/plan_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  late ProviderContainer container;
  late SessionRepository repo;
  late PlanController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hrv_plan_ctrl');
    AppDatabase.testFactory = databaseFactoryFfi;
    AppDatabase.testPath = '${tmp.path}/test.db';
    container = ProviderContainer();
    repo = container.read(sessionRepositoryProvider);
    controller = container.read(planControllerProvider);
  });
  tearDown(() async {
    // I comandi del controller invalidano i FutureProvider autoDispose; senza
    // listener quei rebuild restano pendenti e container.dispose() lancia un
    // benigno "Future already completed" (artefatto noto di Riverpod in
    // teardown, dopo che le asserzioni sono già passate). Lasciamo prima
    // risolvere i future e poi proteggiamo la dispose.
    try {
      await container.read(activePlanProvider.future);
      await container.read(planProgressProvider.future);
    } catch (_) {}
    try {
      container.dispose();
    } catch (_) {}
    await AppDatabase.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> savePlanSession(int planId, DateTime when) =>
      repo.saveSession(
        Session(
          kind: SessionKind.training,
          tag: SessionTag.general,
          startedAt: when,
          endedAt: when.add(const Duration(minutes: 5)),
          pattern: BreathingPattern.resonance6bpm,
          metrics: HrvMetrics.empty,
          planId: planId,
        ),
        const [],
      );

  test('createPlan attiva un piano seminato dalla risonanza', () async {
    final plan = await controller.createPlan(
      goal: PlanGoal.calm,
      resonanceBpm: 5.5,
    );
    expect(plan.id, isNotNull);
    final active = await repo.getActivePlan();
    expect(active!.goal, PlanGoal.calm);
    expect(active.resonanceBpm, 5.5);
    expect(active.ladder.length, 4);
  });

  test('createPlan due volte → il precedente è abbandonato, uno solo attivo',
      () async {
    await controller.createPlan(goal: PlanGoal.calm, resonanceBpm: 5.5);
    await controller.createPlan(goal: PlanGoal.stress, resonanceBpm: 6.0);
    final active = await repo.getActivePlan();
    expect(active!.goal, PlanGoal.stress);
    final all = await repo.listPlans();
    expect(all.length, 2);
    expect(all.where((p) => p.status == PlanStatus.active).length, 1);
  });

  test('abandonActivePlan → nessun piano attivo', () async {
    await controller.createPlan(goal: PlanGoal.calm, resonanceBpm: 5.5);
    await controller.abandonActivePlan();
    expect(await repo.getActivePlan(), isNull);
  });

  test('sessionsPerWeek sovrascrive i target della scaletta', () async {
    await controller.createPlan(
      goal: PlanGoal.calm,
      resonanceBpm: 5.5,
      sessionsPerWeek: 3,
    );
    final active = await repo.getActivePlan();
    expect(active!.ladder.map((w) => w.targetSessions).toSet(), {3});
  });

  test('planProgressProvider su piano fresco → livello 1', () async {
    await controller.createPlan(goal: PlanGoal.calm, resonanceBpm: 5.5);
    final progress = await container.read(planProgressProvider.future);
    expect(progress, isNotNull);
    expect(progress!.currentLevel, 1);
    expect(progress.recommendToday, isTrue);
  });

  test('onPlanSessionSaved marca completato al traguardo', () async {
    final base = DateTime(2026, 1, 1);
    // Piano avviato nel passato (startedAt = base) per simulare le finestre.
    final id = await repo.savePlan(TrainingPlan(
      goal: PlanGoal.calm,
      createdAt: base,
      startedAt: base,
      resonanceBpm: 5.5,
    ));
    // 4 sessioni in ciascuna delle finestre 0..3 → graduation.
    for (final w in [0, 7, 14, 21]) {
      for (final d in [0, 1, 2, 3]) {
        await savePlanSession(id, base.add(Duration(days: w + d)));
      }
    }
    final graduated =
        await controller.onPlanSessionSaved(now: base.add(const Duration(days: 30)));
    expect(graduated, isTrue);
    expect(await repo.getActivePlan(), isNull); // ora completed
    expect((await repo.getPlan(id))!.status, PlanStatus.completed);
  });

  test('onPlanSessionSaved senza traguardo non completa', () async {
    final plan =
        await controller.createPlan(goal: PlanGoal.calm, resonanceBpm: 5.5);
    await savePlanSession(plan.id!, DateTime.now());
    final graduated = await controller.onPlanSessionSaved();
    expect(graduated, isFalse);
    expect(await repo.getActivePlan(), isNotNull);
  });
}
