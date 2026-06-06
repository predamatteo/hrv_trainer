import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/hrv_trend.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';

// NB: HrvTrendCalculator usa DateTime.now() per le età, quindi le fixture sono
// costruite relative a now reale. Le finestre (recente <14gg, precedente
// 14..42gg) sono ben separate dai valori scelti, così i test restano robusti.
Session _m(DateTime when, double rmssd) => Session(
      kind: SessionKind.reading,
      tag: SessionTag.morning,
      startedAt: when,
      endedAt: when.add(const Duration(minutes: 3)),
      pattern: BreathingPattern.resonance6bpm,
      metrics: HrvMetrics(
        sdnnMs: 0,
        rmssdMs: rmssd,
        pnn50Pct: 0,
        meanHrBpm: 60,
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

void main() {
  final now = DateTime.now();

  group('HrvTrendCalculator', () {
    test('nessuna lettura → empty, niente livello', () {
      final s = HrvTrendCalculator.fromMornings([]);
      expect(s.hasLevel, false);
      expect(s.direction, HrvTrendDirection.unknown);
      expect(s.deltaPct, isNull);
    });

    test('livello = media RMSSD recente; score da scoreFromRmssd', () {
      final hist = [
        _m(now.subtract(const Duration(days: 1)), 50),
        _m(now.subtract(const Duration(days: 3)), 60),
        _m(now.subtract(const Duration(days: 5)), 55),
      ];
      final s = HrvTrendCalculator.fromMornings(hist);
      expect(s.hasLevel, true);
      expect(s.levelRmssd!, closeTo(55, 1e-9)); // (50+60+55)/3
      expect(s.levelScore!, closeTo(HrvMetrics.scoreFromRmssd(55), 1e-9));
    });

    test('poche letture (no finestra precedente) → direzione unknown ma livello presente', () {
      final hist = [
        _m(now.subtract(const Duration(days: 1)), 50),
        _m(now.subtract(const Duration(days: 3)), 52),
      ];
      final s = HrvTrendCalculator.fromMornings(hist);
      expect(s.hasLevel, true);
      expect(s.direction, HrvTrendDirection.unknown);
      expect(s.deltaPct, isNull);
    });

    test('recente più alto del precedente → improving, delta% > 0', () {
      final hist = <Session>[
        // recente (alta HRV), età 1..5 gg
        _m(now.subtract(const Duration(days: 1)), 56),
        _m(now.subtract(const Duration(days: 3)), 58),
        _m(now.subtract(const Duration(days: 5)), 54),
        // precedente (bassa HRV), età 21..30 gg
        _m(now.subtract(const Duration(days: 21)), 40),
        _m(now.subtract(const Duration(days: 24)), 41),
        _m(now.subtract(const Duration(days: 27)), 39),
        _m(now.subtract(const Duration(days: 30)), 40),
      ];
      final s = HrvTrendCalculator.fromMornings(hist);
      expect(s.direction, HrvTrendDirection.improving);
      expect(s.deltaPct, isNotNull);
      expect(s.deltaPct!, greaterThan(0));
      expect(s.cvPct, isNotNull); // 3 letture negli ultimi 7gg
      expect(s.spanWeeks, isNotNull);
    });

    test('recente più basso del precedente → declining, delta% < 0', () {
      final hist = <Session>[
        _m(now.subtract(const Duration(days: 1)), 40),
        _m(now.subtract(const Duration(days: 3)), 41),
        _m(now.subtract(const Duration(days: 5)), 39),
        _m(now.subtract(const Duration(days: 21)), 56),
        _m(now.subtract(const Duration(days: 24)), 58),
        _m(now.subtract(const Duration(days: 27)), 54),
        _m(now.subtract(const Duration(days: 30)), 57),
      ];
      final s = HrvTrendCalculator.fromMornings(hist);
      expect(s.direction, HrvTrendDirection.declining);
      expect(s.deltaPct!, lessThan(0));
    });

    test('medie simili (entro SWC) → stable', () {
      final hist = <Session>[
        _m(now.subtract(const Duration(days: 1)), 48),
        _m(now.subtract(const Duration(days: 3)), 50),
        _m(now.subtract(const Duration(days: 5)), 52),
        _m(now.subtract(const Duration(days: 21)), 44),
        _m(now.subtract(const Duration(days: 24)), 48),
        _m(now.subtract(const Duration(days: 27)), 50),
        _m(now.subtract(const Duration(days: 30)), 52),
        _m(now.subtract(const Duration(days: 33)), 56),
      ];
      final s = HrvTrendCalculator.fromMornings(hist);
      expect(s.direction, HrvTrendDirection.stable);
    });
  });
}
