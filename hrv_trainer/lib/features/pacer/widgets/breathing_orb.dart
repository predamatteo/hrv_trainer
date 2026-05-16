import 'package:flutter/material.dart';

import '../../../shared/hrv/breathing_pacer.dart';

/// Cerchio animato che si espande/contrae seguendo lo stato del pacer.
/// Riceve un [amplitude] (0..1) e una [phase] e disegna:
///  - un cerchio esterno statico con glow
///  - un cerchio interno che cresce/decresce sull'amplitude
///  - un ring di progresso per la fase corrente
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
    this.inhaleColor = const Color(0xFF4FB3A9),
    this.exhaleColor = const Color(0xFF2E7D78),
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (phase) {
      BreathingPhase.inhale => inhaleColor,
      BreathingPhase.exhale => exhaleColor,
      _ => Color.lerp(inhaleColor, exhaleColor, 0.5)!,
    };
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _OrbPainter(
          amplitude: amplitude,
          phaseProgress: phaseProgress,
          color: color,
        ),
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w300) ??
                const TextStyle(fontSize: 28),
            child: Text(_label(phase)),
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
  final Color color;

  _OrbPainter({
    required this.amplitude,
    required this.phaseProgress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final rMax = size.shortestSide / 2;
    final rInner = rMax * (0.35 + 0.55 * amplitude);

    // Glow esterno
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromCircle(center: c, radius: rMax));
    canvas.drawCircle(c, rMax, glow);

    // Ring anello sottile
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.25);
    canvas.drawCircle(c, rMax - 6, ring);

    // Orb riempito
    final orb = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.95),
          color.withValues(alpha: 0.6),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: rInner));
    canvas.drawCircle(c, rInner, orb);

    // Progresso di fase (arco in alto)
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = color;
    final rect = Rect.fromCircle(center: c, radius: rMax - 6);
    const startAngle = -1.5708; // -pi/2
    final sweep = phaseProgress.clamp(0.0, 1.0) * 6.2832;
    canvas.drawArc(rect, startAngle, sweep, false, arc);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) =>
      oldDelegate.amplitude != amplitude ||
      oldDelegate.phaseProgress != phaseProgress ||
      oldDelegate.color != color;
}
