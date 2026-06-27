@TestOn('vm')
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/connect_iq/garmin_ciq_source.dart';

/// Verifica la macchina di stop di GarminCiqSource (la parte piu' delicata del
/// bridge BT): stop "leggero" -> ack STATE(stopped) entro 3s, altrimenti
/// fallback forceStop; saltato se nel frattempo parte una nuova sessione.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('dev.hrv/garmin_ciq');
  const eventName = 'dev.hrv/garmin_ciq_events';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;
  late Set<String> throwOn;

  setUp(() {
    calls = [];
    throwOn = {};
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call.method);
      if (throwOn.contains(call.method)) {
        throw PlatformException(code: 'err');
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
  });

  // Simula l'arrivo dal watch di uno STATE READY(stopped:true) sull'EventChannel.
  void injectStopAck() {
    final data = codec.encodeSuccessEnvelope(
        {'type': 'STATE', 'v': 'READY', 'stopped': true});
    messenger.handlePlatformMessage(eventName, data, (_) {});
  }

  test('ack STATE stopped entro 3s -> forceStop NON chiamato', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.stop(); // arma ack1 PRIMA dell'await su invokeMethod('stop')
      async.flushMicrotasks();
      injectStopAck();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();

      expect(calls, contains('stop'));
      expect(calls, isNot(contains('forceStop')));
      src.dispose();
    });
  });

  test('nessun ack -> forceStop chiamato dopo il timeout di 3s', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.stop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4)); // oltre i 3s
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6)); // drena anche ack2 (5s)
      async.flushMicrotasks();

      expect(calls, contains('stop'));
      expect(calls, contains('forceStop'));
      src.dispose();
    });
  });

  test('PlatformException su stop -> il fallback forceStop procede comunque',
      () {
    fakeAsync((async) {
      throwOn = {'stop'};
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.stop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();

      expect(calls, contains('forceStop'));
      src.dispose();
    });
  });

  test('un nuovo start durante l\'attesa dell\'ack salta il forceStop', () {
    fakeAsync((async) {
      final src = GarminCiqSource();
      async.flushMicrotasks();
      src.stop(); // myGen = N
      async.flushMicrotasks();
      src.start(); // bumpa _opGen -> N+1, quindi myGen != _opGen
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4)); // ack1 scade
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();

      expect(calls, contains('start'));
      expect(calls, isNot(contains('forceStop')));
      src.dispose();
    });
  });
}
