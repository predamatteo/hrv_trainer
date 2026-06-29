import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Riquadro informativo on-brand: icona + testo su superficie tonale. Per note
/// gentili, spiegazioni di un concetto o suggerimenti — mai allarmistico
/// (niente toni alert). Usa i token, così resta calmo in light e dark.
class Callout extends StatelessWidget {
  final IconData icon;
  final String text;
  const Callout({super.key, this.icon = Icons.info_outline, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: t.dim, height: 1.4);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.tonal,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: t.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
