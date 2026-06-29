@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/features/pacer/state/breath_session_recorder.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';
import 'package:hrv_trainer/shared/storage/database.dart';
import 'package:hrv_trainer/shared/storage/session_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  late ProviderContainer container;
  late SessionRepository repo;
  setUp(() {
    // Il recorder registra anche la metrica "primo respiro" (#13), che scrive in
    // SharedPreferences: serve il mock o getInstance lancia in test.
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('hrv_breath_rec_test');
    AppDatabase.testFactory = databaseFactoryFfi;
    AppDatabase.testPath = '${tmp.path}/test.db';
    container = ProviderContainer();
    repo = SessionRepository();
  });
  tearDown(() async {
    container.dispose();
    await AppDatabase.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('salva una sessione freestyle senza metriche né RR (watch-less)', () async {
    final recorder = container.read(breathSessionRecorderProvider);
    final started = DateTime(2026, 6, 1, 8, 0, 0);
    final ended = started.add(const Duration(minutes: 3));

    final id = await recorder.record(
      startedAt: started,
      endedAt: ended,
      pattern: BreathingPattern.resonance6bpm,
    );
    expect(id, isNotNull);

    final s = await repo.getSession(id!);
    expect(s, isNotNull);
    expect(s!.kind, SessionKind.freestyle);
    expect(s.tag, SessionTag.general);
    expect(s.metrics.samples, 0); // metriche vuote → watch-less
    expect(s.duration, const Duration(minutes: 3)); // durata = pattern respirato
    expect(await repo.getSessionRrSamples(id), isEmpty);

    // È presente nella lista (conta come pratica nella cronaca /hrv).
    expect((await repo.listSessions()).length, 1);
  });

  test('non salva sessioni più brevi della durata minima', () async {
    final recorder = container.read(breathSessionRecorderProvider);
    final started = DateTime(2026, 6, 1, 8, 0, 0);
    final ended = started.add(const Duration(seconds: 20)); // < 30s

    final id = await recorder.record(
      startedAt: started,
      endedAt: ended,
      pattern: BreathingPattern.resonance6bpm,
    );
    expect(id, isNull);
    expect(await repo.listSessions(), isEmpty);
  });
}
