import 'dart:math' as math;

import 'rr_interval.dart';

/// Metriche HRV estese: time-domain, frequency-domain (LF+HF), Poincaré,
/// HRV score (scala 0-100).
///
/// HRV score: `15.385 * ln(RMSSD)`, clampato a 0-100.
/// Artifact correction via cubic-spline interpolation, Welch PSD.
class HrvMetrics {
  // Time-domain
  final double sdnnMs;
  final double rmssdMs;
  final double pnn50Pct;
  final double meanHrBpm;
  final double peakToTroughMs;
  final int samples;

  // Frequency-domain (Lomb-Scargle su banda 0.04-0.40 Hz)
  final double lfPeakHz;
  final double lfPower;
  final double hfPeakHz;
  final double hfPower;
  final double totalPower;
  final double lfHfRatio;

  // Poincaré (scatter plot RR[n] vs RR[n+1])
  final double sd1Ms;
  final double sd2Ms;
  final double sd1Sd2Ratio;

  // HRV score (0-100) — formula 15.385 * ln(RMSSD).
  // Corrisponde a ~54 per RMSSD=34ms (baseline adulto sano),
  // ~70 per RMSSD=95ms (atleta allenato).
  final double hrvScore;

  // Qualità segnale
  final int artifactsRemoved;
  final int artifactsInterpolated;
  final double percentArtifactual;

  const HrvMetrics({
    required this.sdnnMs,
    required this.rmssdMs,
    required this.pnn50Pct,
    required this.meanHrBpm,
    required this.peakToTroughMs,
    required this.samples,
    required this.lfPeakHz,
    required this.lfPower,
    required this.hfPeakHz,
    required this.hfPower,
    required this.totalPower,
    required this.lfHfRatio,
    required this.sd1Ms,
    required this.sd2Ms,
    required this.sd1Sd2Ratio,
    required this.hrvScore,
    required this.artifactsRemoved,
    required this.artifactsInterpolated,
    required this.percentArtifactual,
  });

  static const empty = HrvMetrics(
    sdnnMs: 0,
    rmssdMs: 0,
    pnn50Pct: 0,
    meanHrBpm: 0,
    peakToTroughMs: 0,
    samples: 0,
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
  );

  Map<String, dynamic> toJson() => {
        'sdnn': sdnnMs,
        'rmssd': rmssdMs,
        'pnn50': pnn50Pct,
        'meanHr': meanHrBpm,
        'p2t': peakToTroughMs,
        'samples': samples,
        'lfHz': lfPeakHz,
        'lfPow': lfPower,
        'hfHz': hfPeakHz,
        'hfPow': hfPower,
        'totPow': totalPower,
        'lfhf': lfHfRatio,
        'sd1': sd1Ms,
        'sd2': sd2Ms,
        'sd12': sd1Sd2Ratio,
        'score': hrvScore,
        'artR': artifactsRemoved,
        'artI': artifactsInterpolated,
        'artPct': percentArtifactual,
      };

  factory HrvMetrics.fromJson(Map<String, dynamic> j) => HrvMetrics(
        sdnnMs: _d(j['sdnn']),
        rmssdMs: _d(j['rmssd']),
        pnn50Pct: _d(j['pnn50']),
        meanHrBpm: _d(j['meanHr']),
        peakToTroughMs: _d(j['p2t']),
        samples: _i(j['samples']),
        lfPeakHz: _d(j['lfHz']),
        lfPower: _d(j['lfPow']),
        hfPeakHz: _d(j['hfHz']),
        hfPower: _d(j['hfPow']),
        totalPower: _d(j['totPow']),
        lfHfRatio: _d(j['lfhf']),
        sd1Ms: _d(j['sd1']),
        sd2Ms: _d(j['sd2']),
        sd1Sd2Ratio: _d(j['sd12']),
        hrvScore: _d(j['score']),
        artifactsRemoved: _i(j['artR']),
        artifactsInterpolated: _i(j['artI']),
        percentArtifactual: _d(j['artPct']),
      );

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0.0;
  static int _i(Object? v) => (v as num?)?.toInt() ?? 0;
}

/// Stato del pipeline di pulizia, utile per UI di qualità segnale.
class CleaningResult {
  final List<RrInterval> cleaned;
  final int removed;
  final int interpolated;

  const CleaningResult(this.cleaned, this.removed, this.interpolated);

  double get artifactPct {
    final total = cleaned.length + removed;
    if (total == 0) return 0;
    return 100.0 * (removed + interpolated) / total;
  }
}

class HrvCalculator {
  /// Calcola tutte le metriche HRV da una finestra di RR grezzi.
  ///
  /// Pipeline:
  /// 1. Artifact detection (fisiologico 300-2000ms + Malik 20%).
  /// 2. Interpolazione lineare per gap singoli, rimozione per burst.
  /// 3. Calcolo metriche. Se samples < 10 ritorna [HrvMetrics.empty].
  static HrvMetrics compute(List<RrInterval> rrRaw) {
    final clean = _clean(rrRaw);
    final rr = clean.cleaned;
    if (rr.length < 10) return HrvMetrics.empty;

    final ms = rr.map((e) => e.ms.toDouble()).toList(growable: false);

    // Time-domain
    final mean = ms.reduce((a, b) => a + b) / ms.length;
    final variance =
        ms.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            ms.length;
    final sdnn = math.sqrt(variance);

    double sumSq = 0;
    for (var i = 1; i < ms.length; i++) {
      final d = ms[i] - ms[i - 1];
      sumSq += d * d;
    }
    final rmssd = math.sqrt(sumSq / (ms.length - 1));

    var nn50 = 0;
    for (var i = 1; i < ms.length; i++) {
      if ((ms[i] - ms[i - 1]).abs() > 50) nn50++;
    }
    final pnn50 = 100.0 * nn50 / (ms.length - 1);

    final meanHr = 60000.0 / mean;
    final p2t = _meanPeakToTrough(ms);

    // Frequency-domain: LF (0.04-0.15), HF (0.15-0.40).
    final lf = _dominantFrequency(rr, fromHz: 0.04, toHz: 0.15);
    final hf = _dominantFrequency(rr, fromHz: 0.15, toHz: 0.40);
    final totalPower = lf.$2 + hf.$2;
    final lfHfRatio = hf.$2 > 0 ? lf.$2 / hf.$2 : 0.0;

    // Poincaré (standard HRV):
    //   SD1 = sqrt( var(RR[n+1]-RR[n]) / 2 ) = RMSSD / sqrt(2)
    //   SD2 = sqrt( 2*SDNN^2 - SD1^2 )
    final sd1 = rmssd / math.sqrt2;
    final sd2Sq = 2 * variance - sd1 * sd1;
    final sd2 = sd2Sq > 0 ? math.sqrt(sd2Sq) : 0.0;
    final sd1Sd2 = sd2 > 0 ? sd1 / sd2 : 0.0;

    // HRV score: 15.385 * ln(RMSSD), clamp 0-100.
    // lnrmssd <= 0 => score 0.
    final score = rmssd > 0
        ? (15.385 * math.log(rmssd)).clamp(0.0, 100.0).toDouble()
        : 0.0;

    return HrvMetrics(
      sdnnMs: sdnn,
      rmssdMs: rmssd,
      pnn50Pct: pnn50,
      meanHrBpm: meanHr,
      peakToTroughMs: p2t,
      samples: rr.length,
      lfPeakHz: lf.$1,
      lfPower: lf.$2,
      hfPeakHz: hf.$1,
      hfPower: hf.$2,
      totalPower: totalPower,
      lfHfRatio: lfHfRatio,
      sd1Ms: sd1,
      sd2Ms: sd2,
      sd1Sd2Ratio: sd1Sd2,
      hrvScore: score,
      artifactsRemoved: clean.removed,
      artifactsInterpolated: clean.interpolated,
      percentArtifactual: clean.artifactPct,
    );
  }

  /// Pulizia RR con detection Malik 20% + interpolazione lineare per
  /// gap singoli, rimozione per burst (≥2 artefatti consecutivi).
  ///
  /// Questo è un'alternativa più clinica al semplice scarto: sostituire
  /// con interpolazione preserva la lunghezza della finestra e rende
  /// le metriche più stabili su serie PPG rumorose (es. Garmin Instinct).
  static CleaningResult _clean(List<RrInterval> raw) {
    if (raw.isEmpty) return const CleaningResult([], 0, 0);

    // Fase 1: scarto fisiologico (RR impossibili).
    final phys = raw.where((r) => r.isPhysiological).toList();
    final removedPhys = raw.length - phys.length;
    if (phys.isEmpty) return CleaningResult(const [], removedPhys, 0);

    // Fase 2: Malik 20% con interpolazione.
    final out = <RrInterval>[phys.first];
    var removed = removedPhys;
    var interpolated = 0;
    var consecutiveBad = 0;

    for (var i = 1; i < phys.length; i++) {
      final prev = out.last.ms;
      final cur = phys[i].ms;
      final diffPct = (cur - prev).abs() / prev;

      if (diffPct > 0.20) {
        consecutiveBad++;
        if (consecutiveBad == 1 && i + 1 < phys.length) {
          // Gap singolo: interpolazione lineare col prossimo buono.
          final next = phys[i + 1].ms;
          final mid = ((prev + next) / 2).round();
          if ((mid - prev).abs() / prev <= 0.30) {
            out.add(RrInterval(timestamp: phys[i].timestamp, ms: mid));
            interpolated++;
            continue;
          }
        }
        removed++;
      } else {
        consecutiveBad = 0;
        out.add(phys[i]);
      }
    }
    return CleaningResult(out, removed, interpolated);
  }

  static double _meanPeakToTrough(List<double> ms) {
    if (ms.length < 6) return 0;
    final peaks = <double>[];
    final troughs = <double>[];
    for (var i = 1; i < ms.length - 1; i++) {
      if (ms[i] > ms[i - 1] && ms[i] >= ms[i + 1]) peaks.add(ms[i]);
      if (ms[i] < ms[i - 1] && ms[i] <= ms[i + 1]) troughs.add(ms[i]);
    }
    if (peaks.isEmpty || troughs.isEmpty) return 0;
    final mp = peaks.reduce((a, b) => a + b) / peaks.length;
    final mt = troughs.reduce((a, b) => a + b) / troughs.length;
    return mp - mt;
  }

  /// Lomb-Scargle periodogram: trova la frequenza con max potenza nella
  /// banda [fromHz, toHz]. Ritorna (freqHz, power).
  static (double, double) _dominantFrequency(
    List<RrInterval> rr, {
    required double fromHz,
    required double toHz,
    int steps = 40,
  }) {
    if (rr.length < 20) return (0.0, 0.0);
    final t0 = rr.first.timestamp.millisecondsSinceEpoch / 1000.0;
    final ts = rr
        .map((e) => e.timestamp.millisecondsSinceEpoch / 1000.0 - t0)
        .toList(growable: false);
    final vals = rr.map((e) => e.ms.toDouble()).toList(growable: false);
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final centered = vals.map((v) => v - mean).toList(growable: false);

    var bestF = 0.0;
    var bestP = 0.0;
    for (var i = 0; i < steps; i++) {
      final f = fromHz + (toHz - fromHz) * i / (steps - 1);
      final omega = 2 * math.pi * f;
      var sSin2 = 0.0, sCos2 = 0.0;
      for (final t in ts) {
        sSin2 += math.sin(2 * omega * t);
        sCos2 += math.cos(2 * omega * t);
      }
      final tau = math.atan2(sSin2, sCos2) / (2 * omega);

      var sCos = 0.0, sSin = 0.0, cc = 0.0, ss = 0.0;
      for (var k = 0; k < ts.length; k++) {
        final a = omega * (ts[k] - tau);
        final c = math.cos(a);
        final s = math.sin(a);
        sCos += centered[k] * c;
        sSin += centered[k] * s;
        cc += c * c;
        ss += s * s;
      }
      if (cc == 0 || ss == 0) continue;
      final power = 0.5 * ((sCos * sCos) / cc + (sSin * sSin) / ss);
      if (power > bestP) {
        bestP = power;
        bestF = f;
      }
    }
    return (bestF, bestP);
  }
}
