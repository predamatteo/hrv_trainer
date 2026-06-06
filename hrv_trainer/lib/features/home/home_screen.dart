import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'state/readiness_provider.dart';
import 'widgets/readiness_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('HRV Trainer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Storico',
            onPressed: () => context.push('/history'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Impostazioni',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: RefreshIndicator(
        // Escape valve manuale: se per qualche regressione futura un
        // provider non viene invalidato dopo una scrittura, l'utente può
        // tirare giù per forzare il ricalcolo. Il flusso normale è che
        // gli `invalidate` esplicite nei controller mantengano la card
        // sincronizzata in tempo reale (vedi TrainingController.stop e
        // RemoteSessionPersister._onSummary).
        onRefresh: () async {
          ref.invalidate(readinessProvider);
          // Aspetta che il future si riavvii per dare feedback visivo
          // chiaro (l'indicatore resta finché il provider non riemette).
          await ref.read(readinessProvider.future);
        },
        child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ReadinessCard(
            onTap: () => context.push('/readiness'),
            onStartMorning: () => context.push('/readiness/checkin'),
          ),
          const SizedBox(height: 16),
          _BigActionCard(
            icon: Icons.wb_sunny_outlined,
            title: 'Morning check-in',
            subtitle: '1-3 minuti a riposo, respiro spontaneo',
            onTap: () => context.push('/readiness/checkin'),
          ),
          const SizedBox(height: 12),
          _BigActionCard(
            icon: Icons.tune,
            title: 'Assessment Frequenza di Risonanza',
            subtitle:
                'Scansione 6.5 → 4.5 bpm per trovare la tua RF personale',
            onTap: () => context.push('/assessment'),
          ),
          const SizedBox(height: 12),
          _BigActionCard(
            icon: Icons.self_improvement,
            title: 'Sessione di Training',
            subtitle: '20 minuti alla tua frequenza di risonanza',
            onTap: () => context.push('/training'),
            highlighted: true,
          ),
          const SizedBox(height: 12),
          _BigActionCard(
            icon: Icons.air,
            title: 'Pacer libero',
            subtitle: 'Respira guidato, senza registrazione',
            onTap: () => context.push('/pacer'),
          ),
          const SizedBox(height: 24),
          Text(
            'Suggerimento del giorno',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Pratica 20 minuti 2 volte al giorno per almeno 10 settimane. '
                'I primi cambiamenti nel tono vagale basale si osservano '
                'dopo 3-4 settimane di pratica costante.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _BigActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlighted;

  const _BigActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        highlighted ? theme.colorScheme.primary : theme.colorScheme.surface;
    final onColor = highlighted
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return Card(
      color: color,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 36, color: onColor),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(color: onColor),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: onColor.withValues(alpha: 0.8)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 18, color: onColor),
            ],
          ),
        ),
      ),
    );
  }
}
