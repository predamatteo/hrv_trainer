@TestOn('vm')
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/features/training/state/training_controller.dart';
import 'package:hrv_trainer/shared/connect_iq/heart_rate_source.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';

class _FakeSource extends HeartRateSource {
  final hr = StreamController<HeartRateEvent>.broadcast();
  int stopCount = 0;

  @override
  Stream<HeartRateEvent> get heartRateStream => hr.stream;
  @override
  Future<void> start(
      {BreathingPattern? pattern, int? targetDurationSec, int? prepMs}) async {}
  @override
  Future<void> stop() async => stopCount++;
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
  test('nessun battito entro il timeout → sessione annullata (abortedNoData)',
      () {
    fakeAsync((async) {
      final source = _FakeSource();
      final container = ProviderContainer(overrides: [
        heartRateSourceProvider.overrideWithValue(source),
      ]);
      // Tiene vivo il provider autoDispose per tutta la durata del test.
      final keepAlive =
          container.listen(trainingControllerProvider, (_, __) {});

      final ctrl = container.read(trainingControllerProvider.notifier);
      ctrl.start(BreathingPattern.resonance6bpm, targetDurationSec: 1200);
      async.flushMicrotasks(); // completa `await src.start()` e arma i timer

      // Sessione avviata, ma in attesa del primo battito (startedAt null).
      expect(container.read(trainingControllerProvider).running, isTrue);

      // Nessun battito: oltre kWatchFirstSampleTimeout (35s) scatta l'abort.
      async.elapse(const Duration(seconds: 36));
      async.flushMicrotasks();

      final st = container.read(trainingControllerProvider);
      expect(st.abortedNoData, isTrue);
      expect(st.running, isFalse);
      expect(source.stopCount, greaterThanOrEqualTo(1)); // sorgente fermata

      keepAlive.close();
      container.dispose();
      source.hr.close();
    });
  });
}
