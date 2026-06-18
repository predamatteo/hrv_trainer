import 'dart:math' as math;

import 'morning_reading.dart';
import 'session_models.dart';

/// Statistiche aggregate per il cruscotto "Andamento HRV" (vista CRONICA).
///
/// Funzioni pure e testabili, separate dalla UI esattamente come
/// [HrvTrendCalculator]: la schermata si limita a disegnare ciò che esce da
/// qui. Tutto si calcola in-memory sulla lista di sessioni della finestra.

/// Punto del trend di coerenza: una sessione di training con coherence valida.
class CoherenceTrendPoint {
  final DateTime date;
  final double coherence;
  final double bpm;
  final int? sessionId;
  const CoherenceTrendPoint({
    required this.date,
    required this.coherence,
    required this.bpm,
    this.sessionId,
  });
}

/// RMSSD media (ms) per tag di sessione, con numerosità.
class TagHrvStat {
  final SessionTag tag;
  final double meanRmssd;
  final int count;
  const TagHrvStat({
    required this.tag,
    required this.meanRmssd,
    required this.count,
  });
}

/// Impatto di un singolo fattore di contesto sull'RMSSD mattutina.
class HabitImpact {
  final String label;

  /// RMSSD media (ms) nelle mattine con questo fattore presente.
  final double meanRmssd;

  /// Numero di mattine con il fattore.
  final int count;

  /// Variazione % rispetto alla baseline delle mattine "pulite"; null se la
  /// baseline non è calcolabile (poche mattine senza fattori).
  final double? deltaPct;

  const HabitImpact({
    required this.label,
    required this.meanRmssd,
    required this.count,
    this.deltaPct,
  });
}

/// Esito completo dell'analisi "impatto abitudini".
class HabitImpactResult {
  /// RMSSD media (ms) delle mattine senza alcun fattore di contesto.
  final double? cleanBaseline;

  /// Numero di mattine "pulite" usate per la baseline.
  final int cleanCount;

  /// Impatti per fattore, ordinati dal più penalizzante; solo fattori con
  /// numerosità sufficiente.
  final List<HabitImpact> impacts;

  const HabitImpactResult({
    this.cleanBaseline,
    this.cleanCount = 0,
    this.impacts = const [],
  });

  bool get hasData => cleanBaseline != null && impacts.isNotEmpty;
}

class DashboardStats {
  /// Numerosità minima per dichiarare una media (per tag o per fattore): sotto
  /// è rumore, non un segnale.
  static const int minSamples = 2;

  /// Finestra (numero di sessioni) della media mobile sul trend di coerenza.
  static const int coherenceRollWindow = 5;

  /// Trend di coerenza sulle sole sessioni di training con coherence valida
  /// (>0), ordinato dal più vecchio al più recente (asse temporale del grafico).
  ///
  /// La coherence ratio è IL segnale del biofeedback (oscillazione cardiaca
  /// concentrata in un picco netto = respiro in risonanza): il suo trend dice
  /// se l'abilità sta migliorando, indipendentemente dal livello assoluto di
  /// RMSSD (degradato su RR stimati da HR a 1 Hz).
  static List<CoherenceTrendPoint> coherenceTrend(List<Session> sessions) {
    final pts = <CoherenceTrendPoint>[
      for (final s in sessions)
        if (s.kind == SessionKind.training && s.metrics.coherenceRatio > 0)
          CoherenceTrendPoint(
            date: s.startedAt,
            coherence: s.metrics.coherenceRatio,
            bpm: s.pattern.breathsPerMinute,
            sessionId: s.id,
          ),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return pts;
  }

  /// Media mobile semplice (finestra [window]) allineata per indice: out[i] è la
  /// media di xs nella finestra che termina in i. Usata per la linea di tendenza
  /// del trend di coerenza.
  static List<double> rollingMean(List<double> xs, int window) {
    final out = <double>[];
    for (var i = 0; i < xs.length; i++) {
      final lo = math.max(0, i - window + 1);
      var sum = 0.0;
      for (var j = lo; j <= i; j++) {
        sum += xs[j];
      }
      out.add(sum / (i - lo + 1));
    }
    return out;
  }

  /// RMSSD media per tag (solo RMSSD>0); restituisce i soli tag con almeno
  /// [minSamples] letture, in ordine di enum per stabilità visiva del grafico.
  static List<TagHrvStat> rmssdByTag(List<Session> sessions) {
    final byTag = <SessionTag, List<double>>{};
    for (final s in sessions) {
      final r = s.metrics.rmssdMs;
      if (r <= 0) continue;
      (byTag[s.tag] ??= <double>[]).add(r);
    }
    return [
      for (final tag in SessionTag.values)
        if ((byTag[tag]?.length ?? 0) >= minSamples)
          TagHrvStat(
            tag: tag,
            meanRmssd: _mean(byTag[tag]!),
            count: byTag[tag]!.length,
          ),
    ];
  }

  /// Impatto dei fattori di contesto sull'RMSSD mattutina: confronta la media
  /// delle mattine con ciascun fattore contro la baseline delle mattine
  /// "pulite" (senza alcun fattore). Considera solo letture morning con
  /// metadati di contesto e RMSSD>0.
  static HabitImpactResult habitImpact(List<Session> sessions) {
    final mornings = <Session>[
      for (final s in sessions)
        if (s.tag == SessionTag.morning &&
            s.morning != null &&
            s.metrics.rmssdMs > 0)
          s,
    ];
    if (mornings.isEmpty) return const HabitImpactResult();

    final clean = <double>[
      for (final s in mornings)
        if (!s.morning!.context.hasFlags) s.metrics.rmssdMs,
    ];
    final cleanBaseline = clean.length >= minSamples ? _mean(clean) : null;

    // (etichetta, predicato sul contesto) per ogni fattore tracciato.
    final defs = <({String label, bool Function(MorningContext) has})>[
      (label: 'Alcol', has: (c) => c.alcohol),
      (label: 'Malattia', has: (c) => c.illness),
      (label: 'Sonno scarso', has: (c) => c.sleep == SleepQuality.poor),
      (label: 'Stress', has: (c) => c.stressed),
      (label: 'Indolenzimento', has: (c) => c.soreness),
    ];

    final impacts = <HabitImpact>[];
    for (final d in defs) {
      final vals = <double>[
        for (final s in mornings)
          if (d.has(s.morning!.context)) s.metrics.rmssdMs,
      ];
      if (vals.length < minSamples) continue;
      final mean = _mean(vals);
      impacts.add(HabitImpact(
        label: d.label,
        meanRmssd: mean,
        count: vals.length,
        deltaPct:
            cleanBaseline == null ? null : (mean / cleanBaseline - 1) * 100.0,
      ));
    }
    // Dal più penalizzante (delta più negativo) in cima.
    impacts.sort((a, b) => (a.deltaPct ?? 0).compareTo(b.deltaPct ?? 0));

    return HabitImpactResult(
      cleanBaseline: cleanBaseline,
      cleanCount: clean.length,
      impacts: impacts,
    );
  }

  static double _mean(List<double> xs) =>
      xs.reduce((a, b) => a + b) / xs.length;
}
