import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Anello di prontezza: gauge ad arco (CustomPaint) con sweep colorato per
/// banda, traccia tenue e contenuto centrale libero (punteggio + stato).
/// Distinto da BreathingOrb: questo è un indicatore statico, non un respiro.
/// Anima il disegno da 0 al valore con una curva morbida all'ingresso.
class ReadinessRing extends StatelessWidget {
  /// Progresso 0..1 (es. punteggio / 100).
  final double progress;
  final Color color;
  final Color? trackColor;
  final double size;
  final double strokeWidth;
  final Widget center;
  final bool animate;

  const ReadinessRing({
    super.key,
    required this.progress,
    required this.color,
    required this.center,
    this.trackColor,
    this.size = 120,
    this.strokeWidth = 9,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final track = trackColor ?? context.tokens.line;
    final target = progress.clamp(0.0, 1.0);

    Widget ring(double v) => CustomPaint(
          size: Size.square(size),
          painter: _RingPainter(progress: v, color: color, track: track, stroke: strokeWidth),
          child: SizedBox.square(dimension: size, child: Center(child: center)),
        );

    if (!animate) return ring(target);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => ring(v),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color track;
  final double stroke;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    const start = -math.pi / 2;
    final sweep = progress.clamp(0.0, 1.0) * 2 * math.pi;
    if (sweep > 0) canvas.drawArc(rect, start, sweep, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track || old.stroke != stroke;
}
