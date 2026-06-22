import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

/// Tile compatta valore/etichetta su sfondo tonale (griglie statistiche:
/// 4-tile del dettaglio sessione, riepiloghi dello storico).
class StatTile extends StatelessWidget {
  final String value;
  final String label;

  /// Suffisso opzionale accanto al valore (es. delta "+3").
  final Widget? valueSuffix;
  final Color? background;
  final Color? valueColor;

  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.valueSuffix,
    this.background,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: background ?? t.tonal,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: valueColor ?? t.text,
                  ),
                ),
              ),
              if (valueSuffix != null) ...[const SizedBox(width: 4), valueSuffix!],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: t.faint),
          ),
        ],
      ),
    );
  }
}

/// Riga metrica label · valore+unità con divisore opzionale (liste metriche
/// del check-in / dettaglio sessione).
class MetricRow extends StatelessWidget {
  final String label;
  final String? sublabel;
  final String value;
  final String? unit;
  final bool divider;

  const MetricRow({
    super.key,
    required this.label,
    required this.value,
    this.sublabel,
    this.unit,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: divider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: t.line, width: 1)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                if (sublabel != null) ...[
                  const SizedBox(height: 1),
                  Text(sublabel!, style: text.bodySmall?.copyWith(color: t.faint)),
                ],
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit!, style: text.labelSmall?.copyWith(color: t.faint)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
