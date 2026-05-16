import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/hrv/breathing_pacer.dart';
import 'state/pacer_controller.dart';
import 'widgets/breathing_orb.dart';

/// Schermata "pacer libero": serve all'utente per familiarizzare con
/// la respirazione a frequenza di risonanza prima di lanciare un training.
class PacerScreen extends ConsumerStatefulWidget {
  const PacerScreen({super.key});

  @override
  ConsumerState<PacerScreen> createState() => _PacerScreenState();
}

class _PacerScreenState extends ConsumerState<PacerScreen>
    with TickerProviderStateMixin {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(pacerPreferencesProvider);
    final tick = ref.watch(pacerControllerProvider);
    final ctrl = ref.read(pacerControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pacer respiratorio'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _PatternControls(
              pattern: prefs.pattern,
              onChanged: (p) {
                ref.read(pacerPreferencesProvider.notifier).state =
                    prefs.copyWith(pattern: p);
              },
            ),
            Center(
              child: BreathingOrb(
                amplitude: tick.amplitude,
                phase: tick.phase,
                phaseProgress: tick.progress,
                inhaleColor: theme.colorScheme.primary,
                exhaleColor: theme.colorScheme.secondary,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Stat(
                      label: 'Frequenza',
                      value:
                          '${prefs.pattern.breathsPerMinute.toStringAsFixed(1)} bpm',
                    ),
                    _Stat(
                      label: 'Periodo',
                      value:
                          '${prefs.pattern.periodSec.toStringAsFixed(1)} s',
                    ),
                    _Stat(
                      label: 'Tempo',
                      value: _fmt(tick.elapsedSec),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile.adaptive(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Vibrazione'),
                        value: prefs.hapticsEnabled,
                        onChanged: (v) {
                          ref.read(pacerPreferencesProvider.notifier).state =
                              prefs.copyWith(hapticsEnabled: v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                    label: Text(_running ? 'Pausa' : 'Avvia pacer'),
                    onPressed: () {
                      if (_running) {
                        ctrl.pause();
                      } else {
                        ctrl.start();
                      }
                      setState(() => _running = !_running);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(double sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec.toInt() % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _PatternControls extends StatelessWidget {
  final BreathingPattern pattern;
  final ValueChanged<BreathingPattern> onChanged;

  const _PatternControls({required this.pattern, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final bpm = pattern.breathsPerMinute;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Frequenza: ${bpm.toStringAsFixed(1)} respiri/min',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Slider(
          min: 3.5,
          max: 9.0,
          divisions: 22,
          value: bpm,
          label: bpm.toStringAsFixed(1),
          onChanged: (v) =>
              onChanged(BreathingPattern.fromBpm(v, ieRatio: 4 / 6)),
        ),
        Wrap(
          spacing: 8,
          children: [
            _preset('Risonanza 6 bpm', BreathingPattern.resonance6bpm),
            _preset('5.5 bpm', BreathingPattern.fromBpm(5.5)),
            _preset('5.0 bpm', BreathingPattern.fromBpm(5.0)),
            _preset('4.5 bpm', BreathingPattern.fromBpm(4.5)),
          ],
        ),
      ],
    );
  }

  Widget _preset(String label, BreathingPattern p) => ActionChip(
        label: Text(label),
        onPressed: () => onChanged(p),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value, style: t.titleLarge),
        Text(label, style: t.labelSmall),
      ],
    );
  }
}
