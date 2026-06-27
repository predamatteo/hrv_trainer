@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/connect_iq/heart_rate_source.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';
import 'package:hrv_trainer/shared/connect_iq/remote_session_persister.dart';
import 'package:hrv_trainer/shared/connect_iq/remote_session_summary.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/rr_interval.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';
import 'package:hrv_trainer/shared/storage/session_repository.dart';

class _FakeSource extends HeartRateSource {
  final remote = StreamController<RemoteSessionSummary>.broadcast();
  final List<int> ackedKeys = [];

  @override
  Stream<RemoteSessionSummary> get remoteSessionStream => remote.stream;
  @override
  Future<void> sendSummaryAck(int startMs) async => ackedKeys.add(startMs);
  @override
  Future<void> requestSync({bool force = false}) async {}

  @override
  String get displayName => 'fake';
  @override
  HrSourceState get state => HrSourceState.connected;
  @override
  Stream<HrSourceState> get stateStream => const Stream.empty();
  @override
  Stream<HeartRateEvent> get heartRateStream => const Stream.empty();
  @override
  Future<void> start(
      {BreathingPattern? pattern, int? targetDurationSec, int? prepMs}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<HrvOnDemandResult?> requestHrvOnDemand() async => null;
  @override
  void dispose() {}
}

class _FakeRepo extends SessionRepository {
  bool existing = false;
  bool failSave = false;
  int saveCount = 0;

  @override
  Future<int> repairOverflowedSessionTimestamps() async => 0;
  @override
  Future<bool> existsSessionStartedAt(DateTime startedAt) async => existing;
  @override
  Future<int> saveSession(Session s, List<RrInterval> rr) async {
    saveCount++;
    if (failSave) throw Exception('boom');
    return 1;
  }
}

RemoteSessionSummary _summary({int startMsRaw = 1717200000000}) =>
    RemoteSessionSummary(
      startedAt: DateTime(2026, 6, 1),
      endedAt: DateTime(2026, 6, 1, 0, 20),
      meanHrBpm: 60,
      sdnnMs: 40,
      rmssdMs: 35,
      samples: 100,
      rrMs: List.filled(100, 900),
      startMsRaw: startMsRaw,
    );

void main() {
  late _FakeSource source;
  late _FakeRepo repo;
  late ProviderContainer container;

  setUp(() {
    source = _FakeSource();
    repo = _FakeRepo();
    container = ProviderContainer(overrides: [
      heartRateSourceProvider.overrideWithValue(source),
      sessionRepositoryProvider.overrideWithValue(repo),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await source.remote.close();
  });

  test('dedup hit: invia solo l\'ack con startMsRaw, non salva', () async {
    repo.existing = true;
    container.read(remoteSessionPersisterProvider); // arma il listener
    source.remote.add(_summary(startMsRaw: 42));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(repo.saveCount, 0);
    expect(source.ackedKeys, [42]); // ack = startMsRaw (chiave del PendingStore)
  });

  test('persist fallito: nessun ack, nessuna eccezione propagata', () async {
    repo.existing = false;
    repo.failSave = true;
    container.read(remoteSessionPersisterProvider);
    source.remote.add(_summary(startMsRaw: 99));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(repo.saveCount, 1);
    // L'ack parte SOLO dopo un persist riuscito: così il watch ritrasmette
    // al prossimo flush invece di perdere la sessione.
    expect(source.ackedKeys, isEmpty);
  });
}
