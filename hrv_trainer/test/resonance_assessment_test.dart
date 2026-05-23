import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';

HrvMetrics _m({
  required double p2t,
  required double lfPower,
  required double lfPeakHz,
  required double sdnn,
  int samples = 120,
}) {
  return HrvMetrics(
    sdnnMs: sdnn,
    rmssdMs: 40,
    pnn50Pct: 0,
    meanHrBpm: 60,
    peakToTroughMs: p2t,
    samples: samples,
    lfPeakHz: lfPeakHz,
    lfPower: lfPower,
    hfPeakHz: 0,
    hfPower: 0,
    totalPower: lfPower,
    lfHfRatio: 0,
    sd1Ms: 0,
    sd2Ms: 0,
    sd1Sd2Ratio: 0,
    hrvScore: 0,
    artifactsRemoved: 0,
    artifactsInterpolated: 0,
    percentArtifactual: 0,
  );
}

AssessmentStep _step(double bpm, HrvMetrics m) => AssessmentStep(
      bpm: bpm,
      duration: const Duration(seconds: 150),
      metrics: m,
      rrSamples: const [],
    );

void main() {
  group('ResonanceAssessment.analyze (scoring per ampiezza)', () {
    test('vince lo step con la massima ampiezza RSA coerente col respiro', () {
      // 6.0 bpm = 0.10 Hz: ampiezza picco-valle e LF nettamente maggiori,
      // picco spettrale allineato alla frequenza respiratoria.
      final steps = [
        _step(6.5, _m(p2t: 45, lfPower: 1200, lfPeakHz: 0.108, sdnn: 45)),
        _step(6.0, _m(p2t: 90, lfPower: 3000, lfPeakHz: 0.100, sdnn: 70)),
        _step(5.5, _m(p2t: 50, lfPower: 1500, lfPeakHz: 0.092, sdnn: 48)),
        _step(5.0, _m(p2t: 35, lfPower: 900, lfPeakHz: 0.083, sdnn: 38)),
        _step(4.5, _m(p2t: 30, lfPower: 700, lfPeakHz: 0.075, sdnn: 33)),
      ];
      final r = ResonanceAssessment.analyze(DateTime(2026, 5, 23), steps);
      expect(r.resonanceBpm, 6.0);
      expect(r.rationale, contains('90 ms')); // ampiezza picco-valle nel testo
    });

    test('un picco spettrale incoerente penalizza uno step ad alta ampiezza',
        () {
      // 5.5 bpm ha l'ampiezza grezza più alta MA il picco spettrale cade
      // lontano dalla frequenza respiratoria (0.13 Hz vs target 0.092):
      // l'oscillazione non è guidata dal respiro. 6.0 bpm, coerente, vince.
      final steps = [
        _step(6.0, _m(p2t: 80, lfPower: 2600, lfPeakHz: 0.100, sdnn: 65)),
        _step(5.5, _m(p2t: 88, lfPower: 2800, lfPeakHz: 0.130, sdnn: 68)),
      ];
      final r = ResonanceAssessment.analyze(DateTime(2026, 5, 23), steps);
      expect(r.resonanceBpm, 6.0);
    });

    test('a parità di ampiezza RSA, vince la potenza LF maggiore', () {
      // Stesso p2t/sdnn/coerenza: il vecchio scoring binario (LF presente/
      // assente) avrebbe pareggiato; ora la magnitudo LF rompe il pari.
      final steps = [
        _step(6.0, _m(p2t: 60, lfPower: 3000, lfPeakHz: 0.100, sdnn: 50)),
        _step(5.5, _m(p2t: 60, lfPower: 1000, lfPeakHz: 0.092, sdnn: 50)),
      ];
      final r = ResonanceAssessment.analyze(DateTime(2026, 5, 23), steps);
      expect(r.resonanceBpm, 6.0);
    });

    test('steps vuoti → nessuna frequenza', () {
      final r = ResonanceAssessment.analyze(DateTime(2026, 5, 23), const []);
      expect(r.resonanceBpm, isNull);
    });
  });
}
