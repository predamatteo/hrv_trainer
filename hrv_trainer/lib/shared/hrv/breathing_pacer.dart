import 'dart:math' as math;

/// Configurazione di un pacer respiratorio.
/// Tutti i valori sono in secondi. `inhale + hold1 + exhale + hold2 = periodo`.
class BreathingPattern {
  final double inhaleSec;
  final double hold1Sec;
  final double exhaleSec;
  final double hold2Sec;

  const BreathingPattern({
    required this.inhaleSec,
    this.hold1Sec = 0,
    required this.exhaleSec,
    this.hold2Sec = 0,
  });

  double get periodSec => inhaleSec + hold1Sec + exhaleSec + hold2Sec;

  double get breathsPerMinute => 60.0 / periodSec;

  double get frequencyHz => 1.0 / periodSec;

  /// Pattern "Low, Slow, Deep" consigliato: I:E 4:6 per 6 bpm.
  static const resonance6bpm = BreathingPattern(inhaleSec: 4, exhaleSec: 6);

  /// Pattern simmetrico 5:5 per 6 bpm.
  static const symmetric6bpm = BreathingPattern(inhaleSec: 5, exhaleSec: 5);

  /// Costruisce un pattern da una frequenza target in bpm (respiri/min)
  /// e un rapporto I:E (inspirazione/espirazione).
  factory BreathingPattern.fromBpm(double bpm, {double ieRatio = 4 / 6}) {
    final period = 60.0 / bpm;
    // inhale/exhale = ieRatio, inhale + exhale = period
    final exhale = period / (1 + ieRatio);
    final inhale = period - exhale;
    return BreathingPattern(inhaleSec: inhale, exhaleSec: exhale);
  }

  Map<String, dynamic> toJson() => {
        'i': inhaleSec,
        'h1': hold1Sec,
        'e': exhaleSec,
        'h2': hold2Sec,
      };

  factory BreathingPattern.fromJson(Map<String, dynamic> j) => BreathingPattern(
        inhaleSec: (j['i'] as num).toDouble(),
        hold1Sec: (j['h1'] as num?)?.toDouble() ?? 0,
        exhaleSec: (j['e'] as num).toDouble(),
        hold2Sec: (j['h2'] as num?)?.toDouble() ?? 0,
      );
}

enum BreathingPhase { inhale, holdAfterInhale, exhale, holdAfterExhale }

class PacerState {
  final BreathingPhase phase;
  final double progress; // 0..1 all'interno della fase corrente
  final double amplitude; // 0..1 dimensione "polmone" simulato
  final double elapsedSec;

  const PacerState({
    required this.phase,
    required this.progress,
    required this.amplitude,
    required this.elapsedSec,
  });
}

/// Calcola lo stato del pacer ad un tempo assoluto.
PacerState pacerAt(BreathingPattern p, double tSec) {
  final T = p.periodSec;
  final t = tSec % T;

  if (t < p.inhaleSec) {
    final r = t / p.inhaleSec;
    return PacerState(
      phase: BreathingPhase.inhale,
      progress: r,
      amplitude: _smooth(r),
      elapsedSec: tSec,
    );
  }
  var c = p.inhaleSec;
  if (t < c + p.hold1Sec) {
    return PacerState(
      phase: BreathingPhase.holdAfterInhale,
      progress: (t - c) / math.max(p.hold1Sec, 1e-9),
      amplitude: 1.0,
      elapsedSec: tSec,
    );
  }
  c += p.hold1Sec;
  if (t < c + p.exhaleSec) {
    final r = (t - c) / p.exhaleSec;
    return PacerState(
      phase: BreathingPhase.exhale,
      progress: r,
      amplitude: 1.0 - _smooth(r),
      elapsedSec: tSec,
    );
  }
  c += p.exhaleSec;
  return PacerState(
    phase: BreathingPhase.holdAfterExhale,
    progress: (t - c) / math.max(p.hold2Sec, 1e-9),
    amplitude: 0.0,
    elapsedSec: tSec,
  );
}

// Curva sinusoidale 0->1 per transizioni morbide.
double _smooth(double x) => 0.5 - 0.5 * math.cos(math.pi * x.clamp(0.0, 1.0));
