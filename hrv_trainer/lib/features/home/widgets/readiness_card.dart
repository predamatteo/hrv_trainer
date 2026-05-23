import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/readiness.dart';
import '../state/readiness_provider.dart';

class ReadinessCard extends ConsumerWidget {
  final VoidCallback? onStartMorning;

  const ReadinessCard({super.key, this.onStartMorning});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(readinessProvider);
    return async.when(
      loading: () => const _CardShell(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            height: 72,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
      error: (e, _) => _CardShell(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Errore readiness: $e'),
        ),
      ),
      data: (r) => _ReadinessBody(readiness: r, onStartMorning: onStartMorning),
    );
  }
}

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});
  @override
  Widget build(BuildContext context) => Card(child: child);
}

/// Colore della riga CV: neutro quando stabile, ambra/rosso al crescere
/// dell'instabilità. Volutamente sobrio per non competere col semaforo
/// principale della banda di readiness.
Color _cvColor(ThemeData theme, CvStability s) => switch (s) {
      CvStability.stable => theme.colorScheme.onSurfaceVariant,
      CvStability.moderate => Colors.orange.shade700,
      CvStability.unstable => theme.colorScheme.error,
      CvStability.unknown => theme.colorScheme.onSurfaceVariant,
    };

class _ReadinessBody extends StatelessWidget {
  final Readiness readiness;
  final VoidCallback? onStartMorning;

  const _ReadinessBody({required this.readiness, this.onStartMorning});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (readiness.band) {
      ReadinessBand.green => theme.colorScheme.primary,
      ReadinessBand.yellow => Colors.orange.shade700,
      ReadinessBand.red => theme.colorScheme.error,
      ReadinessBand.unknown => theme.colorScheme.outline,
    };
    return _CardShell(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  'Morning Readiness',
                  style: theme.textTheme.labelLarge,
                ),
                const Spacer(),
                if (readiness.zScore != null)
                  Text(
                    '${readiness.zScore! >= 0 ? '+' : ''}${readiness.zScore!.toStringAsFixed(1)}σ',
                    style: theme.textTheme.labelLarge?.copyWith(color: color),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              readiness.headline,
              style: theme.textTheme.titleLarge?.copyWith(color: color),
            ),
            const SizedBox(height: 6),
            Text(readiness.message, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            if (readiness.band == ReadinessBand.unknown &&
                onStartMorning != null) ...[
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.wb_sunny_outlined),
                label: const Text('Nuovo Morning check-in'),
                onPressed: onStartMorning,
              ),
            ] else if (readiness.baselineRmssd != null)
              Text(
                'RMSSD oggi ${readiness.todayRmssd.toStringAsFixed(0)} ms '
                '• baseline ${readiness.baselineRmssd!.toStringAsFixed(0)} ms '
                '(${readiness.baselineDays} gg)',
                style: theme.textTheme.labelSmall,
              ),
            if (readiness.cvPct != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.show_chart, size: 13, color: _cvColor(theme, readiness.cvStability)),
                  const SizedBox(width: 4),
                  Text(
                    'Stabilità 7gg • CV ${readiness.cvPct!.toStringAsFixed(1)}% '
                    '(${readiness.cvLabel})',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: _cvColor(theme, readiness.cvStability)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
