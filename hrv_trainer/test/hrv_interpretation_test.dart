import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/hrv/breathing_pacer.dart';
import 'package:hrv_trainer/shared/hrv/hrv_interpretation.dart';
import 'package:hrv_trainer/shared/hrv/hrv_metrics.dart';
import 'package:hrv_trainer/shared/hrv/rr_interval.dart';
import 'package:hrv_trainer/shared/hrv/session_models.dart';

List<RrInterval> _synth({
  required int seconds,
  required double meanMs,
  required double rsaAmpMs,
  required double rsaFreqHz,
  double driftMsPerSec = 0,
  double noiseMs = 0,
  int seed = 1,
}) {
  final rng = math.Random(seed);
  final start = DateTime(2026);
  final out = <RrInterval>[];
  var t = 0.0;
  while (t < seconds) {
    final rsa = rsaAmpMs * math.sin(2 * math.pi * rsaFreqHz * t);
    final drift = driftMsPerSec * t;
    final noise = (rng.nextDouble() - 0.5) * 2 * noiseMs;
    final ms = (meanMs + rsa + drift + noise).round().clamp(400, 1500);
    out.add(RrInterval(
      timestamp: start.add(Duration(milliseconds: (t * 1000).round())),
      ms: ms,
    ));
    t += ms / 1000.0;
  }
  return out;
}

void main() {
  group('interpretTachogram', () {
    test('grande RSA + drift in calo → headline eccellente', () {
      final rr = _synth(
        seconds: 180,
        meanMs: 950,
        rsaAmpMs: 80,
        rsaFreqHz: 0.1,
        driftMsPerSec: 0.2, // RR cresce → bpm cala
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
      );
      expect(i.level, InsightLevel.excellent);
      expect(i.headline.toLowerCase(), contains('rsa'));
      expect(i.body.toLowerCase(), contains('aritmia sinusale'));
    });

    test('RSA piatta → headline scarso e body parla di tracciato piatto', () {
      final rr = _synth(
        seconds: 120,
        meanMs: 800,
        rsaAmpMs: 3,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
      );
      expect(i.level, anyOf(InsightLevel.poor, InsightLevel.fair));
      expect(i.body.toLowerCase(), contains('piatto'));
    });

    test('Drift in salita → riconosce attivazione', () {
      final rr = _synth(
        seconds: 180,
        meanMs: 900,
        rsaAmpMs: 30,
        rsaFreqHz: 0.1,
        driftMsPerSec: -0.6, // RR cala → bpm sale
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
      );
      expect(i.body.toLowerCase(), contains('hr è salit'));
    });

    test('Coerenza inclusa solo se kind è training/assessment', () {
      final rr = _synth(
        seconds: 120,
        meanMs: 900,
        rsaAmpMs: 50,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final iTraining = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
      );
      final iReading = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.reading,
      );
      expect(iTraining.body, contains('pacer'));
      expect(iReading.body, isNot(contains('pacer')));
    });

    test('Dati insufficienti restituisce neutral con messaggio dedicato', () {
      final rr = List.generate(
        5,
        (i) => RrInterval(
            timestamp: DateTime(2026).add(Duration(seconds: i)), ms: 900),
      );
      final i = interpretTachogram(
        rr: rr,
        metrics: HrvMetrics.empty,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
      );
      expect(i.level, InsightLevel.neutral);
      expect(i.headline, 'Dati insufficienti');
    });

    test(
        'postWorkout con drift HR positivo (-bpm marcato) + RSA media → '
        'recovery vagale excellent (bonus tag-specifico)', () {
      // Scenario realistico post-workout: HR parte alta (RR ~700 = ~86 bpm)
      // e scende a HR ~72 bpm a fine sessione (recovery in atto).
      // RSA modesta in valore assoluto (rsaAmp 20 = p2t ~40) ma significativa
      // per uno stato post-workout dove la HRV è fisiologicamente depressa.
      final rr = _synth(
        seconds: 240,
        meanMs: 750,
        rsaAmpMs: 20,
        rsaFreqHz: 0.1,
        driftMsPerSec: 0.4, // RR cresce → bpm scende
      );
      final m = HrvCalculator.compute(rr);
      final iGeneral = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.general,
      );
      final iPost = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.postWorkout,
      );
      // Stesso segnale: general lo etichetta come "fair/good", post-workout
      // riconosce il recovery e lo promuove a excellent.
      expect(iPost.level, InsightLevel.excellent);
      expect(iPost.headline.toLowerCase(), contains('recovery vagale'));
      expect(iPost.body.toLowerCase(), contains('recovery vagale'));
      // Il general dovrebbe restare sotto excellent (p2t ~40 < 80).
      expect(iGeneral.level, isNot(InsightLevel.excellent));
    });

    test('postWorkout: soglie p2t abbassate → "modulazione modesta" diventa '
        '"RSA presente"', () {
      // p2t intorno a 32-38 ms: per general è "fair" (sotto 50), per
      // postWorkout (soglia good=30) deve essere "good".
      final rr = _synth(
        seconds: 180,
        meanMs: 800,
        rsaAmpMs: 18,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final iGeneral = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.general,
      );
      final iPost = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.postWorkout,
      );
      // general: p2t ~36 < 50 = soglia good → fair
      expect(iGeneral.level, InsightLevel.fair);
      // postWorkout: p2t ~36 >= 30 = soglia good per questo tag → good
      expect(iPost.level, InsightLevel.good);
      // Il contesto "post-workout" deve apparire nella narrativa.
      expect(iPost.body.toLowerCase(), contains('post-workout'));
    });

    test('stress con HR in calo marcato → headline "De-escalation in corso"',
        () {
      final rr = _synth(
        seconds: 240,
        meanMs: 820,
        rsaAmpMs: 25,
        rsaFreqHz: 0.1,
        driftMsPerSec: 0.5, // RR cresce molto → bpm scende ~5 bpm
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.stress,
      );
      expect(i.headline.toLowerCase(), contains('de-escalation'));
      expect(i.body.toLowerCase(), contains('simpatico'));
    });

    test('sleep con drift positivo + RSA ampia → "Sistema pronto al sonno"',
        () {
      final rr = _synth(
        seconds: 240,
        meanMs: 1000,
        rsaAmpMs: 80,
        rsaFreqHz: 0.1,
        // 0.6 ms/sec garantisce drift HR ≥ 3 bpm tra le due metà (oltre la
        // soglia "stabile" da 2 bpm), così scatta la frase sleep-specific.
        driftMsPerSec: 0.6,
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.fromBpm(5),
        kind: SessionKind.training,
        tag: SessionTag.sleep,
      );
      expect(i.headline.toLowerCase(), contains('sonno'));
      expect(i.body.toLowerCase(), contains('parasimpatica'));
    });

    test('preWorkout con buona RSA → "Priming vagale completato"', () {
      final rr = _synth(
        seconds: 180,
        meanMs: 900,
        rsaAmpMs: 30,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.preWorkout,
      );
      // p2t ~60 >= profile preWorkout p2tGood=40 → headline tag-specific.
      expect(i.headline.toLowerCase(), contains('priming'));
    });

    test('postWorkout con HR che SALE → narrativa di warning', () {
      final rr = _synth(
        seconds: 240,
        meanMs: 700,
        rsaAmpMs: 15,
        rsaFreqHz: 0.1,
        driftMsPerSec: -0.4, // RR cala → bpm sale (recovery NON in corso)
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretTachogram(
        rr: rr,
        metrics: m,
        pattern: BreathingPattern.resonance6bpm,
        kind: SessionKind.training,
        tag: SessionTag.postWorkout,
      );
      expect(i.body.toLowerCase(), contains('insolito post-workout'));
    });
  });

  group('SessionTag defaults', () {
    test('Morning default 3 min, 6 bpm', () {
      expect(SessionTag.morning.defaultDurationMin, 3);
      expect(SessionTag.morning.defaultPattern.breathsPerMinute,
          closeTo(6, 0.01));
    });

    test('Sleep default 10 min, 5 bpm', () {
      expect(SessionTag.sleep.defaultDurationMin, 10);
      expect(SessionTag.sleep.defaultPattern.breathsPerMinute,
          closeTo(5, 0.01));
    });

    test('Stress default 10 min, 5.5 bpm', () {
      expect(SessionTag.stress.defaultDurationMin, 10);
      expect(SessionTag.stress.defaultPattern.breathsPerMinute,
          closeTo(5.5, 0.01));
    });

    test('PostWorkout default 15 min, 6 bpm', () {
      expect(SessionTag.postWorkout.defaultDurationMin, 15);
      expect(SessionTag.postWorkout.defaultPattern.breathsPerMinute,
          closeTo(6, 0.01));
    });

    test('Rationale presente per ogni tag', () {
      for (final t in SessionTag.values) {
        expect(t.rationale, isNotEmpty);
      }
    });
  });

  group('interpretSpectrum', () {
    test('Allineamento col pacer incluso solo a respiro guidato', () {
      final rr = _synth(
        seconds: 180,
        meanMs: 950,
        rsaAmpMs: 60,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final iTraining = interpretSpectrum(
          m, BreathingPattern.resonance6bpm, SessionKind.training);
      final iReading = interpretSpectrum(
          m, BreathingPattern.resonance6bpm, SessionKind.reading);
      // A respiro guidato confrontiamo il picco col pacer; a respiro
      // spontaneo (Morning) no: nessuna menzione del pacer/frequenza guida.
      expect(iTraining.body, contains('pacer'));
      expect(iReading.body, isNot(contains('pacer')));
      expect(iReading.body.toLowerCase(), contains('respiro spontaneo'));
    });

    test('Spettro non disponibile sotto soglia campioni → neutral', () {
      final rr = List.generate(
        10,
        (i) => RrInterval(
            timestamp: DateTime(2026).add(Duration(seconds: i)), ms: 900),
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretSpectrum(
          m, BreathingPattern.resonance6bpm, SessionKind.reading);
      expect(i.level, InsightLevel.neutral);
      expect(i.headline.toLowerCase(), contains('spettro'));
    });
  });

  group('interpretPoincare', () {
    test('Nuvola a sigaro (ratio basso) viene riconosciuta', () {
      // Oscillazione molto lenta (0.02 Hz = 50s di periodo): SDNN alto,
      // RMSSD basso → SD2 ≫ SD1 e ratio < 0.25.
      final rr = _synth(
        seconds: 240,
        meanMs: 950,
        rsaAmpMs: 100,
        rsaFreqHz: 0.02,
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretPoincare(m);
      expect(m.sd1Sd2Ratio, lessThan(0.25));
      expect(i.headline.toLowerCase(), contains('sigaro'));
      expect(i.body, contains('SD2 ≫ SD1'));
    });

    test('Nuvola rotonda (ratio alto) viene riconosciuta', () {
      // RR molto rumoroso battito-battito → SD1 sale verso SD2.
      final rr = <RrInterval>[];
      final rng = math.Random(7);
      var ts = DateTime(2026);
      for (var i = 0; i < 200; i++) {
        final ms = 900 + ((rng.nextDouble() - 0.5) * 120).round();
        rr.add(RrInterval(timestamp: ts, ms: ms));
        ts = ts.add(Duration(milliseconds: ms));
      }
      final m = HrvCalculator.compute(rr);
      final i = interpretPoincare(m);
      expect(m.sd1Sd2Ratio, greaterThan(0.45));
      expect(i.headline.toLowerCase(),
          anyOf(contains('arrotondata'), contains('dispersa')));
    });

    test('Body include i numeri SD1, SD2 e ratio', () {
      final rr = _synth(
        seconds: 120,
        meanMs: 900,
        rsaAmpMs: 40,
        rsaFreqHz: 0.1,
      );
      final m = HrvCalculator.compute(rr);
      final i = interpretPoincare(m);
      expect(i.body, contains(m.sd1Ms.toStringAsFixed(1)));
      expect(i.body, contains(m.sd2Ms.toStringAsFixed(1)));
      expect(i.body, contains(m.sd1Sd2Ratio.toStringAsFixed(2)));
    });

    test('Dati insufficienti', () {
      final i = interpretPoincare(HrvMetrics.empty);
      expect(i.level, InsightLevel.neutral);
      expect(i.headline, 'Dati insufficienti');
    });
  });
}
