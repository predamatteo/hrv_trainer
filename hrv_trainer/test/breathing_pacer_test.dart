import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';

/// Periodo intero in ms come lo ricostruisce il watch da START_SESSION
/// (garmin_ciq_source invia ogni durata come `(durataSec*1000).round()`).
int watchPeriodMs(BreathingPattern p) =>
    (p.inhaleSec * 1000).round() +
    (p.hold1Sec * 1000).round() +
    (p.exhaleSec * 1000).round() +
    (p.hold2Sec * 1000).round();

void main() {
  group('BreathingPattern.snappedToMs', () {
    test('è un no-op sui pattern già interi (default 6 bpm)', () {
      final p = BreathingPattern.resonance6bpm.snappedToMs();
      expect(p.inhaleSec, 4.0);
      expect(p.exhaleSec, 6.0);
      expect(p.periodSec, 10.0);
    });

    test('allinea il periodo dell\'orb a quello intero inviato al watch', () {
      final raw = BreathingPattern.fromBpm(5.5); // ritmo non intero
      final snapped = raw.snappedToMs();

      // Lo snap non cambia ciò che riceve il watch (sono gli stessi ms round()).
      expect(watchPeriodMs(snapped), watchPeriodMs(raw));

      // Dopo lo snap il periodo dell'orb coincide ESATTAMENTE col periodo intero
      // del watch: niente scivolamento di fase ciclo dopo ciclo.
      expect((snapped.periodSec * 1000).round(), watchPeriodMs(snapped));
      expect(snapped.periodSec * 1000, closeTo(watchPeriodMs(snapped), 1e-6));

      // Le durate snappate sono ms interi.
      expect(snapped.inhaleSec * 1000, closeTo((raw.inhaleSec * 1000).round(), 1e-6));
      expect(snapped.exhaleSec * 1000, closeTo((raw.exhaleSec * 1000).round(), 1e-6));
    });

    test('prima dello snap il periodo double differisce da quello del watch', () {
      // Documenta la causa: su 5.5 bpm il periodo double dell\'orb non è intero.
      final raw = BreathingPattern.fromBpm(5.5);
      final orbPeriodMs = raw.periodSec * 1000;
      // Differenza sub-ms che, moltiplicata per ~110 cicli su 20 min, dava il
      // residuo di drift (~100ms) corretto dallo snap.
      expect((orbPeriodMs - watchPeriodMs(raw)).abs(), greaterThan(0.0));
      expect((orbPeriodMs - watchPeriodMs(raw)).abs(), lessThan(1.0));
    });
  });
}
