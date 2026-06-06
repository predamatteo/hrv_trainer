import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/hrv/hrv_trend.dart';
import '../../../shared/hrv/readiness.dart' show CvStability;
import '../../readiness/state/readiness_providers.dart';

/// Card "Stato generale HRV" in home: la vista CRONICA dell'HRV (livello tipico
/// + direzione su più settimane + stabilità), complementare alla Morning
/// Readiness che è acuta (oggi vs baseline). Riepilogo glanceable; il trend
/// completo vive nello Storico → tap sull'intera card.
class HrvGeneralCard extends ConsumerWidget {
  const HrvGeneralCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final async = ref.watch(hrvGeneralStatusProvider);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/history'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Stato generale HRV', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 10),
              async.when(
                loading: () => const SizedBox(
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                error: (_, _) => Text(
                  'Stato HRV non disponibile.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                data: (s) => _StatusBody(status: s),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  final HrvGeneralStatus status;
  const _StatusBody({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!status.hasLevel) {
      return Text(
        'L\'andamento comparirà dopo qualche lettura morning.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Livello tipico recente (personale, niente etichette assolute).
        Row(
          children: [
            Icon(Icons.favorite_outline, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text('HRV tipico', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 8),
            Text(
              'RMSSD ${status.levelRmssd!.toStringAsFixed(0)} · '
              'score ${status.levelScore!.toStringAsFixed(0)}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Direzione cronica.
        if (status.direction == HrvTrendDirection.unknown)
          Row(
            children: [
              Icon(Icons.timeline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Andamento disponibile dopo più letture.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          )
        else
          _TrendRow(status: status),
        if (status.cvPct != null) ...[
          const SizedBox(height: 6),
          _StabilityRow(status: status),
        ],
      ],
    );
  }
}

class _TrendRow extends StatelessWidget {
  final HrvGeneralStatus status;
  const _TrendRow({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Colore descrittivo, NON allarmante: un calo può essere un blocco di
    // carico, non un problema → arancio (cautela), non rosso/errore.
    final (icon, color, label) = switch (status.direction) {
      HrvTrendDirection.improving => (
          Icons.trending_up,
          scheme.primary,
          'In miglioramento'
        ),
      HrvTrendDirection.declining => (
          Icons.trending_down,
          Colors.orange.shade700,
          'In calo'
        ),
      HrvTrendDirection.stable => (
          Icons.trending_flat,
          scheme.onSurfaceVariant,
          'Stabile'
        ),
      HrvTrendDirection.unknown => (
          Icons.timeline,
          scheme.onSurfaceVariant,
          '—'
        ),
    };
    final pct = status.deltaPct;
    final pctStr =
        pct == null ? '' : '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%';
    final span = status.spanWeeks == null ? '' : ' · ~${status.spanWeeks} sett.';

    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$pctStr$span',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _StabilityRow extends StatelessWidget {
  final HrvGeneralStatus status;
  const _StabilityRow({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _cvColor(theme, status.cvStability);
    return Row(
      children: [
        Icon(Icons.show_chart, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          'Stabilità: ${_cvLabel(status.cvStability)} '
          '(CV ${status.cvPct!.toStringAsFixed(1)}%)',
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// Colore della riga CV, coerente con readiness_card/readiness_screen.
Color _cvColor(ThemeData theme, CvStability s) => switch (s) {
      CvStability.stable => theme.colorScheme.onSurfaceVariant,
      CvStability.moderate => Colors.orange.shade700,
      CvStability.unstable => theme.colorScheme.error,
      CvStability.unknown => theme.colorScheme.onSurfaceVariant,
    };

String _cvLabel(CvStability s) => switch (s) {
      CvStability.stable => 'stabile',
      CvStability.moderate => 'oscillante',
      CvStability.unstable => 'instabile',
      CvStability.unknown => '—',
    };
