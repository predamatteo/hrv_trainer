import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/dashboard_stats.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/morning_reading.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';

HrvMetrics _metrics({double rmssd = 50, double coherence = 0}) => HrvMetrics(
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
      coherenceRatio: coherence,
    );

Session _s({
  required SessionKind kind,
  required SessionTag tag,
  required DateTime when,
  double rmssd = 50,
  double coherence = 0,
  int? id,
  MorningMeta? morning,
}) =>
    Session(
      id: id,
      kind: kind,
      tag: tag,
      startedAt: when,
      endedAt: when.add(const Duration(minutes: 5)),
      pattern: BreathingPattern.resonance6bpm,
      metrics: _metrics(rmssd: rmssd, coherence: coherence),
      morning: morning,
    );

MorningMeta _meta({
  bool alcohol = false,
  bool illness = false,
  bool stressed = false,
  bool soreness = false,
  SleepQuality sleep = SleepQuality.good,
}) =>
    MorningMeta(
      posture: Posture.seated,
      protocol: MorningProtocol.seated60,
      context: MorningContext(
        sleep: sleep,
        alcohol: alcohol,
        illness: illness,
        stressed: stressed,
        soreness: soreness,
      ),
    );

void main() {
  final now = DateTime.now();

  group('DashboardStats.coherenceTrend', () {
    test('include solo training con coherence>0, ordinato vecchie→recenti', () {
      final list = [
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now.subtract(const Duration(days: 2)), coherence: 2.0, id: 1),
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now.subtract(const Duration(days: 5)), coherence: 1.0, id: 2),
        // coherence 0 → escluso
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now.subtract(const Duration(days: 1)), coherence: 0, id: 3),
        // non training → escluso anche se coherence alta
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 3)), coherence: 5.0, id: 4),
      ];
      final pts = DashboardStats.coherenceTrend(list);
      expect(pts.length, 2);
      expect(pts.first.sessionId, 2); // 5gg fa
      expect(pts.last.sessionId, 1); // 2gg fa
      expect(pts.last.coherence, 2.0);
    });

    test('lista vuota → []', () {
      expect(DashboardStats.coherenceTrend([]), isEmpty);
    });
  });

  group('DashboardStats.rollingMean', () {
    test('finestra 2', () {
      expect(DashboardStats.rollingMean([1, 2, 3], 2), [1.0, 1.5, 2.5]);
    });
    test('finestra più grande dei dati = media cumulativa', () {
      expect(DashboardStats.rollingMean([2, 4, 6], 5), [2.0, 3.0, 4.0]);
    });
  });

  group('DashboardStats.rmssdByTag', () {
    test('media per tag, solo tag con >= minSamples, in ordine enum', () {
      final list = [
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now, rmssd: 40),
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now, rmssd: 60),
        // morning una sola → esclusa (sotto minSamples)
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now, rmssd: 70),
        _s(kind: SessionKind.training, tag: SessionTag.postWorkout, when: now, rmssd: 20),
        _s(kind: SessionKind.training, tag: SessionTag.postWorkout, when: now, rmssd: 30),
      ];
      final stats = DashboardStats.rmssdByTag(list);
      expect(stats.length, 2);
      // ordine enum: postWorkout prima di general
      expect(stats.first.tag, SessionTag.postWorkout);
      expect(stats.last.tag, SessionTag.general);
      expect(stats.firstWhere((s) => s.tag == SessionTag.general).meanRmssd,
          closeTo(50, 1e-9));
      expect(stats.firstWhere((s) => s.tag == SessionTag.postWorkout).meanRmssd,
          closeTo(25, 1e-9));
    });

    test('RMSSD <= 0 esclusi dal calcolo', () {
      final list = [
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now, rmssd: 0),
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now, rmssd: 50),
      ];
      // un solo valore valido → sotto minSamples → niente entry
      expect(DashboardStats.rmssdByTag(list), isEmpty);
    });
  });

  group('DashboardStats.habitImpact', () {
    test('delta% vs baseline mattine pulite, solo fattori con >= minSamples', () {
      final list = [
        // baseline pulita (sonno buono, nessun flag): media 50
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 1)), rmssd: 50, morning: _meta()),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 2)), rmssd: 50, morning: _meta()),
        // alcol: media 40 → -20%
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 3)), rmssd: 40, morning: _meta(alcohol: true)),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 4)), rmssd: 40, morning: _meta(alcohol: true)),
        // malattia una sola → esclusa
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 5)), rmssd: 30, morning: _meta(illness: true)),
        // non-morning ignorata
        _s(kind: SessionKind.training, tag: SessionTag.general, when: now, rmssd: 99),
      ];
      final res = DashboardStats.habitImpact(list);
      expect(res.hasData, true);
      expect(res.cleanBaseline, closeTo(50, 1e-9));
      expect(res.cleanCount, 2);
      expect(res.impacts.length, 1);
      final a = res.impacts.single;
      expect(a.label, 'Alcol');
      expect(a.count, 2);
      expect(a.meanRmssd, closeTo(40, 1e-9));
      expect(a.deltaPct, closeTo(-20, 1e-9));
    });

    test('sonno scarso conta come fattore (hasFlags)', () {
      final list = [
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 1)), rmssd: 60, morning: _meta()),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 2)), rmssd: 60, morning: _meta()),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 3)), rmssd: 48, morning: _meta(sleep: SleepQuality.poor)),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 4)), rmssd: 48, morning: _meta(sleep: SleepQuality.poor)),
      ];
      final res = DashboardStats.habitImpact(list);
      expect(res.cleanBaseline, closeTo(60, 1e-9));
      final s = res.impacts.single;
      expect(s.label, 'Sonno scarso');
      expect(s.deltaPct, closeTo(-20, 1e-9));
    });

    test('niente baseline pulita → hasData false', () {
      final list = [
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 1)), rmssd: 40, morning: _meta(alcohol: true)),
        _s(kind: SessionKind.reading, tag: SessionTag.morning, when: now.subtract(const Duration(days: 2)), rmssd: 40, morning: _meta(alcohol: true)),
      ];
      expect(DashboardStats.habitImpact(list).hasData, false);
    });

    test('nessuna mattina → empty', () {
      expect(DashboardStats.habitImpact([]).hasData, false);
    });
  });
}
