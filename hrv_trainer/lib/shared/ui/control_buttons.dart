import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Pulsante circolare per i controlli di sessione (stop/pausa/play).
/// `primary: true` = cerchio petrolio grande con ombra (azione principale);
/// altrimenti cerchio tonale piccolo (azione secondaria).
class CircleControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  final double size;
  final String? tooltip;

  const CircleControlButton({
    super.key,
    required this.icon,
    this.onTap,
    this.primary = false,
    this.size = 54,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget button = Material(
      color: primary ? t.primary : t.tonal,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: size * 0.42,
            color: primary ? t.onPrimary : t.dim,
          ),
        ),
      ),
    );
    if (primary) {
      button = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: t.primary.withValues(alpha: 0.35),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: button,
      );
    }
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
