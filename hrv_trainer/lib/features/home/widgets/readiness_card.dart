import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/hrv/readiness.dart';
import '../state/readiness_provider.dart';

class ReadinessCard extends ConsumerWidget {
  /// Se valorizzato, l'intera card diventa toccabile (→ sezione Readiness).
  final VoidCallback? onTap;

  const ReadinessCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(readinessProvider);
    final card = async.when(
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
      data: (r) => _ReadinessBody(readiness: r),
    );
    if (onTap == null) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
  }
}

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});
  @override
  Widget build(BuildContext context) => Card(child: child);
}

class _ReadinessBody extends StatelessWidget {
  final Readiness readiness;

  const _ReadinessBody({required this.readiness});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (readiness.band) {
      ReadinessBand.green => theme.colorScheme.primary,
      ReadinessBand.yellow => Colors.orange.shade700,
      ReadinessBand.red => theme.colorScheme.error,
      ReadinessBand.unknown => theme.colorScheme.outline,
    };
    // Card compatta: solo le info principali (banda, etichetta, z-score,
    // headline). Il dettaglio completo — messaggio, RMSSD/baseline, CV,
    // grafico — vive nella pagina /readiness, raggiungibile col tap.
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
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text('Morning Readiness', style: theme.textTheme.labelLarge),
                const Spacer(),
                if (readiness.zScore != null)
                  Text(
                    '${readiness.zScore! >= 0 ? '+' : ''}${readiness.zScore!.toStringAsFixed(1)}σ',
                    style: theme.textTheme.labelLarge?.copyWith(color: color),
                  ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              readiness.headline,
              style: theme.textTheme.titleLarge?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
