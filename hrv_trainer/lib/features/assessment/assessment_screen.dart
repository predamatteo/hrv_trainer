import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../pacer/state/pacer_controller.dart';
import '../pacer/widgets/breathing_orb.dart';
import 'state/assessment_controller.dart';

class AssessmentScreen extends ConsumerStatefulWidget {
  const AssessmentScreen({super.key});

  @override
  ConsumerState<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends ConsumerState<AssessmentScreen>
    with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final st = ref.watch(assessmentControllerProvider);
    final tick = ref.watch(pacerControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Assessment Frequenza di Risonanza')),
      body: switch (st.phase) {
        AssessmentPhase.idle => _buildIntro(context),
        AssessmentPhase.baseline => _buildScanning(theme, tick, st),
        AssessmentPhase.scanning => _buildScanning(theme, tick, st),
        AssessmentPhase.completed => _buildResult(context, st),
      },
    );
  }

  Widget _buildIntro(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Come funziona',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Respirerai per ~2.5 minuti a ciascuna di queste frequenze '
            'decrescenti: 6.5 → 6.0 → 5.5 → 5.0 → 4.5 respiri/min.\n\n'
            'Segui il cerchio che si espande (inspira) e si contrae (espira) '
            'in modo fluido, addominale, senza pause. Non forzare la profondità.\n\n'
            'Al termine l\'app individuerà la tua frequenza di risonanza personale '
            'in base al miglior compromesso tra ampiezza HRV, picco spettrale e '
            'sincronia con il respiro.',
          ),
          const Spacer(),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Avvia assessment'),
            onPressed: () async {
              await ref.read(assessmentControllerProvider.notifier).start();
              if (mounted) {
                ref
                    .read(pacerControllerProvider.notifier)
                    .start();
              }
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => context.pop(),
            child: const Text('Annulla'),
          ),
        ],
      ),
    );
  }

  Widget _buildScanning(ThemeData theme, tick, AssessmentState st) {
    final bpm = st.currentBpm ?? 0;
    final elapsed = st.elapsedInStep.inSeconds;
    final total = kStepDurationSec;
    final stepIdx = st.currentStepIndex;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            LinearProgressIndicator(value: elapsed / total),
            const SizedBox(height: 8),
            Text(
              'Step ${stepIdx + 1}/${kAssessmentBpmSteps.length} • '
              '${bpm.toStringAsFixed(1)} bpm',
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            BreathingOrb(
              amplitude: tick.amplitude,
              phase: tick.phase,
              phaseProgress: tick.progress,
              inhaleColor: theme.colorScheme.primary,
              exhaleColor: theme.colorScheme.secondary,
            ),
            const Spacer(),
            Text('Campioni raccolti: ${st.currentWindow.length}',
                style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Annulla'),
              onPressed: () async {
                await ref
                    .read(assessmentControllerProvider.notifier)
                    .cancel();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context, AssessmentState st) {
    final r = st.result;
    final theme = Theme.of(context);
    if (r == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('La tua Frequenza di Risonanza',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    r.resonanceBpm == null
                        ? '—'
                        : '${r.resonanceBpm!.toStringAsFixed(1)} respiri/min',
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: 4),
                  if (r.rationale != null)
                    Text(r.rationale!, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Dettaglio step', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...r.steps.map((s) => Card(
                child: ListTile(
                  title: Text('${s.bpm.toStringAsFixed(1)} bpm'),
                  subtitle: Text(
                    'SDNN ${s.metrics.sdnnMs.toStringAsFixed(0)} ms • '
                    'RMSSD ${s.metrics.rmssdMs.toStringAsFixed(0)} ms • '
                    'LF peak ${s.metrics.lfPeakHz.toStringAsFixed(3)} Hz',
                  ),
                  trailing: s.bpm == r.resonanceBpm
                      ? const Icon(Icons.star, color: Colors.amber)
                      : null,
                ),
              )),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.go('/'),
            child: const Text('Torna alla home'),
          ),
        ],
      ),
    );
  }
}
