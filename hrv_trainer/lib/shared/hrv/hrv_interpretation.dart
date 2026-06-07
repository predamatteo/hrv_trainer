import 'breathing_pacer.dart';
import 'hrv_metrics.dart';
import 'rr_interval.dart';
import 'session_models.dart';

/// Qualità dell'insight: drive il colore della pill nella UI.
enum InsightLevel { excellent, good, fair, poor, neutral }

/// Risultato dell'analisi puntuale di un grafico.
///
/// `headline` è un titolo breve (<= ~40 char) da mostrare in evidenza.
/// `body` è la descrizione dettagliata (1-3 frasi) che spiega cosa si vede.
class ChartInsight {
  final String headline;
  final String body;
  final InsightLevel level;

  const ChartInsight({
    required this.headline,
    required this.body,
    this.level = InsightLevel.neutral,
  });
}

/// Analisi puntuale di un tachogramma a partire dai campioni RR, dalle
/// metriche e dal pattern respiratorio della sessione.
///
/// L'interpretazione si **adatta al contesto** della sessione tramite
/// [tag]: una RSA da 30 ms peak-to-trough è scarsa per una "Morning"
/// (vago dovrebbe essere alto a riposo) ma è ottima per "Post-workout"
/// (vago è fisiologicamente soppresso). Senza calibrazione tag-aware le
/// pill colorate finiscono per spaventare l'utente con "Basso/Discreto"
/// quando i valori sono in realtà appropriati per lo stato fisiologico.
///
/// Per back-compat il default è [SessionTag.general] (soglie storiche).
ChartInsight interpretTachogram({
  required List<RrInterval> rr,
  required HrvMetrics metrics,
  required BreathingPattern pattern,
  required SessionKind kind,
  SessionTag tag = SessionTag.general,
}) {
  if (rr.length < 20 || metrics.samples < 10) {
    return const ChartInsight(
      headline: 'Dati insufficienti',
      body: 'La sessione contiene troppi pochi battiti per descrivere '
          'l\'andamento. Servono almeno ~30s di registrazione pulita.',
      level: InsightLevel.neutral,
    );
  }

  final profile = _profileFor(tag);
  final drift = _hrDriftBpm(rr);
  final p2t = metrics.peakToTroughMs;
  final hasPacer = kind == SessionKind.training ||
      kind == SessionKind.assessment;
  final coherenceHz = hasPacer
      ? (metrics.lfPeakHz - pattern.frequencyHz).abs()
      : null;

  final parts = <String>[];

  // Componente 1: ampiezza RSA (peak-to-trough), tarata sul contesto.
  parts.add(_rsaSentence(p2t, profile));

  // Componente 2: trend HR — semantica tag-specific (post-workout vuole
  // drift positivo, pre-workout è più tollerante).
  parts.add(_driftSentence(drift, tag));

  // Componente 3: coerenza con il respiro guidato (solo se c'è il pacer).
  if (coherenceHz != null) {
    parts.add(_coherenceSentence(
      coherenceHz: coherenceHz,
      pacerBpm: pattern.breathsPerMinute,
      lfPeakHz: metrics.lfPeakHz,
    ));
  }

  // Componente 4: nota su qualità se artefatti rilevanti.
  if (metrics.percentArtifactual >= 10) {
    parts.add(
        'Il ${metrics.percentArtifactual.toStringAsFixed(0)}% di artefatti '
        'potrebbe aver smussato alcune oscillazioni: leggi la forma con '
        'cautela.');
  }

  final headline = _tachogramHeadline(
    p2t: p2t,
    drift: drift,
    coherenceHz: coherenceHz,
    profile: profile,
    tag: tag,
  );
  final level = _tachogramLevel(
    p2t: p2t,
    drift: drift,
    coherenceHz: coherenceHz,
    artifactPct: metrics.percentArtifactual,
    profile: profile,
    tag: tag,
  );

  return ChartInsight(
    headline: headline,
    body: parts.join(' '),
    level: level,
  );
}

/// Analisi puntuale del diagramma di Poincaré in base a SD1, SD2 e ratio.
///
/// Forma della nuvola:
///  - SD1/SD2 < 0.25: "a sigaro" → variabilità dominata dal lungo termine
///    (tipico di respiro lento coerente, ma anche di simpaticotonia se SD2
///    è basso).
///  - 0.25-0.45: ellisse classica equilibrata.
///  - > 0.45: nuvola arrotondata → forte attività vagale battito-battito.
///
/// Non riceve [SessionTag] perché la forma della nuvola è una proprietà
/// geometrica del segnale, indipendente dal contesto fisiologico.
ChartInsight interpretPoincare(HrvMetrics metrics) {
  if (metrics.samples < 10) {
    return const ChartInsight(
      headline: 'Dati insufficienti',
      body: 'Servono più battiti per ottenere una nuvola interpretabile.',
      level: InsightLevel.neutral,
    );
  }

  final sd1 = metrics.sd1Ms;
  final sd2 = metrics.sd2Ms;
  final ratio = metrics.sd1Sd2Ratio;

  final shape = _poincareShape(ratio: ratio, sd1: sd1, sd2: sd2);
  final sd1Reading = _sd1Reading(sd1);
  final sd2Reading = _sd2Reading(sd2);

  final body = '${shape.description} '
      'SD1 ${sd1.toStringAsFixed(1)} ms (${sd1Reading.label.toLowerCase()}) '
      'misura la dispersione perpendicolare alla diagonale, '
      'cioè la variabilità battito-battito di origine vagale. '
      'SD2 ${sd2.toStringAsFixed(1)} ms (${sd2Reading.label.toLowerCase()}) '
      'misura la dispersione lungo la diagonale, '
      'cioè la variabilità lenta complessiva. '
      'Il rapporto SD1/SD2 ${ratio.toStringAsFixed(2)} '
      '${_ratioInterpretation(ratio)}';

  return ChartInsight(
    headline: shape.headline,
    body: body,
    level: _poincareLevel(sd1: sd1, sd2: sd2, ratio: ratio),
  );
}

/// Analisi puntuale dello spettro di potenza (PSD) in base al bilancio
/// LF/HF in unità normalizzate, alla coherence ratio e all'allineamento del
/// picco spettrale con la frequenza del respiro guidato.
///
/// Tre segnali, in ordine di rilevanza per il biofeedback:
///  1. **Coherence** ([HrvMetrics.coherenceRatio]): quanto la potenza è
///     concentrata in un picco netto. Alto = oscillazione cardiaca "pulita",
///     coerente, segno che il respiro sta trascinando il sistema
///     cardiovascolare in risonanza.
///  2. **Allineamento** picco↔respiro: il picco LF dovrebbe cadere sulla
///     [BreathingPattern.frequencyHz]. Se cade altrove, l'ampiezza non è
///     guidata dal respiro.
///  3. **Bilancio LF/HF** (lfNu/hfNu): a respiro lento (~6 bpm, 0.1 Hz) la
///     potenza migra in LF per costruzione — un LF n.u. alto qui NON è
///     "stress simpatico" ma il marker atteso della respirazione di risonanza.
///
/// Il livello è guidato soprattutto da coherence + allineamento: un bilancio
/// "LF dominante" durante il respiro lento è desiderato, non penalizzante.
ChartInsight interpretSpectrum(HrvMetrics m, BreathingPattern p) {
  if (m.samples < 20 || m.totalPower <= 0) {
    return const ChartInsight(
      headline: 'Spettro non disponibile',
      body: 'Servono almeno ~20 battiti puliti per stimare il periodogramma '
          'di Lomb-Scargle. La sessione è troppo corta o troppo rumorosa.',
      level: InsightLevel.neutral,
    );
  }

  final lfNu = m.lfNu;
  final hfNu = m.hfNu;
  final coh = m.coherenceRatio;
  final paceHz = p.frequencyHz;
  // Disallineamento del picco LF rispetto al respiro guidato. Usiamo lfPeakHz
  // perché a ~6 bpm la risonanza vive nella banda LF (0.04-0.15 Hz).
  final alignHz = (m.lfPeakHz - paceHz).abs();
  final peakBpm = m.lfPeakHz * 60;
  final pacerBpm = p.breathsPerMinute;

  final parts = <String>[];

  // Componente 1: bilancio LF/HF n.u. contestualizzato sul respiro lento.
  if (lfNu >= 70) {
    parts.add(
        'La potenza è concentrata nella banda LF (${lfNu.toStringAsFixed(0)}% '
        'vs ${hfNu.toStringAsFixed(0)}% HF): a respiro lento è il profilo '
        'atteso, perché l\'oscillazione di risonanza (~0.1 Hz) cade proprio '
        'in LF, non un segno di stress simpatico.');
  } else if (lfNu >= 50) {
    parts.add(
        'Il bilancio spettrale pende verso LF (${lfNu.toStringAsFixed(0)}% LF '
        '/ ${hfNu.toStringAsFixed(0)}% HF): l\'onda respiratoria lenta inizia '
        'a dominare lo spettro.');
  } else {
    parts.add(
        'La potenza resta sbilanciata verso HF (${hfNu.toStringAsFixed(0)}% HF '
        '/ ${lfNu.toStringAsFixed(0)}% LF): l\'energia è ancora nella banda '
        'respiratoria veloce, segno che il respiro lento non ha ancora '
        'spostato il baricentro spettrale.');
  }

  // Componente 2: forma del picco (coherence ratio).
  if (coh >= 2.5) {
    parts.add(
        'Il picco di potenza è alto e stretto (coherence ${coh.toStringAsFixed(1)}): '
        'l\'oscillazione cardiaca è molto coerente, concentrata in un\'unica '
        'frequenza — la firma della respirazione di risonanza.');
  } else if (coh >= 1.0) {
    parts.add(
        'Il picco è discretamente definito (coherence ${coh.toStringAsFixed(1)}): '
        'c\'è coerenza, ma la potenza è ancora un po\' dispersa attorno alla '
        'frequenza dominante.');
  } else {
    parts.add(
        'Lo spettro è piatto e diffuso (coherence ${coh.toStringAsFixed(1)}): '
        'nessun picco netto domina, l\'oscillazione cardiaca non è ancora '
        'organizzata su una singola frequenza.');
  }

  // Componente 3: allineamento del picco con il pacer.
  if (alignHz <= 0.012) {
    parts.add(
        'Il picco cade a ${m.lfPeakHz.toStringAsFixed(3)} Hz '
        '(${peakBpm.toStringAsFixed(1)} cicli/min), sovrapposto al pacer '
        '(${pacerBpm.toStringAsFixed(1)} bpm): perfetta sincronia '
        'cardio-respiratoria.');
  } else if (alignHz <= 0.025) {
    parts.add(
        'Il picco a ${m.lfPeakHz.toStringAsFixed(3)} Hz '
        '(${peakBpm.toStringAsFixed(1)} cicli/min) è vicino al pacer '
        '(${pacerBpm.toStringAsFixed(1)} bpm) ma non perfettamente '
        'allineato: prova a respirare più in armonia con la guida.');
  } else {
    parts.add(
        'Il picco a ${m.lfPeakHz.toStringAsFixed(3)} Hz '
        '(${peakBpm.toStringAsFixed(1)} cicli/min) è lontano dal pacer '
        '(${pacerBpm.toStringAsFixed(1)} bpm): l\'ampiezza non è ancora '
        'guidata dal respiro.');
  }

  return ChartInsight(
    headline: _spectrumHeadline(coh: coh, alignHz: alignHz, lfNu: lfNu),
    body: parts.join(' '),
    level: _spectrumLevel(coh: coh, alignHz: alignHz),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SPETTRO — helper privati
// ─────────────────────────────────────────────────────────────────────────────

String _spectrumHeadline({
  required double coh,
  required double alignHz,
  required double lfNu,
}) {
  final aligned = alignHz <= 0.012;
  if (coh >= 2.5 && aligned) return 'Risonanza spettrale netta';
  if (coh >= 2.5) return 'Picco coerente ma fuori frequenza';
  if (coh >= 1.0 && aligned) return 'Coerenza in costruzione';
  if (coh >= 1.0) return 'Picco presente, da allineare';
  if (lfNu >= 70) return 'Potenza in LF, picco diffuso';
  return 'Spettro ancora disorganizzato';
}

InsightLevel _spectrumLevel({
  required double coh,
  required double alignHz,
}) {
  final aligned = alignHz <= 0.012;
  final nearby = alignHz <= 0.025;
  if (coh >= 2.5 && aligned) return InsightLevel.excellent;
  if (coh >= 1.5 && nearby) return InsightLevel.good;
  if (coh >= 1.0 || nearby) return InsightLevel.fair;
  return InsightLevel.poor;
}

// ─────────────────────────────────────────────────────────────────────────────
// PROFILO TAG — soglie e narrative tarate sul contesto fisiologico
// ─────────────────────────────────────────────────────────────────────────────

/// Soglie di peak-to-trough RSA per le 4 fasce qualitative.
///
/// Per stati con vago soppresso (postWorkout) le soglie sono abbassate:
/// una RSA da 35 ms post-workout è già un ottimo segnale di recovery,
/// mentre la stessa RSA in un Morning sarebbe "modesta".
class _TachogramProfile {
  /// Peak-to-trough (ms) sopra cui consideriamo l'RSA "eccellente".
  final double p2tExcellent;

  /// Soglia "buona".
  final double p2tGood;

  /// Soglia "discreta". Sotto è considerato piatto/scarso.
  final double p2tFair;

  /// Frase che caratterizza qualitativamente il contesto, inserita nella
  /// sentence RSA dopo "buon tono vagale". Es. "in un check-in mattutino
  /// di buon recupero".
  final String contextNote;

  const _TachogramProfile({
    required this.p2tExcellent,
    required this.p2tGood,
    required this.p2tFair,
    required this.contextNote,
  });
}

_TachogramProfile _profileFor(SessionTag tag) {
  return switch (tag) {
    // Soglie standard "a riposo". Manteniamo i valori storici per general
    // e morning così l'esperienza di chi usa l'app a default resta invariata.
    SessionTag.general => const _TachogramProfile(
        p2tExcellent: 80,
        p2tGood: 50,
        p2tFair: 25,
        contextNote: '',
      ),
    SessionTag.morning => const _TachogramProfile(
        p2tExcellent: 80,
        p2tGood: 50,
        p2tFair: 25,
        contextNote: 'al risveglio',
      ),
    // Vago soppresso: il workout appena fatto deprime la HRV per minuti-ore.
    // Soglie abbassate ~35% per non chiamare "Basso" valori fisiologici.
    SessionTag.postWorkout => const _TachogramProfile(
        p2tExcellent: 50,
        p2tGood: 30,
        p2tFair: 15,
        contextNote: 'post-workout',
      ),
    // Pre-workout: lo stato è intermedio, con anticipazione che spesso
    // alza un po' il simpatico. Soglie ~20% sotto general.
    SessionTag.preWorkout => const _TachogramProfile(
        p2tExcellent: 65,
        p2tGood: 40,
        p2tFair: 20,
        contextNote: 'in fase di priming',
      ),
    // Stress: HRV è la metrica che VUOI vedere salire durante la sessione.
    // Soglie morbide perché stiamo trattando uno stato di partenza basso.
    SessionTag.stress => const _TachogramProfile(
        p2tExcellent: 60,
        p2tGood: 40,
        p2tFair: 20,
        contextNote: 'in de-escalation',
      ),
    // Recovery/sleep: ci aspettiamo HRV elevata. Soglie alzate ~25% così
    // un "Buono" qui equivale a un "Eccellente" in stati attivi.
    SessionTag.recovery => const _TachogramProfile(
        p2tExcellent: 100,
        p2tGood: 65,
        p2tFair: 30,
        contextNote: 'in un giorno di recupero',
      ),
    SessionTag.sleep => const _TachogramProfile(
        p2tExcellent: 100,
        p2tGood: 65,
        p2tFair: 30,
        contextNote: 'prima del sonno',
      ),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// TACHOGRAM — helper privati
// ─────────────────────────────────────────────────────────────────────────────

/// Differenza HR (bpm) tra prima e seconda metà della sessione.
/// Positivo = HR scesa (rilassamento), negativo = HR salita (attivazione).
double _hrDriftBpm(List<RrInterval> rr) {
  if (rr.length < 10) return 0;
  final half = rr.length ~/ 2;
  final firstMs = rr.sublist(0, half).map((e) => e.ms).fold<int>(0, _sum);
  final secondMs =
      rr.sublist(half).map((e) => e.ms).fold<int>(0, _sum);
  final firstMean = firstMs / half;
  final secondMean = secondMs / (rr.length - half);
  final firstBpm = 60000.0 / firstMean;
  final secondBpm = 60000.0 / secondMean;
  return firstBpm - secondBpm;
}

int _sum(int a, int b) => a + b;

String _rsaSentence(double p2t, _TachogramProfile profile) {
  final ctx = profile.contextNote.isEmpty ? '' : ' ${profile.contextNote}';
  if (p2t >= profile.p2tExcellent) {
    return 'Le ondulazioni RR sono molto ampie (~${p2t.toStringAsFixed(0)} ms '
        'tra picco e valle): segno di una forte aritmia sinusale respiratoria, '
        'cioè di una marcata accelerazione in inspirazione e rallentamento in '
        'espirazione, indicatore di ottimo tono vagale$ctx.';
  }
  if (p2t >= profile.p2tGood) {
    return 'Si vedono onde respiratorie ben definite (~${p2t.toStringAsFixed(0)} '
        'ms peak-to-trough), con RR che sale in inspirazione e scende in '
        'espirazione: RSA presente e di buona ampiezza$ctx.';
  }
  if (p2t >= profile.p2tFair) {
    return 'L\'ondulazione respiratoria è modesta (~${p2t.toStringAsFixed(0)} '
        'ms peak-to-trough): la RSA è visibile ma poco ampia, segnale di '
        'attivazione simpatica o di respiro non ancora ben modulato$ctx.';
  }
  return 'Tracciato piatto (peak-to-trough ~${p2t.toStringAsFixed(0)} ms): '
      'le oscillazioni respiratorie sono quasi assenti, tipico di stress, '
      'fatica o respiro troppo superficiale per modulare il battito$ctx.';
}

String _driftSentence(double drift, SessionTag tag) {
  final abs = drift.abs();
  if (abs < 2) {
    return 'La frequenza cardiaca media resta stabile tra inizio e fine '
        'sessione (variazione di ${abs.toStringAsFixed(1)} bpm).';
  }
  final falling = drift > 0; // RR cresce → bpm scende
  final magnitude = abs >= 6 ? 'marcato' : 'progressivo';

  if (falling) {
    return switch (tag) {
      SessionTag.postWorkout =>
        'HR scende di ${abs.toStringAsFixed(1)} bpm tra le due metà: '
            'recovery vagale in corso, segnale positivo dopo il workout.',
      SessionTag.stress =>
        'HR scende di ${abs.toStringAsFixed(1)} bpm in modo $magnitude: '
            'la de-escalation sta funzionando, il simpatico sta cedendo terreno.',
      SessionTag.sleep =>
        'HR scende di ${abs.toStringAsFixed(1)} bpm: la dominanza '
            'parasimpatica sta crescendo, preparazione al sonno ottimale.',
      SessionTag.preWorkout =>
        'HR scende di ${abs.toStringAsFixed(1)} bpm: stai disattivando '
            'il simpatico, buon priming pre-workout.',
      SessionTag.recovery =>
        'HR scende di ${abs.toStringAsFixed(1)} bpm: recupero attivo, '
            'sessione efficace nel rest day.',
      _ =>
        'Si nota un calo $magnitude della HR (-${drift.toStringAsFixed(1)} bpm '
            'dalla prima alla seconda metà): il corpo si è rilassato durante la '
            'pratica, segno di attivazione parasimpatica.',
    };
  }

  return switch (tag) {
    SessionTag.postWorkout =>
      'La HR è salita di ${abs.toStringAsFixed(1)} bpm: insolito post-workout, '
          'il vago non sta ancora prendendo il sopravvento — prova a respirare '
          'più lentamente o concediti più tempo prima della sessione.',
    SessionTag.stress =>
      'La HR è salita di ${abs.toStringAsFixed(1)} bpm: il sistema non si '
          'sta calmando. Considera una sessione di mantenimento, senza '
          'aspettarti grandi cambi oggi.',
    SessionTag.sleep =>
      'La HR è salita di ${abs.toStringAsFixed(1)} bpm prima di dormire: '
          'evita stimolanti e schermi nelle ore precedenti alla sessione.',
    SessionTag.preWorkout =>
      'La HR è salita di ${abs.toStringAsFixed(1)} bpm: anticipazione del '
          'workout fisiologica, ma cerca di mantenere il respiro neutro per '
          'massimizzare il priming vagale.',
    SessionTag.recovery =>
      'La HR è salita di ${abs.toStringAsFixed(1)} bpm in un rest day: '
          'controlla se ci sono stress residui o cattiva qualità del sonno.',
    _ =>
      'La HR è salita in modo $magnitude (+${abs.toStringAsFixed(1)} bpm tra '
          'le due metà): possibile attivazione (pensieri, tensione, sforzo '
          'respiratorio eccessivo).',
  };
}

String _coherenceSentence({
  required double coherenceHz,
  required double pacerBpm,
  required double lfPeakHz,
}) {
  final peakBpm = lfPeakHz * 60;
  if (coherenceHz <= 0.012) {
    return 'Il picco di potenza HRV cade a ${lfPeakHz.toStringAsFixed(3)} Hz '
        '(${peakBpm.toStringAsFixed(1)} cicli/min), sostanzialmente '
        'sovrapposto al pacer (${pacerBpm.toStringAsFixed(1)} bpm): la '
        'sincronia cardio-respiratoria è ottima.';
  }
  if (coherenceHz <= 0.025) {
    return 'Il picco HRV è a ${lfPeakHz.toStringAsFixed(3)} Hz '
        '(${peakBpm.toStringAsFixed(1)} cicli/min) contro un pacer a '
        '${pacerBpm.toStringAsFixed(1)} bpm: coerenza presente ma non '
        'perfetta, prova a respirare più in armonia con la guida.';
  }
  return 'Il picco HRV cade a ${lfPeakHz.toStringAsFixed(3)} Hz '
      '(${peakBpm.toStringAsFixed(1)} cicli/min), lontano dal pacer a '
      '${pacerBpm.toStringAsFixed(1)} bpm: il respiro guidato non sta '
      'ancora trascinando il sistema cardiovascolare.';
}

String _tachogramHeadline({
  required double p2t,
  required double drift,
  required double? coherenceHz,
  required _TachogramProfile profile,
  required SessionTag tag,
}) {
  final coherent = coherenceHz != null && coherenceHz <= 0.012;
  final falling = drift > 0;

  // Headline tag-specific per casi "speciali" dove il drift è il segnale
  // più rilevante (postWorkout/stress vogliono drift positivo).
  if (tag == SessionTag.postWorkout && falling && drift >= 4 &&
      p2t >= profile.p2tGood) {
    return 'Recovery vagale efficace';
  }
  if (tag == SessionTag.stress && falling && drift >= 4) {
    return 'De-escalation in corso';
  }
  if (tag == SessionTag.sleep && falling && p2t >= profile.p2tGood) {
    return 'Sistema pronto al sonno';
  }
  if (tag == SessionTag.preWorkout && p2t >= profile.p2tGood) {
    return 'Priming vagale completato';
  }

  if (p2t >= profile.p2tExcellent && drift > 0) return 'Ampia RSA e buon rilassamento';
  if (p2t >= profile.p2tGood && coherent) return 'Onde respiratorie coerenti';
  if (p2t >= profile.p2tGood && drift > 2) return 'RSA presente, HR in calo';
  if (p2t >= profile.p2tGood) return 'RSA ben definita';
  if (p2t >= profile.p2tFair && drift > 2) return 'Modulazione moderata, rilassamento';
  if (p2t >= profile.p2tFair) return 'Modulazione respiratoria modesta';
  if (drift < -4) return 'Tracciato attivato in salita';
  return 'Oscillazioni ridotte';
}

InsightLevel _tachogramLevel({
  required double p2t,
  required double drift,
  required double? coherenceHz,
  required double artifactPct,
  required _TachogramProfile profile,
  required SessionTag tag,
}) {
  if (artifactPct >= 20) return InsightLevel.poor;
  final coherent = coherenceHz != null && coherenceHz <= 0.012;
  final falling = drift > 0;

  // Bonus tag-specifici: per stati dove il drift HR positivo è IL segnale
  // chiave (recovery in atto), promuoviamo il livello.
  if (tag == SessionTag.postWorkout && falling && drift >= 4 &&
      p2t >= profile.p2tGood) {
    return InsightLevel.excellent;
  }
  if (tag == SessionTag.stress && falling && drift >= 4 &&
      p2t >= profile.p2tFair) {
    return InsightLevel.excellent;
  }

  if (p2t >= profile.p2tExcellent && drift > -2) return InsightLevel.excellent;
  if (p2t >= profile.p2tGood && (coherent || drift > 0)) return InsightLevel.good;
  if (p2t >= profile.p2tGood) return InsightLevel.good;
  if (p2t >= profile.p2tFair) return InsightLevel.fair;
  return InsightLevel.poor;
}

// ─────────────────────────────────────────────────────────────────────────────
// POINCARÉ — helper privati
// ─────────────────────────────────────────────────────────────────────────────

class _PoincareShape {
  final String headline;
  final String description;
  const _PoincareShape(this.headline, this.description);
}

_PoincareShape _poincareShape({
  required double ratio,
  required double sd1,
  required double sd2,
}) {
  // Nuvola degenere: pochi punti coincidenti.
  if (sd1 < 3 && sd2 < 5) {
    return const _PoincareShape(
      'Nuvola compressa',
      'I punti sono quasi tutti sovrapposti: la variabilità è '
          'pressoché assente, segno di un battito molto regolare (possibile '
          'stress, fatica o filtraggio aggressivo del dispositivo).',
    );
  }
  if (ratio < 0.25) {
    return const _PoincareShape(
      'Nuvola a sigaro lungo la diagonale',
      'La nuvola è schiacciata e allungata lungo la diagonale RR n = RR '
          'n+1: la variabilità è dominata dalle oscillazioni lente (SD2 ≫ '
          'SD1). In una sessione di respiro guidato lento è un buon segno '
          'di coerenza; a riposo libero può indicare invece un eccesso di '
          'tono simpatico.',
    );
  }
  if (ratio < 0.45) {
    return const _PoincareShape(
      'Ellisse classica equilibrata',
      'La nuvola forma un\'ellisse ben definita lungo la diagonale, con '
          'una larghezza perpendicolare significativa: bilanciamento '
          'autonomico tipico, con componente parasimpatica e simpatica '
          'entrambe presenti.',
    );
  }
  if (ratio < 0.7) {
    return const _PoincareShape(
      'Nuvola larga e arrotondata',
      'La nuvola è quasi tonda: la variabilità battito-battito (SD1) è '
          'molto vicina a quella complessiva (SD2), segno di forte attività '
          'vagale e di un cuore reattivo da un battito all\'altro.',
    );
  }
  return const _PoincareShape(
    'Nuvola dispersa',
    'La nuvola è molto rotonda e diffusa: variabilità battito-battito '
        'altissima. Spesso è un ottimo segno parasimpatico, ma con SD1 ≥ '
        'SD2 è bene controllare che non ci siano artefatti residui che '
        'gonfiano il dato.',
  );
}

String _ratioInterpretation(double ratio) {
  if (ratio < 0.25) return 'conferma la forma a sigaro.';
  if (ratio < 0.45) return 'è nel range tipico di una persona a riposo.';
  if (ratio < 0.7) return 'indica una dominanza vagale marcata.';
  return 'è insolitamente alto: ricontrolla la qualità del segnale.';
}

class _Reading {
  final String label;
  const _Reading(this.label);
}

_Reading _sd1Reading(double sd1) {
  if (sd1 >= 60) return const _Reading('Elevato');
  if (sd1 >= 30) return const _Reading('Buono');
  if (sd1 >= 15) return const _Reading('Nella norma');
  return const _Reading('Basso');
}

_Reading _sd2Reading(double sd2) {
  if (sd2 >= 150) return const _Reading('Molto alto');
  if (sd2 >= 80) return const _Reading('Buono');
  if (sd2 >= 40) return const _Reading('Nella norma');
  return const _Reading('Basso');
}

InsightLevel _poincareLevel({
  required double sd1,
  required double sd2,
  required double ratio,
}) {
  if (sd1 < 5 && sd2 < 10) return InsightLevel.poor;
  if (sd1 >= 40 && ratio >= 0.25 && ratio <= 0.7) {
    return InsightLevel.excellent;
  }
  if (sd1 >= 20) return InsightLevel.good;
  if (sd1 >= 10) return InsightLevel.fair;
  return InsightLevel.poor;
}
