import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Voce di glossario: termine interno → significato in lingua-utente.
class GlossaryEntry {
  final String term;
  final String meaning;
  const GlossaryEntry(this.term, this.meaning);
}

/// Icona "info" che apre un foglio con un piccolo glossario in lingua-utente.
/// Affordance puntuale per spiegare i termini tecnici (HRV, coerenza, prontezza,
/// risonanza…) senza riempire la UI di testo — vedi il vocabolario in
/// docs/ux-and-usage.md §6.
class InfoButton extends StatelessWidget {
  final String title;
  final List<GlossaryEntry> entries;
  const InfoButton({super.key, required this.title, required this.entries});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IconButton(
      icon: const Icon(Icons.info_outline),
      iconSize: 20,
      color: t.faint,
      tooltip: title,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _GlossarySheet(title: title, entries: entries),
      ),
    );
  }
}

class _GlossarySheet extends StatelessWidget {
  final String title;
  final List<GlossaryEntry> entries;
  const _GlossarySheet({required this.title, required this.entries});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleLarge),
            const SizedBox(height: 16),
            for (final e in entries) ...[
              Text(e.term, style: text.titleSmall?.copyWith(color: t.primary)),
              const SizedBox(height: 2),
              Text(
                e.meaning,
                style: text.bodyMedium?.copyWith(color: t.dim, height: 1.4),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}
