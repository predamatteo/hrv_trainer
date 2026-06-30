import '../training_plan/post_session_report.dart';
import 'breathing_pacer.dart';
import 'hrv_metrics.dart';
import 'morning_reading.dart';
import 'rr_interval.dart';

enum SessionKind { assessment, training, freestyle, reading }

extension SessionKindX on SessionKind {
  /// True solo per le sessioni a respiro GUIDATO (training, assessment): per
  /// queste è esistito un pacer ed ha senso mostrarne o confrontarne la
  /// frequenza. `reading` (check-in mattutino, respiro SPONTANEO) e
  /// `freestyle` (respiro libero) NON hanno pacer: esporre una "frequenza del
  /// respiro" lì è fuorviante (l'utente non seguiva alcuna guida).
  bool get hasPacer =>
      this == SessionKind.training || this == SessionKind.assessment;
}

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
        SessionTag.morning => 'Mattino',
        SessionTag.preWorkout => 'Pre-workout',
        SessionTag.postWorkout => 'Post-workout',
        SessionTag.sleep => 'Sonno',
        SessionTag.stress => 'Stress',
        SessionTag.recovery => 'Recupero',
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

  /// Metadati Morning Readiness (postura/protocollo/contesto). Valorizzato solo
  /// per le letture mattutine create dal check-in dedicato; null altrimenti
  /// (incluse le vecchie sessioni `morning` paced pre-feature). Persistito
  /// nella colonna `morning_meta_json` (DB v3).
  final MorningMeta? morning;

  /// Id del piano di allenamento a cui questa sessione appartiene (se avviata
  /// dalla CTA "sessione di oggi" del piano). null per le sessioni fuori piano.
  /// Persistito nella colonna `plan_id` (DB v4).
  final int? planId;

  /// Report soggettivo post-sessione (tensione/calma/umore/sensazioni). null se
  /// l'utente l'ha saltato o per le sessioni pre-feature. Persistito nella
  /// colonna `post_session_report_json` (DB v4).
  final PostSessionReport? report;

  const Session({
    this.id,
    required this.kind,
    this.tag = SessionTag.general,
    required this.startedAt,
    this.endedAt,
    required this.pattern,
    required this.metrics,
    this.notes,
    this.morning,
    this.planId,
    this.report,
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
    MorningMeta? morning,
    int? planId,
    PostSessionReport? report,
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
        morning: morning ?? this.morning,
        planId: planId ?? this.planId,
        report: report ?? this.report,
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

  /// Individua la frequenza di risonanza come il ritmo respiratorio che
  /// **massimizza l'ampiezza dell'oscillazione cardiaca** indotta dal respiro
  /// (RSA), criterio cardine del protocollo di Lehrer-Vaschillo: la RF è per
  /// definizione la frequenza dove l'oscillazione HRV raggiunge il picco.
  ///
  /// Le metriche di ampiezza (peak-to-trough RR, potenza LF, SDNN) sono
  /// normalizzate **rispetto al massimo osservato tra gli step**: l'assessment
  /// è un confronto intra-sessione tra 5 ritmi, quindi conta quale ritmo rende
  /// l'oscillazione più grande *relativamente agli altri*, non il valore
  /// assoluto. Questo sostituisce il vecchio scoring in cui la potenza LF era
  /// binaria (presente/assente) e quindi non premiava l'ampiezza maggiore —
  /// proprio la grandezza che la risonanza dovrebbe massimizzare.
  ///
  /// Pesi: peak-to-trough domina (0.45) perché su Instinct Solar 2X gli RR sono
  /// stimati da HR a ~1 Hz: RMSSD/HF battito-battito risultano degradati, ma
  /// l'onda respiratoria a ~0.1 Hz (periodo ~10 s) è ben dentro il limite di
  /// Nyquist, quindi peak-to-trough e potenza LF restano affidabili. La
  /// coerenza (picco spettrale allineato alla freq respiratoria) pesa 0.15 come
  /// conferma che l'ampiezza è guidata dal respiro e non da artefatti.
  factory ResonanceAssessment.analyze(
    DateTime takenAt,
    List<AssessmentStep> steps,
  ) {
    final valid =
        steps.where((s) => s.metrics.samples >= 10).toList(growable: false);
    if (valid.isEmpty) {
      return ResonanceAssessment(takenAt: takenAt, steps: steps);
    }

    double maxOf(double Function(AssessmentStep) f) {
      var m = 0.0;
      for (final s in valid) {
        final v = f(s);
        if (v > m) m = v;
      }
      return m > 0 ? m : 1.0; // evita divisione per zero
    }

    final maxP2t = maxOf((s) => s.metrics.peakToTroughMs);
    final maxLf = maxOf((s) => s.metrics.lfPower);
    final maxSdnn = maxOf((s) => s.metrics.sdnnMs);

    double score(AssessmentStep s) {
      // Ampiezza RSA picco-valle: il segno più diretto della risonanza.
      final p2t = (s.metrics.peakToTroughMs / maxP2t).clamp(0.0, 1.0);
      // Potenza spettrale a bassa frequenza: ampiezza dell'oscillazione lenta.
      final lf = (s.metrics.lfPower / maxLf).clamp(0.0, 1.0);
      // Varianza globale come ampiezza di supporto.
      final sdnn = (s.metrics.sdnnMs / maxSdnn).clamp(0.0, 1.0);
      // Coerenza: il picco spettrale deve cadere sulla freq respiratoria,
      // altrimenti l'ampiezza è rumore e non risonanza guidata dal respiro.
      final targetHz = s.bpm / 60.0;
      final coherence =
          1.0 / (1.0 + (s.metrics.lfPeakHz - targetHz).abs() * 40);
      return p2t * 0.45 + lf * 0.30 + sdnn * 0.10 + coherence * 0.15;
    }

    final ranked = [...valid]..sort((a, b) => score(b).compareTo(score(a)));
    final best = ranked.first;
    return ResonanceAssessment(
      takenAt: takenAt,
      steps: steps,
      resonanceBpm: best.bpm,
      rationale:
          'Ampiezza dell\'oscillazione respiratoria massima a '
          '${best.bpm.toStringAsFixed(1)} respiri/min: picco-valle '
          '${best.metrics.peakToTroughMs.toStringAsFixed(0)} ms, picco '
          'spettrale a ${best.metrics.lfPeakHz.toStringAsFixed(3)} Hz '
          '(${(best.metrics.lfPeakHz * 60).toStringAsFixed(1)} cicli/min), '
          'SDNN ${best.metrics.sdnnMs.toStringAsFixed(0)} ms.',
    );
  }
}
