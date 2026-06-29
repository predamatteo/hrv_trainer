import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/hrv/breathing_pacer.dart';

/// Orb respiratorio del mockup: sfera con gradiente inspira→espira che pulsa
/// sull'[amplitude], alone sfocato che respira con essa e arco di progresso
/// della fase corrente. L'etichetta ("Inspira"/"Espira"…) è bianca con ombra.
///
/// API invariata rispetto alla versione precedente: riceve [amplitude] (0..1),
/// [phase], [phaseProgress] e i colori delle due fasi.
class BreathingOrb extends StatelessWidget {
  final double amplitude;
  final BreathingPhase phase;
  final double phaseProgress;
  final double size;
  final Color inhaleColor;
  final Color exhaleColor;

  const BreathingOrb({
    super.key,
    required this.amplitude,
    required this.phase,
    required this.phaseProgress,
    this.size = 280,
    // Colori sempre passati dai call site (token inhale/exhale): nessun default
    // hardcoded, così l'orb resta on-brand in light e dark senza esadecimali.
    required this.inhaleColor,
    required this.exhaleColor,
  });

  @override
  Widget build(BuildContext context) {
    final fontSize = (size * 0.12).clamp(16.0, 26.0);
    // Lo screen reader annuncia "Guida al respiro: Inspira/Espira/…"; la sfera
    // dipinta e l'etichetta interna sono decorative → escluse per non duplicare.
    return Semantics(
      label: 'Guida al respiro',
      value: _label(phase),
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _OrbPainter(
              amplitude: amplitude.clamp(0.0, 1.0),
              phaseProgress: phaseProgress,
              inhaleColor: inhaleColor,
              exhaleColor: exhaleColor,
            ),
            child: Center(
              child: Text(
                _label(phase),
                style: TextStyle(
                  fontFamily: 'Figtree',
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  shadows: const [
                    Shadow(
                      color: Color(0x73002A2D),
                      blurRadius: 10,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _label(BreathingPhase p) => switch (p) {
    BreathingPhase.inhale => 'Inspira',
    BreathingPhase.exhale => 'Espira',
    BreathingPhase.holdAfterInhale => 'Trattieni',
    BreathingPhase.holdAfterExhale => 'Pausa',
  };
}

class _OrbPainter extends CustomPainter {
  final double amplitude;
  final double phaseProgress;
  final Color inhaleColor;
  final Color exhaleColor;

  _OrbPainter({
    required this.amplitude,
    required this.phaseProgress,
    required this.inhaleColor,
    required this.exhaleColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rMax = size.shortestSide / 2;
    // La sfera respira tra ~62% e 100% del raggio disponibile (come il mockup).
    final rInner = rMax * (0.62 + 0.38 * amplitude) * 0.78;

    // Alone sfocato: pulsa di intensità e dimensione con l'amplitude.
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14)
      ..shader = RadialGradient(
        colors: [
          inhaleColor.withValues(alpha: 0.10 + 0.34 * amplitude),
          inhaleColor.withValues(alpha: 0.0),
        ],
        stops: const [0.25, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: rMax));
    canvas.drawCircle(c, rMax * (0.8 + 0.2 * amplitude), glow);

    // Traccia dell'arco (tenue) + arco di progresso della fase.
    final trackR = rMax - 3;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = inhaleColor.withValues(alpha: 0.4);
    canvas.drawCircle(c, trackR, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = inhaleColor;
    final sweep = phaseProgress.clamp(0.0, 1.0) * 2 * math.pi;
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: trackR),
        -math.pi / 2,
        sweep,
        false,
        arc,
      );
    }

    // Sfera con gradiente inspira (alto) → espira (basso).
    final orb = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.35),
        radius: 0.95,
        colors: [inhaleColor, exhaleColor],
      ).createShader(Rect.fromCircle(center: c, radius: rInner));
    canvas.drawCircle(c, rInner, orb);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.amplitude != amplitude ||
      old.phaseProgress != phaseProgress ||
      old.inhaleColor != inhaleColor ||
      old.exhaleColor != exhaleColor;
}
