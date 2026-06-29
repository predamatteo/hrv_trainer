import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Barra gradiente warn→accent→good con un marcatore posizionato sul valore.
/// Usata per la coerenza cardiaca dal vivo (e varianti nei dashboard).
class CoherenceBar extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final double height;

  const CoherenceBar({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 3,
    this.height = 8,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final frac = ((value - min) / (max - min)).clamp(0.0, 1.0);
    // Lo screen reader annuncia "Coerenza cardiaca: <valore>"; la grafica
    // interna (gradiente + marcatore) è decorativa → esclusa.
    return Semantics(
      container: true,
      label: 'Coerenza cardiaca',
      value: value.toStringAsFixed(1),
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return SizedBox(
              height: height + 8,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      height: height,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(height),
                        gradient: LinearGradient(
                          colors: [t.warn, t.accent, t.good],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (frac * w - 1.5).clamp(0.0, w - 3),
                    top: -3,
                    child: Container(
                      width: 3,
                      height: height + 6,
                      decoration: BoxDecoration(
                        color: t.text,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
