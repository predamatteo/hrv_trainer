import 'dart:math' as math;

import 'rr_interval.dart';

/// Affidabilità complessiva di una misura HRV, derivata da quantità di
/// campioni, durata, percentuale di artefatti e sorgente del segnale.
///
/// Sull'Instinct Solar 2X gli RR sono STIMATI da HR a ~1 Hz (no battito-
/// battito reale): la banda HF (0.15-0.40 Hz) è oltre Nyquist e RMSSD
/// sottostima. Per questo una sorgente `estimated_from_hr` non raggiunge mai
/// `high`: lo segnaliamo onestamente invece di presentare numeri come
/// "misurati".
enum HrvConfidence { high, moderate, low, insufficient }

extension HrvConfidenceX on HrvConfidence {
  String get label => switch (this) {
        HrvConfidence.high => 'Alta',
        HrvConfidence.moderate => 'Media',
        HrvConfidence.low => 'Bassa',
        HrvConfidence.insufficient => 'Insufficiente',
      };
}

/// Metriche HRV estese: time-domain, frequency-domain (LF+HF), Poincaré,
/// HRV score (scala 0-100).
///
/// HRV score: `15.385 * ln(RMSSD)`, clampato a 0-100.
/// Pipeline: detection artefatti (fisiologico + Malik/mediana) con
/// interpolazione lineare dei gap singoli, periodogramma di Lomb-Scargle per
/// le potenze di banda integrate.
class HrvMetrics {
  // Time-domain
  final double sdnnMs;
  final double rmssdMs;
  final double pnn50Pct;
  final double meanHrBpm;
  final double peakToTroughMs;
  final int samples;

  // Frequency-domain (Lomb-Scargle su banda 0.04-0.40 Hz).
  // lfPower/hfPower sono la potenza INTEGRATA sulla banda (area sotto il
  // periodogramma), non il singolo bin di picco; lfPeakHz/hfPeakHz sono la
  // frequenza del picco entro la banda.
  final double lfPeakHz;
  final double lfPower;
  final double hfPeakHz;
  final double hfPower;
  final double totalPower;
  final double lfHfRatio;

  /// Unità normalizzate (n.u.): LF e HF come % della potenza LF+HF. Robuste
  /// al fatto che la potenza assoluta di Lomb-Scargle ha unità arbitrarie.
  final double lfNu;
  final double hfNu;

  /// Coherence ratio (stile HeartMath): potenza nel picco dominante (±0.015 Hz)
  /// rapportata alla potenza residua. Alto = oscillazione cardiaca concentrata
  /// in un picco netto = respiro coerente/risonanza. È il segnale chiave del
  /// biofeedback (più informativo dell'RMSSD su sorgente a 1 Hz).
  final double coherenceRatio;

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

  /// Durata effettiva coperta dagli RR puliti (somma dei ms), in secondi.
  /// Usata per il gating di confidenza (>=60s per il time-domain stabile).
  final double durationSec;

  /// Sorgente degli RR: 'rr_native' (intervalli battito-battito reali) oppure
  /// 'estimated_from_hr' (ricostruiti da HR a ~1 Hz, caso Instinct 2X).
  final String rrSource;

  /// Affidabilità complessiva (vedi [HrvConfidence]).
  final HrvConfidence confidence;

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
    // Campi aggiunti dopo il rilascio iniziale: opzionali con default così le
    // costruzioni esistenti (test, vecchi callers) restano valide.
    this.lfNu = 0,
    this.hfNu = 0,
    this.coherenceRatio = 0,
    this.durationSec = 0,
    this.rrSource = 'estimated_from_hr',
    this.confidence = HrvConfidence.insufficient,
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
    lfNu: 0,
    hfNu: 0,
    coherenceRatio: 0,
    durationSec: 0,
    rrSource: 'estimated_from_hr',
    confidence: HrvConfidence.insufficient,
  );

  /// HRV score 0-100 dalla sola RMSSD: `15.385 * ln(RMSSD)` clampato.
  /// Sorgente UNICA del punteggio: usata sia in [HrvCalculator.compute] sia
  /// dagli aggregati (es. livello HRV in HrvTrendCalculator) per non
  /// duplicare la costante. RMSSD <= 0 → 0.
  static double scoreFromRmssd(double rmssdMs) => rmssdMs > 0
      ? (15.385 * math.log(rmssdMs)).clamp(0.0, 100.0).toDouble()
      : 0.0;

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
        'lfNu': lfNu,
        'hfNu': hfNu,
        'coh': coherenceRatio,
        'sd1': sd1Ms,
        'sd2': sd2Ms,
        'sd12': sd1Sd2Ratio,
        'score': hrvScore,
        'artR': artifactsRemoved,
        'artI': artifactsInterpolated,
        'artPct': percentArtifactual,
        'durSec': durationSec,
        'rrSrc': rrSource,
        'conf': confidence.name,
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
        lfNu: _d(j['lfNu']),
        hfNu: _d(j['hfNu']),
        coherenceRatio: _d(j['coh']),
        sd1Ms: _d(j['sd1']),
        sd2Ms: _d(j['sd2']),
        sd1Sd2Ratio: _d(j['sd12']),
        hrvScore: _d(j['score']),
        artifactsRemoved: _i(j['artR']),
        artifactsInterpolated: _i(j['artI']),
        percentArtifactual: _d(j['artPct']),
        durationSec: _d(j['durSec']),
        rrSource: (j['rrSrc'] as String?) ?? 'estimated_from_hr',
        confidence: _conf(j['conf']),
      );

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0.0;
  static int _i(Object? v) => (v as num?)?.toInt() ?? 0;
  static HrvConfidence _conf(Object? v) => HrvConfidence.values.firstWhere(
        (c) => c.name == v,
        orElse: () => HrvConfidence.insufficient,
      );
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
  /// [rrSource] determina la pulizia: per `estimated_from_hr` (RR ricostruiti
  /// da HR a 1 Hz) la quantizzazione produce salti relativi anche su HR reale
  /// stabile, quindi usiamo una soglia più larga e il confronto con la mediana
  /// mobile invece del solo battito precedente.
  ///
  /// Pipeline:
  /// 1. Gate fisiologico (300-2000ms) + detection spike vs mediana mobile.
  /// 2. Interpolazione lineare per gap singoli, rimozione per burst.
  /// 3. Metriche time/frequency/Poincaré + confidenza. Se puliti < 10 ritorna
  ///    [HrvMetrics.empty].
  static HrvMetrics compute(
    List<RrInterval> rrRaw, {
    String rrSource = 'estimated_from_hr',
  }) {
    final estimated = rrSource == 'estimated_from_hr';
    final clean = _clean(rrRaw, estimated: estimated);
    final rr = clean.cleaned;
    if (rr.length < 10) return HrvMetrics.empty;

    final ms = rr.map((e) => e.ms.toDouble()).toList(growable: false);

    // Time-domain. Varianza CAMPIONARIA (n-1) per coerenza con RMSSD, con
    // SD2/SD1ratio e con la convenzione del watch (HrSession.buildSummary).
    final mean = ms.reduce((a, b) => a + b) / ms.length;
    final variance =
        ms.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            (ms.length - 1);
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
    final durationSec = ms.reduce((a, b) => a + b) / 1000.0;

    // Frequency-domain: periodogramma di Lomb-Scargle sull'intera banda
    // 0.04-0.40 Hz, poi potenze INTEGRATE per banda (LF 0.04-0.15, HF
    // 0.15-0.40) e picchi per banda.
    final spec = spectrum(rr);
    final lfPower = _bandPower(spec, 0.04, 0.15);
    final hfPower = _bandPower(spec, 0.15, 0.40);
    final lfPeakHz = _peakFreq(spec, 0.04, 0.15);
    final hfPeakHz = _peakFreq(spec, 0.15, 0.40);
    final totalPower = lfPower + hfPower;
    final lfHfRatio = hfPower > 0 ? lfPower / hfPower : 0.0;
    final lhSum = lfPower + hfPower;
    final lfNu = lhSum > 0 ? 100.0 * lfPower / lhSum : 0.0;
    final hfNu = lhSum > 0 ? 100.0 * hfPower / lhSum : 0.0;
    final coherenceRatio = _coherence(spec, lfPeakHz, totalPower);

    // Poincaré (standard HRV):
    //   SD1 = sqrt( var(RR[n+1]-RR[n]) / 2 ) = RMSSD / sqrt(2)
    //   SD2 = sqrt( 2*SDNN^2 - SD1^2 )
    final sd1 = rmssd / math.sqrt2;
    final sd2Sq = 2 * variance - sd1 * sd1;
    final sd2 = sd2Sq > 0 ? math.sqrt(sd2Sq) : 0.0;
    final sd1Sd2 = sd2 > 0 ? sd1 / sd2 : 0.0;

    // HRV score: 15.385 * ln(RMSSD), clamp 0-100 (vedi scoreFromRmssd).
    final score = HrvMetrics.scoreFromRmssd(rmssd);

    final confidence = _confidence(
      samples: rr.length,
      durationSec: durationSec,
      artifactPct: clean.artifactPct,
      estimated: estimated,
      meanHr: meanHr,
    );

    return HrvMetrics(
      sdnnMs: sdnn,
      rmssdMs: rmssd,
      pnn50Pct: pnn50,
      meanHrBpm: meanHr,
      peakToTroughMs: p2t,
      samples: rr.length,
      lfPeakHz: lfPeakHz,
      lfPower: lfPower,
      hfPeakHz: hfPeakHz,
      hfPower: hfPower,
      totalPower: totalPower,
      lfHfRatio: lfHfRatio,
      lfNu: lfNu,
      hfNu: hfNu,
      coherenceRatio: coherenceRatio,
      sd1Ms: sd1,
      sd2Ms: sd2,
      sd1Sd2Ratio: sd1Sd2,
      hrvScore: score,
      artifactsRemoved: clean.removed,
      artifactsInterpolated: clean.interpolated,
      percentArtifactual: clean.artifactPct,
      durationSec: durationSec,
      rrSource: rrSource,
      confidence: confidence,
    );
  }

  /// Pulizia RR con gate fisiologico + detection spike rispetto a una MEDIANA
  /// MOBILE (più robusta del solo battito precedente, che incatenava i
  /// rigetti dopo uno step legittimo). Interpolazione lineare per gap singoli,
  /// rimozione per burst.
  ///
  /// Per [estimated]==true (RR da HR a 1 Hz) la soglia è più larga: la
  /// quantizzazione, non l'ectopia, è la sorgente di errore dominante.
  static CleaningResult _clean(List<RrInterval> raw, {required bool estimated}) {
    if (raw.isEmpty) return const CleaningResult([], 0, 0);

    // Fase 1: scarto fisiologico (RR impossibili).
    final phys = raw.where((r) => r.isPhysiological).toList();
    final removedPhys = raw.length - phys.length;
    if (phys.isEmpty) return CleaningResult(const [], removedPhys, 0);

    final threshold = estimated ? 0.30 : 0.20;

    final out = <RrInterval>[phys.first];
    final recent = <int>[phys.first.ms]; // finestra per la mediana mobile
    var removed = removedPhys;
    var interpolated = 0;
    var consecutiveBad = 0;

    for (var i = 1; i < phys.length; i++) {
      final ref = _median(recent);
      final cur = phys[i].ms;
      final diffPct = (cur - ref).abs() / ref;

      if (diffPct > threshold) {
        consecutiveBad++;
        if (consecutiveBad == 1 && i + 1 < phys.length) {
          // Gap singolo: interpolazione lineare fra mediana e prossimo buono.
          final next = phys[i + 1].ms;
          final mid = ((ref + next) / 2).round();
          if ((mid - ref).abs() / ref <= threshold + 0.10) {
            out.add(RrInterval(timestamp: phys[i].timestamp, ms: mid));
            _pushRecent(recent, mid);
            interpolated++;
            continue;
          }
        }
        removed++;
      } else {
        consecutiveBad = 0;
        out.add(phys[i]);
        _pushRecent(recent, cur);
      }
    }
    return CleaningResult(out, removed, interpolated);
  }

  static void _pushRecent(List<int> recent, int v) {
    recent.add(v);
    if (recent.length > 5) recent.removeAt(0);
  }

  static double _median(List<int> xs) {
    if (xs.isEmpty) return 0;
    final s = [...xs]..sort();
    final n = s.length;
    return n.isOdd
        ? s[n ~/ 2].toDouble()
        : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
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

  /// Periodogramma di Lomb-Scargle (adatto a serie campionate in modo non
  /// uniforme, come gli RR) su [fromHz, toHz] con [steps] punti.
  ///
  /// Ritorna la lista completa di (freqHz, power): esposta pubblicamente così
  /// che la UI possa disegnare lo spettro PSD e il resto del modulo possa
  /// integrare le potenze di banda. Vuota se < 20 campioni.
  static List<(double, double)> spectrum(
    List<RrInterval> rr, {
    double fromHz = 0.04,
    double toHz = 0.40,
    int steps = 96,
  }) {
    if (rr.length < 20 || steps < 2) return const [];
    final t0 = rr.first.timestamp.millisecondsSinceEpoch / 1000.0;
    final ts = rr
        .map((e) => e.timestamp.millisecondsSinceEpoch / 1000.0 - t0)
        .toList(growable: false);
    final vals = rr.map((e) => e.ms.toDouble()).toList(growable: false);
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final centered = vals.map((v) => v - mean).toList(growable: false);

    final out = <(double, double)>[];
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
      if (cc == 0 || ss == 0) {
        out.add((f, 0.0));
        continue;
      }
      final power = 0.5 * ((sCos * sCos) / cc + (sSin * sSin) / ss);
      out.add((f, power));
    }
    return out;
  }

  /// Potenza integrata (trapezi) del periodogramma fra [lo] e [hi] Hz.
  static double _bandPower(List<(double, double)> spec, double lo, double hi) {
    if (spec.length < 2) return 0.0;
    var sum = 0.0;
    for (var i = 1; i < spec.length; i++) {
      final f0 = spec[i - 1].$1, f1 = spec[i].$1;
      final p0 = spec[i - 1].$2, p1 = spec[i].$2;
      // Porzione di [f0,f1] dentro [lo,hi].
      final a = f0 < lo ? lo : f0;
      final b = f1 > hi ? hi : f1;
      if (b <= a || f1 == f0) continue;
      double interp(double f) => p0 + (p1 - p0) * (f - f0) / (f1 - f0);
      sum += 0.5 * (interp(a) + interp(b)) * (b - a);
    }
    return sum;
  }

  /// Frequenza del picco di potenza entro [lo, hi].
  static double _peakFreq(List<(double, double)> spec, double lo, double hi) {
    var bestF = 0.0, bestP = 0.0;
    for (final (f, p) in spec) {
      if (f >= lo && f <= hi && p > bestP) {
        bestP = p;
        bestF = f;
      }
    }
    return bestF;
  }

  /// Coherence ratio: potenza nel picco dominante (±0.015 Hz) / potenza
  /// residua. Alto = oscillazione concentrata in un picco netto (respiro
  /// coerente). 0 se non c'è picco o potenza.
  static double _coherence(
    List<(double, double)> spec,
    double peakHz,
    double totalPower,
  ) {
    if (spec.isEmpty || totalPower <= 0 || peakHz <= 0) return 0.0;
    final peakWin = _bandPower(spec, peakHz - 0.015, peakHz + 0.015);
    final rest = totalPower - peakWin;
    return rest > 0 ? peakWin / rest : 0.0;
  }

  static HrvConfidence _confidence({
    required int samples,
    required double durationSec,
    required double artifactPct,
    required bool estimated,
    required double meanHr,
  }) {
    // Troppo corta/scarsa per qualunque metrica stabile (la guida richiede
    // >=60s per il time-domain ultra-short).
    if (samples < 30 || durationSec < 30) return HrvConfidence.insufficient;
    // Alta % artefatti, oppure RR stimati ad alta HR (la quantizzazione 1 Hz
    // rivaleggia con la vera HRV battito-battito).
    if (artifactPct >= 15 || (estimated && meanHr >= 80)) {
      return HrvConfidence.low;
    }
    // Stima da HR 1 Hz, o finestra < 2 min, o artefatti moderati.
    if (artifactPct >= 5 || estimated || durationSec < 120) {
      return HrvConfidence.moderate;
    }
    // Solo RR nativi, puliti e abbastanza lunghi possono dirsi "alta".
    return HrvConfidence.high;
  }
}
