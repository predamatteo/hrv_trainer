import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/readiness.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';

Session _morning(DateTime when, double rmssd, double hr) {
  return Session(
    kind: SessionKind.reading,
    tag: SessionTag.morning,
    startedAt: when,
    endedAt: when.add(const Duration(minutes: 3)),
    pattern: BreathingPattern.resonance6bpm,
    metrics: HrvMetrics(
      sdnnMs: 0,
      rmssdMs: rmssd,
      pnn50Pct: 0,
      meanHrBpm: hr,
      peakToTroughMs: 0,
      samples: 100,
      lfPeakHz: 0,
      lfPower: 0,
      hfPeakHz: 0,
      hfPower: 0,
      totalPower: 0,
      lfHfRatio: 0,
      sd1Ms: 0,
      sd2Ms: 0,
      sd1Sd2Ratio: 0,
      hrvScore: 0,
      artifactsRemoved: 0,
      artifactsInterpolated: 0,
      percentArtifactual: 0,
    ),
  );
}

void main() {
  group('ReadinessCalculator', () {
    test('unknown se nessuna morning reading', () {
      final r = ReadinessCalculator.fromHistory([]);
      expect(r.band, ReadinessBand.unknown);
    });

    test('baseline in costruzione se meno di 3 letture precedenti', () {
      final now = DateTime(2026, 4, 22);
      final hist = [
        _morning(now, 40, 60),
        _morning(now.subtract(const Duration(days: 1)), 42, 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.band, ReadinessBand.unknown);
      expect(r.baselineDays, 1);
    });

    test('green se RMSSD in linea col baseline (z > -0.5)', () {
      final now = DateTime(2026, 4, 22);
      final hist = <Session>[
        _morning(now, 42, 60), // oggi
        for (var i = 1; i <= 7; i++)
          _morning(now.subtract(Duration(days: i)), 40 + (i % 3), 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.band, ReadinessBand.green);
    });

    test('red se RMSSD drammaticamente sotto baseline', () {
      final now = DateTime(2026, 4, 22);
      final hist = <Session>[
        _morning(now, 15, 75), // oggi: tonfo + HR su
        for (var i = 1; i <= 7; i++)
          _morning(now.subtract(Duration(days: i)), 40 + (i % 3), 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.band, ReadinessBand.red);
      expect(r.direction, AutonomicDirection.sympatheticHigh);
    });

    test('yellow se RMSSD giù ma HR normale -> parasimpatico basso', () {
      final now = DateTime(2026, 4, 22);
      // Baseline con variabilità realistica (sd ~8 ms).
      final baselineRmssd = [55, 40, 48, 38, 52, 42, 50];
      final hist = <Session>[
        _morning(now, 39, 60), // RMSSD a ~-1.2σ, HR invariato
        for (var i = 1; i <= 7; i++)
          _morning(now.subtract(Duration(days: i)),
              baselineRmssd[i - 1].toDouble(), 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.band, ReadinessBand.yellow);
      expect(r.direction, AutonomicDirection.parasympatheticLow);
    });
  });

  group('CV(lnRMSSD)', () {
    test('serie stabile → CV basso, stabilità "stable"', () {
      final now = DateTime(2026, 4, 22);
      final flat = [40, 41, 40, 42, 40, 41, 40];
      final hist = <Session>[
        for (var i = 0; i < flat.length; i++)
          _morning(now.subtract(Duration(days: i)), flat[i].toDouble(), 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.cvPct, isNotNull);
      expect(r.cvPct!, lessThan(5));
      expect(r.cvStability, CvStability.stable);
    });

    test('serie molto oscillante → CV alto, stabilità "unstable"', () {
      final now = DateTime(2026, 4, 22);
      final swing = [80, 20, 75, 22, 70, 25, 78];
      final hist = <Session>[
        for (var i = 0; i < swing.length; i++)
          _morning(now.subtract(Duration(days: i)), swing[i].toDouble(), 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.cvPct, isNotNull);
      expect(r.cvPct!, greaterThan(10));
      expect(r.cvStability, CvStability.unstable);
    });

    test('CV disponibile già con 3 letture, prima della readiness piena', () {
      final now = DateTime(2026, 4, 22);
      final hist = <Session>[
        _morning(now, 40, 60),
        _morning(now.subtract(const Duration(days: 1)), 44, 60),
        _morning(now.subtract(const Duration(days: 2)), 42, 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      // baseline (2 letture) insufficiente → banda unknown...
      expect(r.band, ReadinessBand.unknown);
      // ...ma il CV è già calcolabile sulle 3 letture.
      expect(r.cvPct, isNotNull);
    });

    test('nessun CV con meno di 3 letture', () {
      final now = DateTime(2026, 4, 22);
      final hist = <Session>[
        _morning(now, 40, 60),
        _morning(now.subtract(const Duration(days: 1)), 42, 60),
      ];
      final r = ReadinessCalculator.fromHistory(hist);
      expect(r.cvPct, isNull);
      expect(r.cvStability, CvStability.unknown);
    });
  });
}
