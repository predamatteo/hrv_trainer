import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session_models.dart';

/// Helper visuali/numerici condivisi fra lo Storico e il cruscotto "Andamento
/// HRV". Estratti da history_screen così entrambe le schermate li usano senza
/// creare una dipendenza diretta fra feature.

/// Colore stabile per tag: distingue contesti fisiologicamente diversi sul
/// trend (un post-workout col vago momentaneamente depresso NON va letto sulla
/// stessa scala di una lettura mattutina a riposo). I colori sono fissi e
/// indipendenti dal seed Material 3 per restare riconoscibili anche fra temi
/// diversi; tinte sature ma leggibili sia in light che in dark.
Color tagColor(SessionTag tag) => switch (tag) {
      SessionTag.morning => const Color(0xFFF59E0B), // ambra alba
      SessionTag.preWorkout => const Color(0xFF3B82F6), // blu
      SessionTag.postWorkout => const Color(0xFFEF4444), // rosso carico
      SessionTag.sleep => const Color(0xFF8B5CF6), // viola notte
      SessionTag.stress => const Color(0xFFF97316), // arancio allerta
      SessionTag.recovery => const Color(0xFF22C55E), // verde recupero
      SessionTag.general => const Color(0xFF64748B), // grigio neutro
    };

/// Colore del pallino qualità segnale dalla % di artefatti: <5 verde, <15
/// ambra, altrimenti rosso. Stesse soglie con cui HrvCalculator declassa la
/// confidenza, così dot e label restano coerenti.
Color qualityColor(double artifactPct) {
  if (artifactPct < 5) return const Color(0xFF22C55E);
  if (artifactPct < 15) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

/// ln(RMSSD) robusto: lnRMSSD è la trasformazione standard per normalizzare la
/// distribuzione fortemente skewed dell'RMSSD (la baseline readiness lavora in
/// questo spazio). Per RMSSD <= 0 ritorna null così il punto viene escluso dal
/// trend invece di propagare un -inf nel grafico.
double? lnRmssdOf(Session s) {
  final v = s.metrics.rmssdMs;
  if (v <= 0) return null;
  return math.log(v);
}
