import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Stato vuoto condiviso: icona grande tenue + messaggio centrato. Espone solo
/// il contenuto (Column `min`); il chiamante decide centraggio/scroll (es.
/// dentro un ListView per mantenere il pull-to-refresh). Sostituisce i
/// `_EmptyState` duplicati in Storico e cruscotto Andamento HRV.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: t.faint),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: t.dim, height: 1.4),
        ),
      ],
    );
  }
}
