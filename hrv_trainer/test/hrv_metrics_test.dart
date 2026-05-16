import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/rr_interval.dart';

void main() {
  group('HrvCalculator', () {
    test('ritorna empty se troppi pochi campioni', () {
      final rr = List.generate(
          5,
          (i) => RrInterval(
              timestamp: DateTime(2020).add(Duration(seconds: i)),
              ms: 900));
      expect(HrvCalculator.compute(rr).samples, 0);
    });

    test('RR costante ha SDNN e RMSSD ~= 0', () {
      final rr = List.generate(
          50,
          (i) => RrInterval(
              timestamp:
                  DateTime(2020).add(Duration(milliseconds: i * 900)),
              ms: 900));
      final m = HrvCalculator.compute(rr);
      expect(m.sdnnMs, lessThan(1));
      expect(m.rmssdMs, lessThan(1));
      expect(m.meanHrBpm, closeTo(66.7, 0.5));
      expect(m.hrvScore, 0.0); // RMSSD=0 => score=0
    });

    test('rileva frequenza dominante ~0.1 Hz su segnale sinusoidale', () {
      // Simula RSA: RR = 900 + 80*sin(2*pi*0.1*t)
      final rr = <RrInterval>[];
      var t = 0.0;
      final start = DateTime(2020);
      while (t < 120) {
        final ms = 900 + 80 * math.sin(2 * math.pi * 0.1 * t);
        rr.add(RrInterval(
          timestamp: start.add(Duration(milliseconds: (t * 1000).round())),
          ms: ms.round(),
        ));
        t += ms / 1000.0;
      }
      final m = HrvCalculator.compute(rr);
      expect(m.sdnnMs, greaterThan(40));
      expect(m.lfPeakHz, closeTo(0.1, 0.02));
      expect(m.totalPower, greaterThan(0));
    });

    test('HRV score formula: 15.385 * ln(RMSSD)', () {
      // RR che produce RMSSD ~= 34 ms (valore tipico adulto): alternato.
      final rr = <RrInterval>[];
      for (var i = 0; i < 60; i++) {
        final even = i.isEven;
        rr.add(RrInterval(
          timestamp:
              DateTime(2020).add(Duration(milliseconds: i * 900)),
          ms: even ? 900 : 924,
        ));
      }
      final m = HrvCalculator.compute(rr);
      // RMSSD dovrebbe essere ~24 ms (differenza fissa 24 ms)
      expect(m.rmssdMs, closeTo(24, 1));
      // Score = 15.385 * ln(24) ≈ 48.9
      expect(m.hrvScore, closeTo(48.9, 1));
    });

    test('Poincaré SD1/SD2 relazione con RMSSD/SDNN', () {
      final rr = <RrInterval>[];
      final rng = math.Random(42);
      for (var i = 0; i < 100; i++) {
        final noise = (rng.nextDouble() - 0.5) * 60;
        rr.add(RrInterval(
          timestamp:
              DateTime(2020).add(Duration(milliseconds: i * 900)),
          ms: (900 + noise).round(),
        ));
      }
      final m = HrvCalculator.compute(rr);
      // SD1 = RMSSD / sqrt(2)
      expect(m.sd1Ms, closeTo(m.rmssdMs / math.sqrt2, 0.1));
      expect(m.sd2Ms, greaterThan(0));
    });

    test('artifact correction: burst di 3 outliers viene rimosso', () {
      final rr = <RrInterval>[];
      for (var i = 0; i < 50; i++) {
        final ms = i >= 20 && i < 23 ? 400 : 900; // burst artefatto
        rr.add(RrInterval(
          timestamp:
              DateTime(2020).add(Duration(milliseconds: i * 900)),
          ms: ms,
        ));
      }
      final m = HrvCalculator.compute(rr);
      expect(m.artifactsRemoved, greaterThanOrEqualTo(2));
      expect(m.percentArtifactual, greaterThan(0));
    });

    test('artifact correction: gap singolo viene interpolato', () {
      final rr = <RrInterval>[];
      for (var i = 0; i < 50; i++) {
        final ms = i == 25 ? 1400 : 900; // singolo outlier
        rr.add(RrInterval(
          timestamp:
              DateTime(2020).add(Duration(milliseconds: i * 900)),
          ms: ms,
        ));
      }
      final m = HrvCalculator.compute(rr);
      expect(m.artifactsInterpolated, greaterThanOrEqualTo(1));
    });
  });
}
