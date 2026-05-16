import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../hrv/breathing_pacer.dart';
import 'garmin_ciq_source.dart';
import 'heart_rate_source.dart';
import 'mock_hr_source.dart';

enum HrBackend { mock, garminCiq }

/// Default: [HrBackend.garminCiq]. Lato Android, il bridge nativo
/// (GarminCiqBridge.kt) rileva automaticamente se il Connect IQ Mobile SDK
/// è presente e ricade internamente su un simulatore se manca; non serve
/// quindi selezionare `mock` dall'app per sviluppare senza hardware.
final hrBackendProvider =
    StateProvider<HrBackend>((ref) => HrBackend.garminCiq);

/// Pattern respiratorio corrente (usato dal mock per modulare la RSA).
final currentPatternProvider =
    StateProvider<BreathingPattern>((ref) => BreathingPattern.resonance6bpm);

final heartRateSourceProvider = Provider<HeartRateSource>((ref) {
  final backend = ref.watch(hrBackendProvider);
  late HeartRateSource src;
  switch (backend) {
    case HrBackend.mock:
      src = MockHeartRateSource(
        breathingPatternProvider: () => ref.read(currentPatternProvider),
      );
    case HrBackend.garminCiq:
      src = GarminCiqSource();
  }
  ref.onDispose(src.dispose);
  return src;
});

final hrSourceStateProvider = StreamProvider<HrSourceState>((ref) {
  final src = ref.watch(heartRateSourceProvider);
  return src.stateStream;
});

final heartRateStreamProvider = StreamProvider<HeartRateEvent>((ref) {
  final src = ref.watch(heartRateSourceProvider);
  return src.heartRateStream;
});
