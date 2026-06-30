@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/rr_interval.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';
import 'package:hrv_trainer/shared/storage/database.dart';
import 'package:hrv_trainer/shared/storage/session_repository.dart';
import 'package:hrv_trainer/shared/training_plan/plan_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _validMetrics = jsonEncode(HrvMetrics.empty.toJson());
final _validPattern = jsonEncode(BreathingPattern.resonance6bpm.toJson());

Session _session(DateTime when) => Session(
      kind: SessionKind.training,
      tag: SessionTag.general,
      startedAt: when,
      endedAt: when.add(const Duration(minutes: 20)),
      pattern: BreathingPattern.resonance6bpm,
      metrics: HrvMetrics.empty,
    );

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  late SessionRepository repo;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hrv_repo_test');
    AppDatabase.testFactory = databaseFactoryFfi;
    AppDatabase.testPath = '${tmp.path}/test.db';
    repo = SessionRepository();
  });
  tearDown(() async {
    await AppDatabase.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('saveSession / getSession / rr samples roundtrip', () async {
    final id = await repo.saveSession(_session(DateTime(2026, 6, 1)), [
      RrInterval(timestamp: DateTime(2026, 6, 1), ms: 800),
      RrInterval(timestamp: DateTime(2026, 6, 1, 0, 0, 1), ms: 820),
    ]);
    final s = await repo.getSession(id);
    expect(s, isNotNull);
    expect(s!.tag, SessionTag.general);
    final rr = await repo.getSessionRrSamples(id);
    expect(rr.map((e) => e.ms).toList(), [800, 820]);
  });

  test('export + re-import dello stesso backup → dedup su startedAt', () async {
    await repo.saveSession(_session(DateTime(2026, 6, 1)),
        [RrInterval(timestamp: DateTime(2026, 6, 1), ms: 800)]);
    final backup = await repo.exportAll();

    // La sessione e' gia' presente: il re-import deve saltarla, non duplicarla.
    final r = await repo.importAll(backup);
    expect(r.sessionsImported, 0);
    expect(r.sessionsSkipped, 1);
    expect((await repo.listSessions()).length, 1);
  });

  test('importAll rifiuta uno schemaVersion piu nuovo', () async {
    final r = await repo.importAll({'schemaVersion': 99, 'sessions': const []});
    expect(r.isError, isTrue);
  });

  test('importAll scarta i record corrotti senza inquinare il DB', () async {
    final r = await repo.importAll({
      'schemaVersion': 1,
      'sessions': [
        {
          'startedAt': 1000,
          'kind': 'training',
          'patternJson': _validPattern,
          'metricsJson': '{not valid json',
        }, // metrics non decodificabile
        {
          'startedAt': 2000,
          'kind': 'training',
          'patternJson': 'garbage',
          'metricsJson': _validMetrics,
        }, // pattern non decodificabile
        {
          'kind': 'training',
          'patternJson': _validPattern,
          'metricsJson': _validMetrics,
        }, // startedAt mancante
        {
          'startedAt': 3000,
          'kind': 'training',
          'patternJson': _validPattern,
          'metricsJson': _validMetrics,
        }, // valido
      ],
    });
    expect(r.sessionsInvalid, 3);
    expect(r.sessionsImported, 1);
    // Solo il record valido e' nel DB, e si rilegge senza crash.
    final all = await repo.listSessions();
    expect(all.length, 1);
    expect(all.first.startedAt.millisecondsSinceEpoch, 3000);
  });

  test('backup senza morningMetaJson (v1) importa con morning null', () async {
    final r = await repo.importAll({
      'schemaVersion': 1,
      'sessions': [
        {
          'startedAt': 4000,
          'kind': 'reading',
          'tag': 'morning',
          'patternJson': _validPattern,
          'metricsJson': _validMetrics,
          // niente morningMetaJson
        },
      ],
    });
    expect(r.sessionsImported, 1);
    final s = (await repo.listSessions()).single;
    expect(s.morning, isNull);
    expect(s.tag, SessionTag.morning);
  });

  // ===== Piano di allenamento (v4) ===========================================

  TrainingPlan makePlan(DateTime created) => TrainingPlan(
        goal: PlanGoal.calm,
        createdAt: created,
        startedAt: created,
        resonanceBpm: 5.5,
      );

  test('savePlan / getActivePlan / updatePlan', () async {
    final id = await repo.savePlan(makePlan(DateTime(2026, 6, 1)));
    final active = await repo.getActivePlan();
    expect(active, isNotNull);
    expect(active!.id, id);
    expect(active.goal, PlanGoal.calm);
    expect(active.resonanceBpm, 5.5);

    // Completando il piano non risulta più "attivo".
    await repo.updatePlan(active.copyWith(status: PlanStatus.completed));
    expect(await repo.getActivePlan(), isNull);
    expect((await repo.getPlan(id))!.status, PlanStatus.completed);
  });

  test('saveSession con planId + report → riletti correttamente', () async {
    final planId = await repo.savePlan(makePlan(DateTime(2026, 6, 1)));
    final session = _session(DateTime(2026, 6, 2)).copyWith(
      planId: planId,
      report: const PostSessionReport(
        tensionPre: 7,
        calmPost: 9,
        mood: 4,
        sensations: [BodySensation.slowerBreath],
        note: 'bene',
      ),
    );
    final sid = await repo.saveSession(session, const []);
    final back = await repo.getSession(sid);
    expect(back!.planId, planId);
    expect(back.report!.calmDelta, 6); // 9 - (10 - 7)
    expect(back.report!.sensations, [BodySensation.slowerBreath]);

    // planSessionTimes conta solo le sessioni concluse del piano.
    final times = await repo.planSessionTimes(planId);
    expect(times.length, 1);
    expect(times.single, DateTime(2026, 6, 2));
  });

  test('report vuoto non viene persistito (resta null)', () async {
    final sid = await repo.saveSession(
      _session(DateTime(2026, 6, 3)).copyWith(report: const PostSessionReport()),
      const [],
    );
    expect((await repo.getSession(sid))!.report, isNull);
  });

  test('export/import di un piano → planId delle sessioni ri-mappato', () async {
    final planId = await repo.savePlan(makePlan(DateTime(2026, 6, 1)));
    await repo.saveSession(
      _session(DateTime(2026, 6, 2)).copyWith(planId: planId),
      const [],
    );
    final backup = await repo.exportAll();

    // Re-import sullo stesso DB: piano e sessione già presenti → tutto skippato.
    final r = await repo.importAll(backup);
    expect(r.plansSkipped, 1);
    expect(r.sessionsSkipped, 1);

    // Import su un DB pulito: il piano prende un nuovo id e la sessione vi
    // resta collegata tramite il re-mapping.
    await AppDatabase.resetForTest();
    AppDatabase.testFactory = databaseFactoryFfi;
    AppDatabase.testPath = '${tmp.path}/test2.db';
    final repo2 = SessionRepository();
    final r2 = await repo2.importAll(backup);
    expect(r2.plansImported, 1);
    expect(r2.sessionsImported, 1);
    final newPlan = await repo2.getActivePlan();
    expect(newPlan, isNotNull);
    final linked = (await repo2.listSessions()).single;
    expect(linked.planId, newPlan!.id);
  });

  test('latestAssessment ritorna bpm + data, null se nessuno', () async {
    expect(await repo.latestAssessment(), isNull);
    await repo.saveAssessment(ResonanceAssessment(
      takenAt: DateTime(2026, 6, 1, 8),
      steps: const [],
      resonanceBpm: 5.5,
    ));
    final a = await repo.latestAssessment();
    expect(a!.bpm, 5.5);
    expect(a.takenAt, DateTime(2026, 6, 1, 8));
  });
}
