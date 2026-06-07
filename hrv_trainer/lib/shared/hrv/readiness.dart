import 'dart:math' as math;

import 'session_models.dart';

/// Stato di readiness mattutino basato su z-score del **lnRMSSD** rispetto al
/// baseline personale.
///
/// Logica:
/// - Baseline cronico: media+SD del lnRMSSD sulle ultime fino a [chronicDays]
///   letture morning (per la stabilità del denominatore z).
/// - Baseline acuto (7gg): media+SD del lnRMSSD recente → definisce lo
///   Smallest Worthwhile Change (SWC = 0.5·SD) e la banda "normale" mostrata
///   sul grafico.
/// - z-score della lettura odierna rispetto al cronico.
/// - Bande: z>-0.5 green, -1.5<z≤-0.5 yellow, z≤-1.5 red.
///
/// Si lavora sul **lnRMSSD** (non RMSSD grezzo) perché è la scala su cui la
/// letteratura standardizza l'HRV quotidiano: la trasformazione log comprime
/// la forte asimmetria dell'RMSSD rendendo z e CV confrontabili.
///
/// Paradosso della saturazione: un RMSSD basso accompagnato da HR ben sotto il
/// baseline (bradicardia) indica saturazione vagale, non fatica — in quel caso
/// la banda viene ammorbidita (vedi sotto).
enum ReadinessBand { unknown, green, yellow, red }

enum AutonomicDirection { balanced, parasympatheticLow, sympatheticHigh }

/// Raccomandazione di carico per la giornata, derivata dalla banda + un
/// guardrail anti-accumulo (mai >2 giorni consecutivi dello stesso estremo).
enum TrainingAdvice { unknown, trainHard, trainEasy, rest }

extension TrainingAdviceX on TrainingAdvice {
  String get label => switch (this) {
        TrainingAdvice.trainHard => 'Via libera al carico',
        TrainingAdvice.trainEasy => 'Carico leggero',
        TrainingAdvice.rest => 'Recupero',
        TrainingAdvice.unknown => '—',
      };
}

/// Stabilità della serie HRV recente, derivata dal Coefficiente di Variazione
/// del lnRMSSD sulla finestra rolling. Un CV crescente segnala instabilità
/// omeostatica (la traiettoria perde affidabilità prima ancora che la media
/// crolli): nello studio post-concussione un CV passato da ~3% a ~6% ha
/// anticipato la disfunzione autonomica. Soglie indicative, non diagnostiche.
enum CvStability { unknown, stable, moderate, unstable }

class Readiness {
  final ReadinessBand band;
  final AutonomicDirection direction;
  final double? zScore;
  final double? baselineRmssd;
  final double todayRmssd;
  final double todayHr;
  final int baselineDays;
  final String headline;
  final String message;

  /// Coefficiente di Variazione del lnRMSSD (%) sulla finestra rolling più
  /// recente (oggi incluso). `null` finché non ci sono ≥3 letture valide.
  final double? cvPct;

  /// Raccomandazione di carico azionabile.
  final TrainingAdvice advice;

  /// Testo di guida (banda + eventuale guardrail consecutivi).
  final String adviceText;

  /// Smallest Worthwhile Change sulla scala ln (0.5·SD del lnRMSSD a 7gg).
  /// `null` se baseline insufficiente. Per disegnare la banda "normale".
  final double? swcLn;

  /// Estremi della banda normale in RMSSD (ms): exp(mean7 ± SWC). `null` se
  /// baseline insufficiente.
  final double? bandLowRmssd;
  final double? bandHighRmssd;

  /// True se la banda è stata ammorbidita per saturazione vagale (RMSSD basso
  /// ma HR sotto baseline): lo segnaliamo per non spaventare l'utente.
  final bool vagalSaturation;

  const Readiness({
    required this.band,
    required this.direction,
    required this.zScore,
    required this.baselineRmssd,
    required this.todayRmssd,
    required this.todayHr,
    required this.baselineDays,
    required this.headline,
    required this.message,
    this.cvPct,
    this.advice = TrainingAdvice.unknown,
    this.adviceText = '',
    this.swcLn,
    this.bandLowRmssd,
    this.bandHighRmssd,
    this.vagalSaturation = false,
  });

  /// Classifica il CV in fasce di stabilità. Soglie: <5% stabile (range tipico
  /// settimanale del lnRMSSD in soggetti sani), 5-10% oscillante, ≥10%
  /// instabile. Indicative: il segnale forte è il *trend* del CV nel tempo.
  CvStability get cvStability {
    final c = cvPct;
    if (c == null) return CvStability.unknown;
    if (c < 5) return CvStability.stable;
    if (c < 10) return CvStability.moderate;
    return CvStability.unstable;
  }

  String get cvLabel => switch (cvStability) {
        CvStability.stable => 'stabile',
        CvStability.moderate => 'oscillante',
        CvStability.unstable => 'instabile',
        CvStability.unknown => '—',
      };

  static const unknown = Readiness(
    band: ReadinessBand.unknown,
    direction: AutonomicDirection.balanced,
    zScore: null,
    baselineRmssd: null,
    todayRmssd: 0,
    todayHr: 0,
    baselineDays: 0,
    headline: 'Baseline non ancora disponibile',
    message: 'Servono almeno 3 Morning reading per iniziare a calcolare '
        'la tua readiness personale. Programma un check-in mattutino di '
        '1-3 minuti a riposo, subito dopo il risveglio.',
  );
}

class ReadinessCalculator {
  static const int minBaselineDays = 3;
  static const int defaultWindowDays = 7;

  /// Finestra cronica (giorni) per media/SD del lnRMSSD usate come denominatore
  /// z: più lunga = z più stabile rispetto al rumore quotidiano.
  static const int chronicDays = 60;

  /// Calcola la readiness usando [history] = sessioni taggate `morning`
  /// ordinate dalla più recente alla più vecchia. La più recente è
  /// considerata la lettura "di oggi"; le precedenti formano il baseline.
  static Readiness fromHistory(
    List<Session> history, {
    int windowDays = defaultWindowDays,
  }) {
    final mornings = history
        .where((s) => s.tag == SessionTag.morning && s.metrics.samples > 0)
        .toList();
    if (mornings.isEmpty) return Readiness.unknown;

    // CV(lnRMSSD) sulla finestra più recente, oggi incluso: misura di
    // dispersione della serie recente (instabilità), distinta dal confronto
    // oggi-vs-baseline che guida la banda. Disponibile già con 3 letture.
    final cvPct = _cvLnRmssd(mornings.take(windowDays));

    final today = mornings.first;
    final baseline = mornings.skip(1).take(chronicDays).toList();
    if (baseline.length < minBaselineDays) {
      return Readiness(
        band: ReadinessBand.unknown,
        direction: AutonomicDirection.balanced,
        zScore: null,
        baselineRmssd: null,
        todayRmssd: today.metrics.rmssdMs,
        todayHr: today.metrics.meanHrBpm,
        baselineDays: baseline.length,
        headline: 'Baseline in costruzione (${baseline.length}/$minBaselineDays)',
        message: 'Ancora ${minBaselineDays - baseline.length} Morning reading '
            'per iniziare a calcolare readiness.',
        cvPct: cvPct,
      );
    }

    // Statistiche display (RMSSD grezzo) e HR sul baseline cronico.
    final rmssds = baseline.map((s) => s.metrics.rmssdMs).toList();
    final hrs = baseline.map((s) => s.metrics.meanHrBpm).toList();
    final meanRmssd = _mean(rmssds);
    final meanHr = _mean(hrs);
    final sdHr = _sampleSd(hrs, meanHr);

    // z su lnRMSSD (cronico).
    final lnChronic = baseline
        .map((s) => s.metrics.rmssdMs)
        .where((r) => r > 0)
        .map(math.log)
        .toList();
    final meanLn = _mean(lnChronic);
    final sdLn = _sampleSd(lnChronic, meanLn);
    final lnToday =
        today.metrics.rmssdMs > 0 ? math.log(today.metrics.rmssdMs) : meanLn;
    final z = sdLn > 0 ? (lnToday - meanLn) / sdLn : 0.0;

    // SWC e banda normale sull'acuto 7gg (la "current normal").
    final lnAcute = baseline
        .take(windowDays)
        .map((s) => s.metrics.rmssdMs)
        .where((r) => r > 0)
        .map(math.log)
        .toList();
    final mean7 = lnAcute.isEmpty ? meanLn : _mean(lnAcute);
    final sd7 = lnAcute.length >= 2 ? _sampleSd(lnAcute, mean7) : sdLn;
    final swcLn = 0.5 * sd7;
    final bandLowRmssd = math.exp(mean7 - swcLn);
    final bandHighRmssd = math.exp(mean7 + swcLn);

    var band = switch (z) {
      > -0.5 => ReadinessBand.green,
      > -1.5 => ReadinessBand.yellow,
      _ => ReadinessBand.red,
    };

    // Direzione: HR sopra baseline + RMSSD giù ⇒ simpatico alto.
    //            HR in linea + RMSSD giù ⇒ parasimpatico basso.
    var direction = () {
      if (z >= -0.5) return AutonomicDirection.balanced;
      final hrDelta = today.metrics.meanHrBpm - meanHr;
      if (hrDelta > 3) return AutonomicDirection.sympatheticHigh;
      return AutonomicDirection.parasympatheticLow;
    }();

    // Saturazione vagale: RMSSD crollato MA HR ben sotto baseline = dominanza
    // parasimpatica estrema, non fatica. Ammorbidiamo red→yellow e marchiamo
    // la direzione come parasimpatica (cfr. PNS Index / paradosso saturazione).
    var vagalSaturation = false;
    final hrZ = sdHr > 0 ? (today.metrics.meanHrBpm - meanHr) / sdHr : 0.0;
    if (band == ReadinessBand.red && hrZ <= -0.5) {
      band = ReadinessBand.yellow;
      direction = AutonomicDirection.parasympatheticLow;
      vagalSaturation = true;
    }

    final advice = _advice(band, mornings, meanRmssd);

    return Readiness(
      band: band,
      direction: direction,
      zScore: z,
      baselineRmssd: meanRmssd,
      todayRmssd: today.metrics.rmssdMs,
      todayHr: today.metrics.meanHrBpm,
      baselineDays: baseline.length,
      headline: _headline(band, direction),
      message: _message(band, direction, z, meanRmssd, today.metrics.rmssdMs,
          vagalSaturation),
      cvPct: cvPct,
      advice: advice.$1,
      adviceText: advice.$2,
      swcLn: swcLn,
      bandLowRmssd: bandLowRmssd,
      bandHighRmssd: bandHighRmssd,
      vagalSaturation: vagalSaturation,
    );
  }

  /// Coefficiente di Variazione del lnRMSSD (%) sulla finestra: SD/|media|·100.
  /// Richiede ≥3 letture valide (RMSSD > 0). SD campionaria (n-1).
  static double? _cvLnRmssd(Iterable<Session> window) {
    final ln = window
        .map((s) => s.metrics.rmssdMs)
        .where((r) => r > 0)
        .map(math.log)
        .toList(growable: false);
    if (ln.length < 3) return null;
    final mean = _mean(ln);
    if (mean == 0) return null;
    final sd = _sampleSd(ln, mean);
    return (sd / mean.abs()) * 100.0;
  }

  static double _mean(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  /// SD campionaria (n-1). Ritorna 0 se < 2 elementi.
  static double _sampleSd(List<double> xs, double mean) {
    if (xs.length < 2) return 0;
    final v = xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
        (xs.length - 1);
    return math.sqrt(v);
  }

  /// (advice, testo). Guardrail: se la banda è green ma le ultime 3+ mattine
  /// (oggi incluso) sono tutte sopra baseline, suggerisce comunque un giorno
  /// più leggero per non accumulare carico (mai >2 hard consecutivi).
  static (TrainingAdvice, String) _advice(
    ReadinessBand band,
    List<Session> morningsNewestFirst,
    double meanRmssd,
  ) {
    final base = switch (band) {
      ReadinessBand.green => (
          TrainingAdvice.trainHard,
          'Tono vagale in linea o superiore: ok a sessioni di qualità o '
              'intensità. Buona giornata per il training alla frequenza di '
              'risonanza.'
        ),
      ReadinessBand.yellow => (
          TrainingAdvice.trainEasy,
          'Readiness sotto la norma: preferisci tecnica a basso carico, una '
              'sessione breve o recovery attivo. Niente record oggi.'
        ),
      ReadinessBand.red => (
          TrainingAdvice.rest,
          'Recupero prioritario: evita carichi pesanti, prioritizza sonno, '
              'idratazione e respirazione lenta.'
        ),
      ReadinessBand.unknown => (TrainingAdvice.unknown, ''),
    };
    if (band == ReadinessBand.green) {
      var streak = 0;
      for (final s in morningsNewestFirst) {
        if (s.metrics.rmssdMs >= meanRmssd) {
          streak++;
        } else {
          break;
        }
      }
      if (streak >= 3) {
        return (
          TrainingAdvice.trainEasy,
          '$streak mattine consecutive sopra il baseline: valuta una seduta '
              'più leggera oggi per non accumulare carico (evita >2 giorni '
              'hard di fila).'
        );
      }
    }
    return base;
  }

  static String _headline(ReadinessBand b, AutonomicDirection d) {
    return switch (b) {
      ReadinessBand.green => 'Pronto a dare',
      ReadinessBand.yellow => 'Attenzione al carico',
      ReadinessBand.red => 'Recupero prioritario',
      ReadinessBand.unknown => 'Baseline non disponibile',
    };
  }

  static String _message(
    ReadinessBand b,
    AutonomicDirection d,
    double z,
    double base,
    double today,
    bool vagalSaturation,
  ) {
    final baseStr = base.toStringAsFixed(0);
    final todayStr = today.toStringAsFixed(0);
    switch (b) {
      case ReadinessBand.green:
        return 'RMSSD $todayStr ms vs baseline $baseStr ms. Tono vagale in linea '
            'o superiore. Puoi affrontare sessioni di qualità o intensità.';
      case ReadinessBand.yellow:
        if (vagalSaturation) {
          return 'RMSSD $todayStr ms (−${z.abs().toStringAsFixed(1)}σ) ma HR '
              'sotto il tuo baseline: probabile saturazione vagale (dominanza '
              'parasimpatica), non fatica. Sessione tranquilla, senza forzare.';
        }
        final dirText = d == AutonomicDirection.sympatheticHigh
            ? 'Segnali di stress simpatico: HR sopra il tuo baseline.'
            : 'Parasimpatico sotto media: sonno o recupero insufficienti.';
        return 'RMSSD $todayStr ms (−${z.abs().toStringAsFixed(1)}σ). $dirText '
            'Preferisci training tecnico a basso carico o recovery attivo.';
      case ReadinessBand.red:
        final dirText = d == AutonomicDirection.sympatheticHigh
            ? 'Evita carichi pesanti: sistema simpatico marcatamente attivo.'
            : 'Sistema parasimpatico depresso: prioritizza riposo e idratazione.';
        return 'RMSSD $todayStr ms (−${z.abs().toStringAsFixed(1)}σ rispetto '
            'al baseline $baseStr ms). $dirText';
      case ReadinessBand.unknown:
        return '';
    }
  }

  /// Costruisce la serie temporale per il grafico trend: punti ordinati dal più
  /// vecchio al più recente con la media mobile a 7 letture del lnRMSSD.
  static List<ReadinessTrendPoint> buildTrend(List<Session> history) {
    final mornings = history
        .where((s) => s.tag == SessionTag.morning && s.metrics.rmssdMs > 0)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt)); // vecchio → nuovo
    final out = <ReadinessTrendPoint>[];
    final lnWindow = <double>[];
    for (final s in mornings) {
      final ln = math.log(s.metrics.rmssdMs);
      lnWindow.add(ln);
      if (lnWindow.length > 7) lnWindow.removeAt(0);
      out.add(ReadinessTrendPoint(
        date: s.startedAt,
        rmssd: s.metrics.rmssdMs,
        lnRmssd: ln,
        rollingMean7Ln: _mean(lnWindow),
        hasContextFlags: s.morning?.context.hasFlags ?? false,
      ));
    }
    return out;
  }
}

/// Un punto del grafico trend della Morning Readiness.
class ReadinessTrendPoint {
  final DateTime date;
  final double rmssd;
  final double lnRmssd;
  final double rollingMean7Ln;
  final bool hasContextFlags;

  const ReadinessTrendPoint({
    required this.date,
    required this.rmssd,
    required this.lnRmssd,
    required this.rollingMean7Ln,
    required this.hasContextFlags,
  });
}
