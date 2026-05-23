import 'dart:math' as math;

import 'session_models.dart';

/// Stato di readiness mattutino basato su z-score rispetto al baseline personale.
///
/// Logica:
/// - Baseline personale calcolato come media rolling di N Morning readings
///   precedenti (default 7, min 3).
/// - Deviazione standard rolling degli stessi dati.
/// - z-score della lettura odierna rispetto al baseline.
/// - Classificazione:
///     z > +0.5 -> green "tono vagale sopra la media"
///     -0.5 ≤ z ≤ +0.5 -> green "in linea col tuo baseline"
///     -1.5 < z < -0.5 -> yellow "leggero affaticamento"
///     z ≤ -1.5 -> red "recupero insufficiente"
///
/// La direzione (Parasimpatico vs Simpatico) è indicativa:
/// - Drop di RMSSD con HR elevato → simpatico predominante (stress/fatica)
/// - Drop di RMSSD con HR normale → parasimpatico debole (sonno scarso)
enum ReadinessBand { unknown, green, yellow, red }

enum AutonomicDirection { balanced, parasympatheticLow, sympatheticHigh }

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
        '2-3 minuti a riposo, subito dopo il risveglio.',
  );
}

class ReadinessCalculator {
  static const int minBaselineDays = 3;
  static const int defaultWindowDays = 7;

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

    // CV(lnRMSSD) sulla finestra più recente, oggi incluso: è una misura di
    // dispersione della serie recente (instabilità), distinta dal confronto
    // oggi-vs-baseline che guida la banda. Disponibile già con 3 letture.
    final cvPct = _cvLnRmssd(mornings.take(windowDays));

    final today = mornings.first;
    final baseline = mornings.skip(1).take(windowDays).toList();
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

    final rmssds = baseline.map((s) => s.metrics.rmssdMs).toList();
    final hrs = baseline.map((s) => s.metrics.meanHrBpm).toList();
    final meanRmssd = rmssds.reduce((a, b) => a + b) / rmssds.length;
    final meanHr = hrs.reduce((a, b) => a + b) / hrs.length;
    final variance = rmssds
            .map((x) => (x - meanRmssd) * (x - meanRmssd))
            .reduce((a, b) => a + b) /
        rmssds.length;
    final sd = math.sqrt(variance);

    final z = sd > 0 ? (today.metrics.rmssdMs - meanRmssd) / sd : 0.0;

    final band = switch (z) {
      > -0.5 => ReadinessBand.green,
      > -1.5 => ReadinessBand.yellow,
      _ => ReadinessBand.red,
    };

    // Direzione: HR sopra baseline + RMSSD giù ⇒ simpatico alto.
    //            HR in linea + RMSSD giù ⇒ parasimpatico basso.
    final direction = () {
      if (z >= -0.5) return AutonomicDirection.balanced;
      final hrDelta = today.metrics.meanHrBpm - meanHr;
      if (hrDelta > 3) return AutonomicDirection.sympatheticHigh;
      return AutonomicDirection.parasympatheticLow;
    }();

    return Readiness(
      band: band,
      direction: direction,
      zScore: z,
      baselineRmssd: meanRmssd,
      todayRmssd: today.metrics.rmssdMs,
      todayHr: today.metrics.meanHrBpm,
      baselineDays: baseline.length,
      headline: _headline(band, direction),
      message: _message(band, direction, z, meanRmssd, today.metrics.rmssdMs),
      cvPct: cvPct,
    );
  }

  /// Coefficiente di Variazione del lnRMSSD (%) sulla finestra: SD/|media|·100.
  ///
  /// Si lavora sul lnRMSSD (non sull'RMSSD grezzo) perché è la scala su cui la
  /// letteratura riporta il CV dell'HRV quotidiano: la trasformazione log
  /// comprime la forte asimmetria dell'RMSSD e rende i valori di CV
  /// confrontabili tra individui (tipico settimanale ~3-7%). Richiede ≥3
  /// letture valide (RMSSD > 0). SD campionaria (n-1) per coerenza col resto
  /// del modulo.
  static double? _cvLnRmssd(Iterable<Session> window) {
    final ln = window
        .map((s) => s.metrics.rmssdMs)
        .where((r) => r > 0)
        .map(math.log)
        .toList(growable: false);
    if (ln.length < 3) return null;
    final mean = ln.reduce((a, b) => a + b) / ln.length;
    if (mean == 0) return null;
    final variance = ln
            .map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) /
        (ln.length - 1);
    final sd = math.sqrt(variance);
    return (sd / mean.abs()) * 100.0;
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
  ) {
    final baseStr = base.toStringAsFixed(0);
    final todayStr = today.toStringAsFixed(0);
    switch (b) {
      case ReadinessBand.green:
        return 'RMSSD $todayStr ms vs baseline $baseStr ms. Tono vagale in linea '
            'o superiore. Puoi affrontare sessioni di qualità o intensità.';
      case ReadinessBand.yellow:
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
}
