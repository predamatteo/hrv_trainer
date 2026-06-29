import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'app_card.dart';
import 'pill.dart';

/// Voce-pratica tappabile del design system, in due forme:
/// - [compact] `true` (griglia Home): tile verticale a icona grande, pensata per
///   la griglia a 2 colonne; opzione [tinted] per la superficie evidenziata.
/// - [compact] `false` (hub Sessione): riga descrittiva con icona in contenitore,
///   sottotitolo ampio e chevron.
///
/// Centralizza ciò che le due viste condividevano (superficie `AppCard`, colori
/// del tono via [Pill.colorsFor], tipografia, tap), eliminando i due widget
/// `_PracticeTile`/`_PracticeCard` duplicati.
class PracticeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final PillTone tone;
  final VoidCallback onTap;

  /// Forma compatta verticale (Home) vs riga descrittiva (Sessione).
  final bool compact;

  /// Solo in modalità compatta: superficie primary-tonal evidenziata.
  final bool tinted;

  const PracticeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
    required this.onTap,
    this.compact = false,
    this.tinted = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final c = Pill.colorsFor(tone, t);

    if (compact) {
      return AppCard(
        onTap: onTap,
        color: tinted ? t.primaryTonal : t.tonal,
        border: Colors.transparent,
        radius: 22,
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: 86,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, size: 27, color: c.fg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: t.dim),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration:
                BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: c.fg, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                const SizedBox(height: 3),
                Text(subtitle, style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: t.faint),
        ],
      ),
    );
  }
}
