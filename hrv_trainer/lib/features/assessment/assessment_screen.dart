import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/connect_iq/widgets/watch_readiness_gate.dart';
import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/ui/ui.dart';
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

    ref.listen<AssessmentState>(assessmentControllerProvider, (prev, next) {
      final wasScanning = prev?.phase == AssessmentPhase.scanning;
      if (!wasScanning && next.phase == AssessmentPhase.scanning) {
        ref.read(pacerControllerProvider.notifier).start();
      }
      if (next.phase != AssessmentPhase.scanning &&
          next.phase != AssessmentPhase.baseline &&
          (prev?.phase == AssessmentPhase.scanning || prev?.phase == AssessmentPhase.baseline)) {
        ref.read(pacerControllerProvider.notifier).pause();
      }
      if (next.abortedNoData && (prev == null || !prev.abortedNoData)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'L\'orologio non ha inviato dati. Spesso basta riavviare '
              'l\'orologio (memoria Connect IQ piena) o avvicinarlo e '
              'controllare il Bluetooth.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: switch (st.phase) {
          AssessmentPhase.idle => _buildIntro(context),
          AssessmentPhase.waiting => _buildWaiting(),
          AssessmentPhase.baseline => _buildScanning(st),
          AssessmentPhase.scanning => _buildScanning(st),
          AssessmentPhase.completed => _buildResult(context, st),
        },
      ),
    );
  }

  Widget _buildWaiting() {
    return Column(
      children: [
        const HeaderBar(showBack: false, title: 'Assessment risonanza', centerTitle: true, dense: true),
        Expanded(
          child: WatchWaitingView(
            onCancel: () async {
              await ref.read(assessmentControllerProvider.notifier).cancel();
              if (mounted && context.canPop()) context.pop();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildIntro(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        const HeaderBar(title: 'Assessment della risonanza'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            children: [
              Text('Come funziona', style: text.titleLarge),
              const SizedBox(height: 14),
              AppCard(
                color: t.tonal,
                border: Colors.transparent,
                child: Text(
                  'Respirerai per ~2,5 minuti a ciascuna di queste frequenze '
                  'decrescenti: 6,5 → 6,0 → 5,5 → 5,0 → 4,5 respiri/min.\n\n'
                  'Segui il cerchio che si espande (inspira) e si contrae (espira) '
                  'in modo fluido e addominale, senza pause. Non forzare la profondità.\n\n'
                  'Al termine l\'app individua la tua frequenza di risonanza personale: '
                  'quella in cui l\'oscillazione del battito guidata dal respiro (RSA) '
                  'raggiunge l\'ampiezza massima.',
                  style: text.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Avvia assessment'),
                  onPressed: () async {
                    final ready = await ensureWatchReady(context, ref);
                    if (!ready || !mounted) return;
                    await ref.read(assessmentControllerProvider.notifier).start();
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: () => context.pop(), child: const Text('Annulla')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScanning(AssessmentState st) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final tick = ref.watch(pacerControllerProvider);
    final bpm = st.currentBpm ?? 0;
    final orbSize = (MediaQuery.sizeOf(context).width - 120).clamp(180.0, 250.0);

    return Column(
      children: [
        const HeaderBar(showBack: false, title: 'Assessment risonanza', centerTitle: true, dense: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            children: [
              if (st.connectionLost) ...[
                const WatchConnectionLostBanner(),
                const SizedBox(height: 10),
              ],
              _StepProgress(
                total: kAssessmentBpmSteps.length,
                filled: st.currentStepIndex < 0 ? 0 : st.currentStepIndex,
              ),
              const SizedBox(height: 10),
              Text(
                'Ritmo ${st.currentStepIndex + 1}/${kAssessmentBpmSteps.length} · '
                '${bpm.toStringAsFixed(1).replaceAll('.', ',')} respiri/min',
                style: text.titleMedium,
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: BreathingOrb(
              amplitude: tick.amplitude,
              phase: tick.phase,
              phaseProgress: tick.progress,
              inhaleColor: t.inhale,
              exhaleColor: t.exhale,
              size: orbSize,
            ),
          ),
        ),
        Text('Campioni raccolti: ${st.currentWindow.length}',
            style: text.labelMedium?.copyWith(color: t.faint)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.stop, size: 20),
            label: const Text('Annulla'),
            onPressed: () => ref.read(assessmentControllerProvider.notifier).cancel(),
          ),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, AssessmentState st) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final r = st.result;
    if (r == null) return const SizedBox.shrink();
    final bpm = r.resonanceBpm;
    final bpmStr = bpm == null ? '—' : bpm.toStringAsFixed(1).replaceAll('.', ',');
    final hzStr = bpm == null ? '' : (bpm / 60).toStringAsFixed(2).replaceAll('.', ',');

    return Column(
      children: [
        const HeaderBar(title: 'Assessment della risonanza'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            children: [
              _StepProgress(total: r.steps.length, filled: r.steps.length),
              const SizedBox(height: 18),
              AppCard(
                color: t.primaryTonal,
                border: Colors.transparent,
                padding: const EdgeInsets.all(22),
                child: Column(
                  children: [
                    Text('La tua frequenza di risonanza',
                        style: text.bodyMedium?.copyWith(color: t.dim)),
                    const SizedBox(height: 6),
                    Text(bpmStr, style: text.displayLarge?.copyWith(color: t.text, height: 1.05)),
                    const SizedBox(height: 2),
                    Text(
                      bpm == null ? 'dati insufficienti' : 'respiri al minuto · $hzStr Hz',
                      style: text.bodyMedium?.copyWith(color: t.dim),
                    ),
                    if (bpm != null) ...[
                      const SizedBox(height: 14),
                      Pill(tone: PillTone.good, icon: Icons.check_circle, label: 'coerenza massima qui'),
                    ],
                  ],
                ),
              ),
              if (r.steps.isNotEmpty) ...[
                const SizedBox(height: 16),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Oscillazione respiratoria per ritmo', style: text.titleSmall),
                      const SizedBox(height: 2),
                      Text('ampiezza RSA picco-valle · respiri / min',
                          style: text.bodySmall?.copyWith(color: t.faint)),
                      const SizedBox(height: 16),
                      _RateBars(steps: r.steps, resonanceBpm: bpm),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'A questo ritmo il sistema cuore-respiro entra in fase: l\'ampiezza '
                'dell\'onda RSA è massima. Usalo come passo predefinito del pacer.',
                style: text.bodyMedium?.copyWith(color: t.dim, height: 1.5),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bpm != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text('Imposta $bpmStr come pacer predefinito'),
                    onPressed: () => _setAsPacer(context, bpm),
                  ),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => ref.read(assessmentControllerProvider.notifier).cancel(),
                child: const Text('Ripeti l\'assessment'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _setAsPacer(BuildContext context, double bpm) {
    final prefs = ref.read(pacerPreferencesProvider);
    ref.read(pacerPreferencesProvider.notifier).state =
        prefs.copyWith(pattern: BreathingPattern.fromBpm(bpm));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pacer impostato a ${bpm.toStringAsFixed(1).replaceAll('.', ',')} respiri/min'),
        duration: const Duration(seconds: 2),
      ),
    );
    context.go('/');
  }
}

/// Barra di progresso a segmenti (1 per ritmo) + contatore N/M.
class _StepProgress extends StatelessWidget {
  final int total;
  final int filled;
  const _StepProgress({required this.total, required this.filled});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          Expanded(
            child: Container(
              height: 5,
              decoration: BoxDecoration(
                color: i < filled ? t.primary : t.tonal2,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          if (i < total - 1) const SizedBox(width: 6),
        ],
        const SizedBox(width: 10),
        Text('$filled/$total', style: text.labelSmall?.copyWith(color: t.faint)),
      ],
    );
  }
}

/// Istogramma dell'ampiezza RSA (picco-valle) per ritmo respiratorio scansionato.
/// Il ritmo di risonanza è evidenziato in primary con la marca "picco".
class _RateBars extends StatelessWidget {
  final List<AssessmentStep> steps;
  final double? resonanceBpm;
  const _RateBars({required this.steps, required this.resonanceBpm});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final sorted = [...steps]..sort((a, b) => a.bpm.compareTo(b.bpm));
    var maxP2t = 0.0;
    for (final s in sorted) {
      if (s.metrics.peakToTroughMs > maxP2t) maxP2t = s.metrics.peakToTroughMs;
    }
    if (maxP2t <= 0) maxP2t = 1;

    const chartH = 128.0;
    return SizedBox(
      height: chartH + 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final s in sorted)
            Expanded(
              child: Builder(builder: (context) {
                final peak = resonanceBpm != null && (s.bpm - resonanceBpm!).abs() < 0.01;
                final frac = (s.metrics.peakToTroughMs / maxP2t).clamp(0.0, 1.0);
                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SizedBox(
                      height: 14,
                      child: peak
                          ? Text('picco', style: text.labelSmall?.copyWith(color: t.primary, fontWeight: FontWeight.w700))
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      height: (chartH - 18) * frac + 2,
                      decoration: BoxDecoration(
                        color: peak ? t.primary : t.tonal2,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(s.bpm.toStringAsFixed(1).replaceAll('.', ','),
                        style: text.labelSmall?.copyWith(color: t.faint)),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }
}
