import 'breathing_pacer.dart';
import 'hrv_metrics.dart';
import 'rr_interval.dart';

enum SessionKind { assessment, training, freestyle, reading }

/// Tag contestuale della sessione. Permette di segmentare lo storico e
/// calcolare baseline separati (es. "Morning reading" per readiness score).
enum SessionTag {
  morning, // check-in mattutino a riposo (per Morning Readiness)
  preWorkout,
  postWorkout,
  sleep,
  stress,
  recovery,
  general,
}

extension SessionTagX on SessionTag {
  String get label => switch (this) {
        SessionTag.morning => 'Morning',
        SessionTag.preWorkout => 'Pre-workout',
        SessionTag.postWorkout => 'Post-workout',
        SessionTag.sleep => 'Sleep',
        SessionTag.stress => 'Stress',
        SessionTag.recovery => 'Recovery',
        SessionTag.general => 'Generale',
      };

  /// Pattern respiratorio consigliato per il contesto. L'utente può
  /// comunque modificare lo slider prima dello start.
  ///
  /// Razionale clinico (Lehrer-Gevirtz 2014, Shaffer 2017):
  /// - 6 bpm è la frequenza di risonanza media adulta;
  /// - 5.5 bpm allunga l'espirazione → maggior attivazione vagale per
  ///   stati con simpatico dominante (stress, rest day);
  /// - 5 bpm è il limite inferiore confortevole, indica dominanza
  ///   parasimpatica massima (pre-sonno).
  BreathingPattern get defaultPattern => switch (this) {
        SessionTag.sleep => BreathingPattern.fromBpm(5.0),
        SessionTag.stress => BreathingPattern.fromBpm(5.5),
        SessionTag.recovery => BreathingPattern.fromBpm(5.5),
        _ => BreathingPattern.resonance6bpm,
      };

  /// Durata consigliata in minuti. Calibrate sui protocolli di
  /// biofeedback (Lehrer & Gevirtz, "Heart Rate Variability Biofeedback")
  /// e sull'uso reale del dispositivo (Instinct Solar 2X — sessioni
  /// lunghe scaricano la batteria con BT attivo).
  int get defaultDurationMin => switch (this) {
        SessionTag.morning => 3,
        SessionTag.preWorkout => 5,
        SessionTag.postWorkout => 15,
        SessionTag.stress => 10,
        SessionTag.sleep => 10,
        SessionTag.recovery => 20,
        SessionTag.general => 20,
      };

  /// Razionale mostrato come hint nella UI di setup sessione.
  String get rationale => switch (this) {
        SessionTag.morning =>
          'Check-in mattutino a riposo: alimenta la Morning Readiness.',
        SessionTag.preWorkout =>
          'Priming vagale prima del carico: 5 min sono sufficienti.',
        SessionTag.postWorkout =>
          'Recovery: aiuta il vago a riprendere il sopravvento dopo il workout.',
        SessionTag.stress =>
          'De-escalation: espirazione allungata (5.5 bpm) per abbassare il simpatico.',
        SessionTag.recovery =>
          'Rest day: sessione lunga a respiro lento per allenare il baroriflesso.',
        SessionTag.sleep =>
          'Pre-sonno: 5 bpm per indurre dominanza parasimpatica.',
        SessionTag.general =>
          'Training generico alla frequenza di risonanza standard.',
      };
}

/// Una sessione completa (assessment o training).
class Session {
  final int? id;
  final SessionKind kind;
  final SessionTag tag;
  final DateTime startedAt;
  final DateTime? endedAt;
  final BreathingPattern pattern;
  final HrvMetrics metrics;
  final String? notes;

  const Session({
    this.id,
    required this.kind,
    this.tag = SessionTag.general,
    required this.startedAt,
    this.endedAt,
    required this.pattern,
    required this.metrics,
    this.notes,
  });

  Duration get duration =>
      (endedAt ?? DateTime.now()).difference(startedAt);

  Session copyWith({
    int? id,
    SessionKind? kind,
    SessionTag? tag,
    DateTime? startedAt,
    DateTime? endedAt,
    BreathingPattern? pattern,
    HrvMetrics? metrics,
    String? notes,
  }) =>
      Session(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        tag: tag ?? this.tag,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        pattern: pattern ?? this.pattern,
        metrics: metrics ?? this.metrics,
        notes: notes ?? this.notes,
      );
}

/// Risultato di uno step del protocollo di assessment (es. respiro a 5.5 bpm).
class AssessmentStep {
  final double bpm;
  final Duration duration;
  final HrvMetrics metrics;
  final List<RrInterval> rrSamples;

  const AssessmentStep({
    required this.bpm,
    required this.duration,
    required this.metrics,
    required this.rrSamples,
  });
}

/// Esito completo di una sessione di assessment per la Frequenza di Risonanza.
class ResonanceAssessment {
  final DateTime takenAt;
  final List<AssessmentStep> steps;
  final double? resonanceBpm;
  final String? rationale;

  const ResonanceAssessment({
    required this.takenAt,
    required this.steps,
    this.resonanceBpm,
    this.rationale,
  });

  /// Trova la frequenza con il miglior compromesso di SDNN, LF-peak e
  /// vicinanza della freq dominante alla freq respiratoria target.
  factory ResonanceAssessment.analyze(
    DateTime takenAt,
    List<AssessmentStep> steps,
  ) {
    if (steps.isEmpty) {
      return ResonanceAssessment(takenAt: takenAt, steps: steps);
    }
    double score(AssessmentStep s) {
      final targetHz = s.bpm / 60.0;
      final freqCloseness = 1.0 /
          (1.0 + ((s.metrics.lfPeakHz - targetHz).abs() * 40));
      // sdnn normalizzato (ipotesi range 20-150 ms) + lf power * closeness
      final sdnnNorm = (s.metrics.sdnnMs / 150.0).clamp(0.0, 1.0);
      return sdnnNorm * 0.5 +
          (s.metrics.lfPower > 0 ? 0.3 : 0.0) +
          freqCloseness * 0.2;
    }

    final ranked = [...steps]..sort((a, b) => score(b).compareTo(score(a)));
    final best = ranked.first;
    return ResonanceAssessment(
      takenAt: takenAt,
      steps: steps,
      resonanceBpm: best.bpm,
      rationale:
          'Miglior compromesso tra ampiezza SDNN (${best.metrics.sdnnMs.toStringAsFixed(1)} ms), '
          'picco LF a ${best.metrics.lfPeakHz.toStringAsFixed(3)} Hz '
          'e sincronia con la respirazione (${best.bpm.toStringAsFixed(1)} bpm).',
    );
  }
}
