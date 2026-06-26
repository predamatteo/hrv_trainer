import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/ui/ui.dart';
import 'state/pacer_controller.dart';
import 'widgets/breathing_orb.dart';

/// Schermata "Respiro libero": orb a tutta pagina per familiarizzare con la
/// respirazione a frequenza di risonanza. Nessuna registrazione. Si avvia da
/// sé all'ingresso; "Stop" esce, "Pausa" sospende. Lo slider completo
/// (3,5–9,0) vive nel foglio "tune"; in pagina ci sono 3 ritmi rapidi.
class PacerScreen extends ConsumerStatefulWidget {
  const PacerScreen({super.key});

  @override
  ConsumerState<PacerScreen> createState() => _PacerScreenState();
}

class _PacerScreenState extends ConsumerState<PacerScreen> {
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pacerControllerProvider.notifier).start();
      if (mounted) setState(() => _running = true);
    });
  }

  @override
  void dispose() {
    // Controller non-autoDispose: va fermato a mano uscendo, altrimenti il
    // Timer (e le vibrazioni) continuerebbero in background.
    ref.read(pacerControllerProvider.notifier).pause();
    WakelockPlus.disable();
    super.dispose();
  }

  void _toggle() {
    final ctrl = ref.read(pacerControllerProvider.notifier);
    if (_running) {
      ctrl.pause();
    } else {
      ctrl.resume();
    }
    setState(() => _running = !_running);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final prefs = ref.watch(pacerPreferencesProvider);
    // NB: il tick del pacer (20 Hz) NON viene osservato qui — lo guardano solo
    // _OrbView e _ElapsedLabel, così l'intero Scaffold (header, pill, switch,
    // bottoni) non si ricostruisce 20 volte al secondo su una schermata che può
    // restare aperta a lungo (nessun auto-stop) con wakelock attivo.
    final orbSize = (MediaQuery.sizeOf(context).width - 90).clamp(200.0, 280.0);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            children: [
              HeaderBar(
                title: 'Respiro libero',
                centerTitle: true,
                trailing: IconButton(
                  icon: const Icon(Icons.tune),
                  color: t.dim,
                  onPressed: () => _showTune(context, prefs),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _OrbView(
                      size: orbSize,
                      inhaleColor: t.inhale,
                      exhaleColor: t.exhale,
                    ),
                    const SizedBox(height: 34),
                    Text(
                      'Segui l\'onda · espira più a lungo',
                      style: text.bodyMedium?.copyWith(color: t.dim),
                    ),
                    const SizedBox(height: 6),
                    const _ElapsedLabel(),
                    const SizedBox(height: 30),
                    _RatePills(
                      current: prefs.pattern.breathsPerMinute,
                      onPick: (bpm) => ref.read(pacerPreferencesProvider.notifier).state =
                          prefs.copyWith(pattern: BreathingPattern.fromBpm(bpm)),
                    ),
                  ],
                ),
              ),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.vibration, size: 20, color: t.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Haptics — vibra con il respiro', style: text.bodyLarge),
                    ),
                    Switch(
                      value: prefs.hapticsEnabled,
                      onChanged: (v) => ref.read(pacerPreferencesProvider.notifier).state =
                          prefs.copyWith(hapticsEnabled: v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleControlButton(
                    icon: Icons.stop,
                    tooltip: 'Esci',
                    onTap: () => context.pop(),
                  ),
                  const SizedBox(width: 18),
                  CircleControlButton(
                    icon: _running ? Icons.pause : Icons.play_arrow,
                    primary: true,
                    size: 70,
                    tooltip: _running ? 'Pausa' : 'Riprendi',
                    onTap: _toggle,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _showTune(BuildContext context, PacerPreferences prefs) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TuneSheet(
        pattern: prefs.pattern,
        onChanged: (p) =>
            ref.read(pacerPreferencesProvider.notifier).state = prefs.copyWith(pattern: p),
      ),
    );
  }

}

String _fmtElapsed(int totalSec) {
  final m = (totalSec ~/ 60).toString().padLeft(2, '0');
  final s = (totalSec % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Solo l'orb osserva il tick del pacer (20 Hz): isolarlo qui evita di
/// ricostruire il resto della schermata ad ogni frame. Stesso pattern di
/// _OrbView in training_screen.dart.
class _OrbView extends ConsumerWidget {
  final double size;
  final Color inhaleColor;
  final Color exhaleColor;
  const _OrbView({
    required this.size,
    required this.inhaleColor,
    required this.exhaleColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(pacerControllerProvider);
    return BreathingOrb(
      amplitude: tick.amplitude,
      phase: tick.phase,
      phaseProgress: tick.progress,
      size: size,
      inhaleColor: inhaleColor,
      exhaleColor: exhaleColor,
    );
  }
}

/// Cronometro: con `select` sul secondo intero si ricostruisce a ~1 Hz, non a
/// 20 Hz come il tick grezzo (il display mostra solo mm:ss).
class _ElapsedLabel extends ConsumerWidget {
  const _ElapsedLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sec = ref.watch(
        pacerControllerProvider.select((t) => t.elapsedSec.toInt()));
    return Text(_fmtElapsed(sec), style: Theme.of(context).textTheme.displaySmall);
  }
}

class _RatePills extends StatelessWidget {
  final double current;
  final ValueChanged<double> onPick;
  const _RatePills({required this.current, required this.onPick});

  static const _rates = [5.5, 6.0, 6.5];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    // FittedBox: a scale di testo molto grandi le 3 pill si riducono insieme
    // invece di sforare la larghezza (overflow) della Row.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in _rates)
            Builder(builder: (context) {
              final selected = (current - r).abs() < 0.05;
              return GestureDetector(
                onTap: () => onPick(r),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected ? t.primary : t.tonal,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    r == 6.0 ? '6,0 / min' : r.toStringAsFixed(1).replaceAll('.', ','),
                    style: text.labelLarge?.copyWith(
                      color: selected ? t.onPrimary : t.dim,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// Foglio "tune": controllo fine della frequenza (slider 3,5–9,0) + preset.
class _TuneSheet extends StatefulWidget {
  final BreathingPattern pattern;
  final ValueChanged<BreathingPattern> onChanged;
  const _TuneSheet({required this.pattern, required this.onChanged});

  @override
  State<_TuneSheet> createState() => _TuneSheetState();
}

class _TuneSheetState extends State<_TuneSheet> {
  late BreathingPattern _pattern = widget.pattern;

  void _apply(BreathingPattern p) {
    setState(() => _pattern = p);
    widget.onChanged(p);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final bpm = _pattern.breathsPerMinute;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 14, 22, 22 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: t.line, borderRadius: BorderRadius.circular(4)),
            ),
          ),
          const SizedBox(height: 16),
          Text('Frequenza del pacer', style: text.titleMedium),
          const SizedBox(height: 2),
          Text('${bpm.toStringAsFixed(1).replaceAll('.', ',')} respiri/min',
              style: text.bodyMedium?.copyWith(color: t.dim)),
          Slider(
            min: 3.5,
            max: 9.0,
            divisions: 22,
            value: bpm.clamp(3.5, 9.0),
            label: bpm.toStringAsFixed(1),
            onChanged: (v) => _apply(BreathingPattern.fromBpm(v)),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in const [4.5, 5.0, 5.5, 6.0, 6.5])
                ActionChip(
                  label: Text(p == 6.0 ? 'Risonanza 6,0' : p.toStringAsFixed(1).replaceAll('.', ',')),
                  onPressed: () => _apply(BreathingPattern.fromBpm(p)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
