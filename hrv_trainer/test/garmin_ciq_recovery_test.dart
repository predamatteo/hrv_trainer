@TestOn('vm')
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/connect_iq/garmin_ciq_source.dart';
import 'package:hrv_trainer/shared/connect_iq/heart_rate_source.dart';

/// Recupero della connessione in GarminCiqSource (bug "grafico bloccato +
/// Connessione persa" / retry incastrato su "Connessione…"):
///  - F1: un HR_SAMPLE è prova di link vivo → promuove _state a `connected`
///        (guardato on-change, SOLO su HR_SAMPLE).
///  - F2: `connecting` non è più uno stato assorbente: senza eventi risolutivi
///        un watchdog lo retrocede a `disconnected` (riabilita "Riconnetti").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('dev.hrv/garmin_ciq');
  const eventName = 'dev.hrv/garmin_ciq_events';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(method, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
  });

  // Simula un evento watch→phone sull'EventChannel.
  void inject(Map<String, Object?> payload) {
    messenger.handlePlatformMessage(
        eventName, codec.encodeSuccessEnvelope(payload), (_) {});
  }

  test('F1: un HR_SAMPLE promuove connecting → connected (una sola volta)', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      final emitted = <HrSourceState>[];
      src.stateStream.listen(emitted.add);
      async.flushMicrotasks();

      src.start(); // → connecting
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connecting);

      inject({'type': 'HR_SAMPLE', 'bpm': 62, 'rr': 950});
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connected);

      // Secondo battito: guardia on-change → niente secondo evento `connected`
      // (altrimenti watchReadinessProvider si ricostruirebbe ad ogni battito).
      inject({'type': 'HR_SAMPLE', 'bpm': 63, 'rr': 940});
      async.flushMicrotasks();

      expect(
        emitted.where((s) => s == HrSourceState.connected).length,
        1,
      );
      src.dispose();
    });
  });

  test('F1 (scope): HRV_RESULT/SESSION_SUMMARY NON promuovono da connecting', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.start(); // → connecting
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connecting);

      // Artefatti drenabili dal PendingStore a link NON vivo: non devono
      // fabbricare prontezza.
      inject({
        'type': 'HRV_RESULT',
        'reqId': 99,
        't': 1000,
        'rmssd': 40,
        'sdnn': 55,
        'rr': [900, 910, 905],
      });
      async.flushMicrotasks();
      inject({'type': 'SESSION_SUMMARY', 'startMs': 1000, 'endMs': 2000});
      async.flushMicrotasks();

      expect(src.state, HrSourceState.connecting);
      src.dispose();
    });
  });

  test('F2: connecting senza eventi → disconnected dopo il watchdog', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.reconnect(); // → connecting
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connecting);

      // Prima del timeout resta connecting…
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connecting);

      // …oltre il timeout (40s) retrocede, sbloccando il gate ("Riconnetti").
      async.elapse(const Duration(seconds: 11));
      async.flushMicrotasks();
      expect(src.state, HrSourceState.disconnected);
      src.dispose();
    });
  });

  test('F2: un HR_SAMPLE prima del timeout annulla il watchdog (no demozione)',
      () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.start(); // → connecting
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 5));
      inject({'type': 'HR_SAMPLE', 'bpm': 60, 'rr': 1000}); // → connected
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connected);

      // Ben oltre il timeout: una sessione che streamma NON deve essere
      // retrocessa solo perché lo STATE:ACTIVE una-tantum era andato perso.
      async.elapse(const Duration(seconds: 50));
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connected);
      src.dispose();
    });
  });

  test('F2: uno STATE risolutivo prima del timeout annulla il watchdog', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.reconnect(); // → connecting
      async.flushMicrotasks();

      inject({'type': 'STATE', 'v': 'DEVICE_CONNECTED'});
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connected);

      async.elapse(const Duration(seconds: 50));
      async.flushMicrotasks();
      expect(src.state, HrSourceState.connected);
      src.dispose();
    });
  });
}
