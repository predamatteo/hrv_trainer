@TestOn('vm')
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/features/readiness/state/morning_checkin_controller.dart';
import 'package:hrv_trainer/shared/connect_iq/heart_rate_source.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';

/// F3: quando il flusso di battiti si ferma durante una cattura, oltre al
/// banner "Connessione persa" il controller tenta UN reconnect() (che lato
/// nativo ri-registra il listener app-event caduto), senza scatenare un
/// reconnect storm se il link resta muto.
class _FakeSource extends HeartRateSource {
  final hr = StreamController<HeartRateEvent>.broadcast();
  int reconnectCount = 0;

  @override
  Stream<HeartRateEvent> get heartRateStream => hr.stream;
  @override
  Future<void> start(
      {BreathingPattern? pattern, int? targetDurationSec, int? prepMs}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> reconnect() async => reconnectCount++;
  @override
  String get displayName => 'fake';
  @override
  HrSourceState get state => HrSourceState.connected;
  @override
  Stream<HrSourceState> get stateStream => const Stream.empty();
  @override
  Future<HrvOnDemandResult?> requestHrvOnDemand() async => null;
  @override
  void dispose() {}
}

void main() {
  test('stallo del flusso → connectionLost + un solo reconnect (self-heal)', () {
    fakeAsync((async) {
      final source = _FakeSource();
      final container = ProviderContainer(overrides: [
        heartRateSourceProvider.overrideWithValue(source),
      ]);
      // Tiene vivo il provider autoDispose per tutta la durata del test.
      final keepAlive =
          container.listen(morningCheckInControllerProvider, (_, _) {});

      final ctrl = container.read(morningCheckInControllerProvider.notifier);
      ctrl.start();
      async.flushMicrotasks(); // completa `await src.start()` e arma i timer

      // Primo battito: la misura parte, il watchdog dello stale si arma.
      source.hr
          .add(HeartRateEvent(timestamp: DateTime.now(), bpm: 60, rrMs: 1000));
      async.flushMicrotasks();
      expect(
        container.read(morningCheckInControllerProvider).connectionLost,
        isFalse,
      );

      // Nessun altro battito: oltre kWatchStaleDataTimeout (12s) scatta il
      // banner + il tentativo di auto-recupero.
      async.elapse(const Duration(seconds: 13));
      async.flushMicrotasks();
      final st = container.read(morningCheckInControllerProvider);
      expect(st.connectionLost, isTrue);
      expect(source.reconnectCount, 1);

      // Link ancora muto: nessun reconnect storm.
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(source.reconnectCount, 1);

      keepAlive.close();
      container.dispose();
      source.hr.close();
    });
  });

  test('la ripresa dei battiti riabilita il self-heal per uno stallo futuro',
      () {
    fakeAsync((async) {
      final source = _FakeSource();
      final container = ProviderContainer(overrides: [
        heartRateSourceProvider.overrideWithValue(source),
      ]);
      final keepAlive =
          container.listen(morningCheckInControllerProvider, (_, _) {});
      final ctrl = container.read(morningCheckInControllerProvider.notifier);
      ctrl.start();
      async.flushMicrotasks();

      source.hr
          .add(HeartRateEvent(timestamp: DateTime.now(), bpm: 61, rrMs: 980));
      async.flushMicrotasks();

      // Primo stallo → 1 reconnect.
      async.elapse(const Duration(seconds: 13));
      async.flushMicrotasks();
      expect(source.reconnectCount, 1);

      // I battiti riprendono (link recuperato): azzera connectionLost e
      // ri-abilita l'auto-recupero.
      source.hr
          .add(HeartRateEvent(timestamp: DateTime.now(), bpm: 62, rrMs: 970));
      async.flushMicrotasks();
      expect(
        container.read(morningCheckInControllerProvider).connectionLost,
        isFalse,
      );

      // Secondo stallo → un ALTRO reconnect (il guard è stato riarmato).
      async.elapse(const Duration(seconds: 13));
      async.flushMicrotasks();
      expect(source.reconnectCount, 2);

      keepAlive.close();
      container.dispose();
      source.hr.close();
    });
  });
}
