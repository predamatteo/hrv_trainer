import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Header impilato riutilizzabile: indietro + titolo (+ sottotitolo) + azione.
/// Sostituisce l'AppBar piatta dove serve titolo + sottotitolo (es.
/// "Risonanza · 6,0 respiri/min", "Check-in mattutino · lettura di 4 min").
class HeaderBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showBack;
  final VoidCallback? onBack;
  final Widget? trailing;

  /// Titolo centrato (header di sessione) vs allineato a sinistra (dettagli).
  final bool centerTitle;

  /// Titolo compatto (14) invece di 17, per gli header densi.
  final bool dense;

  const HeaderBar({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = true,
    this.onBack,
    this.trailing,
    this.centerTitle = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final titleStyle = (dense ? text.titleSmall : text.titleMedium)?.copyWith(fontWeight: FontWeight.w600);

    final back = showBack
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            color: t.dim,
            visualDensity: VisualDensity.compact,
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          )
        : const SizedBox(width: 40);

    final titleColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centerTitle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(title, style: titleStyle, textAlign: centerTitle ? TextAlign.center : TextAlign.start),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            textAlign: centerTitle ? TextAlign.center : TextAlign.start,
            style: text.bodySmall?.copyWith(color: t.faint),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          back,
          if (centerTitle)
            Expanded(child: Center(child: titleColumn))
          else ...[
            const SizedBox(width: 4),
            Expanded(child: titleColumn),
          ],
          trailing ?? const SizedBox(width: 40),
        ],
      ),
    );
  }
}
