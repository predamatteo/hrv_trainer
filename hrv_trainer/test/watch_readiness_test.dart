import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/connect_iq/bluetooth_state.dart';
import 'package:hrv_trainer/shared/connect_iq/heart_rate_source.dart';
import 'package:hrv_trainer/shared/connect_iq/hr_source_provider.dart';
import 'package:hrv_trainer/shared/connect_iq/watch_readiness.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';

/// Sorgente HR finta con stato fisso: ci serve solo `state` (il fallback usato
/// da watchReadinessProvider quando lo stream non ha ancora emesso) e stream
/// vuoti. Eredita i default concreti di HeartRateSource (reconnect, sync, ...).
class _FakeSource extends HeartRateSource {
  _FakeSource(this._state);
  final HrSourceState _state;

  @override
  String get displayName => 'fake';
  @override
  HrSourceState get state => _state;
  @override
  Stream<HrSourceState> get stateStream => const Stream.empty();
  @override
  Stream<HeartRateEvent> get heartRateStream => const Stream.empty();
  @override
  Future<void> start({
    BreathingPattern? pattern,
    int? targetDurationSec,
    int? prepMs,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<HrvOnDemandResult?> requestHrvOnDemand() async => null;
  @override
  void dispose() {}
}

Future<ProviderContainer> _container({
  required BluetoothAdapterState bt,
  required HrSourceState hr,
}) async {
  final c = ProviderContainer(
    overrides: [
      bluetoothAdapterStateProvider.overrideWith(
        (ref) => Stream<BluetoothAdapterState>.value(bt),
      ),
      heartRateSourceProvider.overrideWithValue(_FakeSource(hr)),
    ],
  );
  // Attendi che lo StreamProvider del BT abbia un valore concreto, così
  // watchReadinessProvider legge lo stato reale e non `loading`.
  await c.read(bluetoothAdapterStateProvider.future);
  return c;
}

void main() {
  group('watchReadinessProvider', () {
    test(
      'Bluetooth spento vince su tutto (anche se il link sarebbe connesso)',
      () async {
        final c = await _container(
          bt: BluetoothAdapterState.off,
          hr: HrSourceState.connected,
        );
        addTearDown(c.dispose);
        expect(c.read(watchReadinessProvider), WatchReadiness.bluetoothOff);
      },
    );

    test('turningOff è trattato come spento', () async {
      final c = await _container(
        bt: BluetoothAdapterState.turningOff,
        hr: HrSourceState.connected,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.bluetoothOff);
    });

    test('BT acceso + link connesso → ready', () async {
      final c = await _container(
        bt: BluetoothAdapterState.on,
        hr: HrSourceState.connected,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.ready);
      expect(c.read(watchReadinessProvider).canStart, isTrue);
    });

    test('BT acceso + disconnesso → disconnected', () async {
      final c = await _container(
        bt: BluetoothAdapterState.on,
        hr: HrSourceState.disconnected,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.disconnected);
      expect(c.read(watchReadinessProvider).canStart, isFalse);
    });

    test('BT acceso + nessun device → noDevice', () async {
      final c = await _container(
        bt: BluetoothAdapterState.on,
        hr: HrSourceState.noDevice,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.noDevice);
    });

    test('BT acceso + errore SDK → error', () async {
      final c = await _container(
        bt: BluetoothAdapterState.on,
        hr: HrSourceState.error,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.error);
    });

    test('BT in stato ambiguo (unknown) NON è trattato come spento', () async {
      // Permesso BLE non concesso al plugin o piattaforma senza valore certo:
      // ci si fida dello stato Garmin, qui connesso → ready.
      final c = await _container(
        bt: BluetoothAdapterState.unknown,
        hr: HrSourceState.connected,
      );
      addTearDown(c.dispose);
      expect(c.read(watchReadinessProvider), WatchReadiness.ready);
    });
  });
}
