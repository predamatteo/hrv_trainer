import 'dart:math' as math;

import 'hrv_metrics.dart';
import 'readiness.dart' show CvStability;
import 'session_models.dart';

/// Direzione dell'andamento HRV di lungo periodo (settimane).
enum HrvTrendDirection { unknown, improving, stable, declining }

/// Stato HRV "generale" / CRONICO: livello tipico recente + direzione su più
/// settimane + stabilità. È COMPLEMENTARE alla Morning Readiness (che è acuta:
/// oggi vs baseline personale). Risponde a "la mia HRV di base sta salendo?",
/// che è l'adattamento perseguito dal training di risonanza.
///
/// Si lavora in lnRMSSD (scala standard per normalizzare la skewness) e la
/// soglia di significatività è lo Smallest Worthwhile Change (0.5·SD): così
/// piccole oscillazioni di rumore non vengono lette come "miglioramento/calo".
/// Niente etichette assolute (l'app evita norme di popolazione; l'Instinct 2X
/// sottostima l'RMSSD): solo confronto personale nel tempo.
class HrvGeneralStatus {
  /// RMSSD tipico recente (media finestra recente). null se nessuna lettura.
  final double? levelRmssd;

  /// HRV score 0-100 corrispondente a [levelRmssd].
  final double? levelScore;

  final HrvTrendDirection direction;

  /// Variazione % in RMSSD (recente vs periodo precedente). null se la
  /// direzione non è determinabile (dati insufficienti).
  final double? deltaPct;

  /// Ampiezza in settimane del confronto (span reale dei dati usati).
  final int? spanWeeks;

  /// CV(lnRMSSD) % sugli ultimi 7 giorni; null se < 3 letture.
  final double? cvPct;

  const HrvGeneralStatus({
    this.levelRmssd,
    this.levelScore,
    this.direction = HrvTrendDirection.unknown,
    this.deltaPct,
    this.spanWeeks,
    this.cvPct,
  });

  static const empty = HrvGeneralStatus();

  bool get hasLevel => levelRmssd != null;

  /// Classificazione stabilità dal CV, stesse soglie della Morning Readiness
  /// (<5% stabile, 5-10% oscillante, ≥10% instabile).
  CvStability get cvStability {
    final c = cvPct;
    if (c == null) return CvStability.unknown;
    if (c < 5) return CvStability.stable;
    if (c < 10) return CvStability.moderate;
    return CvStability.unstable;
  }
}

class HrvTrendCalculator {
  /// Finestra "recente" (giorni) per il livello e il lato recente del confronto.
  static const int recentDays = 14;

  /// Finestra "precedente" (giorni) immediatamente prima della recente.
  static const int priorDays = 28;

  /// Letture minime per finestra per dichiarare una direzione.
  static const int minPerWindow = 3;

  /// Finestra (giorni) del CV di stabilità.
  static const int cvDays = 7;

  /// Calcola lo stato generale da [morningsNewestFirst] = sessioni taggate
  /// `morning` ordinate dalla più recente alla più vecchia.
  static HrvGeneralStatus fromMornings(List<Session> morningsNewestFirst) {
    final now = DateTime.now();
    // (età in giorni, lnRMSSD, RMSSD) per ogni lettura valida.
    final valid = <({double ageDays, double ln, double rmssd})>[];
    for (final s in morningsNewestFirst) {
      final r = s.metrics.rmssdMs;
      if (s.tag != SessionTag.morning || s.metrics.samples <= 0 || r <= 0) {
        continue;
      }
      final ageDays = now.difference(s.startedAt).inSeconds / 86400.0;
      valid.add((ageDays: ageDays, ln: math.log(r), rmssd: r));
    }
    if (valid.isEmpty) return HrvGeneralStatus.empty;

    // Livello: media RMSSD della finestra recente; se vuota (solo letture
    // vecchie) ripiega su tutte le disponibili così la card mostra comunque
    // un livello.
    final recent = valid.where((v) => v.ageDays < recentDays).toList();
    final levelSource = recent.isNotEmpty ? recent : valid;
    final levelRmssd = _mean(levelSource.map((v) => v.rmssd));
    final levelScore = HrvMetrics.scoreFromRmssd(levelRmssd);

    // Stabilità: CV(lnRMSSD) sugli ultimi 7gg.
    final cvPct =
        _cv(valid.where((v) => v.ageDays < cvDays).map((v) => v.ln).toList());

    // Direzione: recente (0..recentDays) vs precedente
    // (recentDays..recentDays+priorDays). Servono abbastanza letture per lato,
    // altrimenti niente direzione (solo livello + stabilità).
    final prior = valid
        .where((v) =>
            v.ageDays >= recentDays && v.ageDays < recentDays + priorDays)
        .toList();
    if (recent.length < minPerWindow || prior.length < minPerWindow) {
      return HrvGeneralStatus(
        levelRmssd: levelRmssd,
        levelScore: levelScore,
        cvPct: cvPct,
      );
    }

    final recentLn = recent.map((v) => v.ln).toList();
    final priorLn = prior.map((v) => v.ln).toList();
    final recentMean = _mean(recentLn);
    final priorMean = _mean(priorLn);
    final delta = recentMean - priorMean;

    // SWC = 0.5·SD come deadband: SD del periodo precedente (riferimento), con
    // fallback alla SD dell'unione se il prior ha varianza ~nulla.
    var sd = _sd(priorLn, priorMean);
    if (sd <= 0) {
      final union = [...recentLn, ...priorLn];
      sd = _sd(union, _mean(union));
    }
    final swc = 0.5 * sd;

    final direction = delta.abs() < swc
        ? HrvTrendDirection.stable
        : (delta > 0
            ? HrvTrendDirection.improving
            : HrvTrendDirection.declining);

    final deltaPct = (math.exp(delta) - 1) * 100.0;

    // Span reale dei dati confrontati (dalla lettura più vecchia del prior alla
    // più recente del recente) espresso in settimane.
    final maxAge = prior.map((v) => v.ageDays).reduce(math.max);
    final minAge = recent.map((v) => v.ageDays).reduce(math.min);
    final spanWeeks = ((maxAge - minAge) / 7).round().clamp(1, 99).toInt();

    return HrvGeneralStatus(
      levelRmssd: levelRmssd,
      levelScore: levelScore,
      direction: direction,
      deltaPct: deltaPct,
      spanWeeks: spanWeeks,
      cvPct: cvPct,
    );
  }

  static double _mean(Iterable<double> xs) {
    final l = xs.toList();
    if (l.isEmpty) return 0;
    return l.reduce((a, b) => a + b) / l.length;
  }

  /// SD campionaria (n-1). 0 se < 2 elementi.
  static double _sd(List<double> xs, double mean) {
    if (xs.length < 2) return 0;
    final v = xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
        (xs.length - 1);
    return math.sqrt(v);
  }

  /// CV(lnRMSSD) % = SD/|media|·100. null se < 3 valori.
  static double? _cv(List<double> ln) {
    if (ln.length < 3) return null;
    final m = _mean(ln);
    if (m == 0) return null;
    return (_sd(ln, m) / m.abs()) * 100.0;
  }
}
