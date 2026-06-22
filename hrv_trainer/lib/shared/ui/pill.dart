import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Tonalità semantica di una [Pill]: determina sfondo + colore contenuto.
enum PillTone { neutral, primary, good, warn, alert, accent }

/// Badge/chip a stadio (raggio 999). Sostituisce i container inline ad-hoc
/// (status badge, z-score chip, tag, qualità segnale…). Cifre tabellari sui
/// numerici via il textTheme.
class Pill extends StatelessWidget {
  final String? label;

  /// Contenuto custom (es. testo con parti in grassetto). Ha priorità su [label].
  final Widget? child;

  final IconData? icon;
  final Color? iconColor;

  /// Widget iniziale (es. un [Dot]). Ha priorità su [icon].
  final Widget? leading;

  final PillTone tone;
  final bool dense;
  final VoidCallback? onTap;

  const Pill({
    super.key,
    this.label,
    this.child,
    this.icon,
    this.iconColor,
    this.leading,
    this.tone = PillTone.neutral,
    this.dense = false,
    this.onTap,
  });

  static ({Color bg, Color fg}) colorsFor(PillTone tone, AppTokens t) {
    return switch (tone) {
      PillTone.neutral => (bg: t.tonal, fg: t.dim),
      PillTone.primary => (bg: t.primaryTonal, fg: t.primary),
      PillTone.good => (bg: t.goodTonal, fg: t.good),
      PillTone.warn => (bg: t.warnTonal, fg: t.warn),
      PillTone.alert => (bg: t.alertTonal, fg: t.alert),
      PillTone.accent => (bg: t.accentTonal, fg: t.accent),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = colorsFor(tone, t);
    final style =
        (dense ? Theme.of(context).textTheme.labelMedium : Theme.of(context).textTheme.labelLarge)
            ?.copyWith(color: c.fg);

    final children = <Widget>[];
    if (leading != null) {
      children.add(leading!);
      children.add(const SizedBox(width: 6));
    } else if (icon != null) {
      children.add(Icon(icon, size: dense ? 15 : 17, color: iconColor ?? c.fg));
      children.add(const SizedBox(width: 6));
    }
    if (child != null) {
      children.add(DefaultTextStyle.merge(style: style, child: child!));
    } else if (label != null) {
      children.add(Flexible(child: Text(label!, style: style, overflow: TextOverflow.ellipsis)));
    }

    Widget pill = Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
    if (onTap != null) {
      pill = InkWell(borderRadius: BorderRadius.circular(999), onTap: onTap, child: pill);
    }
    return pill;
  }
}

/// Pallino colorato (indicatore di stato), tipicamente come `leading` di [Pill].
class Dot extends StatelessWidget {
  final Color color;
  final double size;
  const Dot(this.color, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
