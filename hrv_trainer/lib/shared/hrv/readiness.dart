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
  });

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
    );
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
