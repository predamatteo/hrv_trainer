import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/readiness_provider.dart';

/// Card-promemoria del check-in mattutino, in cima alla home.
///
/// Compare SOLO se oggi (giorno solare locale) non è ancora stata salvata una
/// lettura morning, e sparisce non appena il check-in del giorno è completato
/// (vedi [morningCheckInDoneTodayProvider]). È un nudge gentile per la routine
/// quotidiana: la Morning Readiness vive di letture costanti, una al giorno.
///
/// Da nascosta non occupa spazio (`SizedBox.shrink`); da visibile incapsula la
/// propria spaziatura inferiore così la home non mostra un gap quando manca.
class MorningCheckInPromptCard extends ConsumerWidget {
  const MorningCheckInPromptCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doneAsync = ref.watch(morningCheckInDoneTodayProvider);
    // Mostriamo il promemoria solo quando sappiamo con certezza che oggi manca.
    // In loading/error restiamo invisibili: niente flash di una card che
    // potrebbe sparire un attimo dopo, e nessun falso allarme se la query fallisce.
    final show = switch (doneAsync) {
      AsyncData(:final value) => !value,
      _ => false,
    };
    if (!show) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onContainer = scheme.onPrimaryContainer;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.primaryContainer,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/readiness/checkin'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Badge circolare col sole: dà identità "mattina" alla card e
                // la distingue dalla Training card (full-primary) senza gridare.
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.wb_sunny_outlined, color: onContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DA FARE OGGI',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: onContainer.withValues(alpha: 0.7),
                          letterSpacing: 0.8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Morning check-in',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: onContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '1-3 minuti a riposo, respiro spontaneo appena sveglio.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onContainer.withValues(alpha: 0.85),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios, size: 16, color: onContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
