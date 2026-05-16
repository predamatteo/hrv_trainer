import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/hrv/session_models.dart';
import '../pacer/state/pacer_controller.dart';
import '../pacer/widgets/breathing_orb.dart';
import 'state/training_controller.dart';

class TrainingScreen extends ConsumerStatefulWidget {
  final SessionTag initialTag;

  const TrainingScreen({super.key, this.initialTag = SessionTag.general});

  @override
  ConsumerState<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends ConsumerState<TrainingScreen>
    with TickerProviderStateMixin {
  late BreathingPattern _pattern;
  late int _durationMin;
  late SessionTag _tag;

  @override
  void dispose() {
    // Sicurezza: se l'utente esce con back system, assicurati che il
    // wakelock venga rilasciato anche se ref.listen non era ancora attivo.
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    // Morning check-in = sessione corta (3 min) con pacer standard 6 bpm.
    if (_tag == SessionTag.morning) {
      _pattern = BreathingPattern.resonance6bpm;
      _durationMin = 3;
    } else {
      _pattern = BreathingPattern.resonance6bpm;
      _durationMin = 20;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TrainingState>(trainingControllerProvider, (prev, next) {
      // Avvia il pacer del phone solo quando il TrainingController fissa
      // startedAt — cioè al primo HR sample dal watch (o al fallback timeout).
      // Stesso anchor temporale del countdown: così il pacer del phone non
      // parte all'istante del tap "Avvia" lasciando il watch indietro di
      // tutta la latenza openApplication/sendMessage del Connect IQ SDK
      // (osservata fino a ~17 s quando l'app sul watch non è già aperta).
      final wasWaiting = prev == null || prev.startedAt == null;
      if (wasWaiting && next.startedAt != null && next.running) {
        ref.read(pacerControllerProvider.notifier).start();
      }
      if (prev != null && prev.running && !next.running) {
        // Ferma il pacer ticker quando la sessione termina (auto-stop o
        // stop manuale). Provider non è più autoDispose quindi va spento.
        ref.read(pacerControllerProvider.notifier).pause();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sessione completata e salvata'),
            duration: Duration(seconds: 2),
          ),
        );
        // Se la sessione è stata salvata mostriamo subito il dettaglio
        // della sessione appena conclusa, sostituendo la route /training
        // nello stack così che il back system riporti l'utente in home.
        // Senza id (es. stop senza save / senza startedAt) ricadiamo sul
        // pop verso la schermata che ha aperto il training.
        final id = next.lastSessionId;
        if (id != null) {
          context.pushReplacement('/history/session/$id');
        } else if (context.canPop()) {
          context.pop();
        }
      }
    });

    // Watch SOLO il flag running: cambio solo quando si avvia/ferma sessione.
    // Tutti i sotto-widget watchano in autonomia ciò che gli serve, così il
    // pacer (20 Hz) non ricostruisce chart/metrics/progress.
    final running = ref.watch(
      trainingControllerProvider.select((s) => s.running),
    );

    // Tieni lo schermo acceso durante la sessione (biofeedback richiede
    // di vedere orb e dati senza black-out Android).
    WakelockPlus.toggle(enable: running);

    if (!running) {
      return _buildSetup(context);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await _confirmStop();
        if (confirm == true && context.mounted) {
          await ref.read(trainingControllerProvider.notifier).stop(save: true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const _TrainingTimerTitle(),
          actions: [
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () async {
                final confirm = await _confirmStop();
                if (confirm == true && context.mounted) {
                  await ref
                      .read(trainingControllerProvider.notifier)
                      .stop(save: true);
                }
              },
            )
          ],
        ),
        body: Column(
          children: [
            const SizedBox(height: 12),
            const _TrainingProgressBar(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: const [
                    Expanded(flex: 3, child: Center(child: _OrbView())),
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          Expanded(child: _HrLiveChart()),
                          SizedBox(height: 8),
                          _LiveMetrics(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Nuova sessione di training')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Frequenza respiro',
                style: theme.textTheme.titleMedium),
            Slider(
              min: 4.0,
              max: 8.0,
              divisions: 16,
              value: _pattern.breathsPerMinute,
              label: _pattern.breathsPerMinute.toStringAsFixed(1),
              onChanged: (v) => setState(
                  () => _pattern = BreathingPattern.fromBpm(v)),
            ),
            const SizedBox(height: 16),
            Text('Durata',
                style: theme.textTheme.titleMedium),
            Slider(
              min: 1,
              max: 30,
              divisions: 29,
              value: _durationMin.toDouble(),
              label: '$_durationMin min',
              onChanged: (v) => setState(() => _durationMin = v.toInt()),
            ),
            const SizedBox(height: 16),
            Text('Contesto', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: SessionTag.values.map((t) {
                return ChoiceChip(
                  label: Text(t.label),
                  selected: _tag == t,
                  onSelected: (_) => setState(() => _tag = t),
                );
              }).toList(),
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: Text('Avvia $_durationMin min a '
                  '${_pattern.breathsPerMinute.toStringAsFixed(1)} bpm'),
              onPressed: () async {
                debugPrint('[TRAIN] Avvia pressed');
                ref.read(pacerPreferencesProvider.notifier).state =
                    ref.read(pacerPreferencesProvider).copyWith(
                          pattern: _pattern,
                        );
                await ref
                    .read(trainingControllerProvider.notifier)
                    .start(_pattern,
                        targetDurationSec: _durationMin * 60, tag: _tag);
                // Il pacer NON parte qui: viene avviato dal ref.listen più in
                // alto quando arriva il primo HR sample dal watch, così che
                // ciclo ispira/espira sul phone e sul watch siano allineati.
                debugPrint('[TRAIN] training started, pacer waiting for watch');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmStop() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Terminare la sessione?'),
          content: const Text(
              'I dati raccolti verranno salvati nello storico.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Continua'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Termina'),
            ),
          ],
        ),
      );

}

class _HrLiveChart extends ConsumerWidget {
  const _HrLiveChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(trainingControllerProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Header (BPM, range, swing) si attiva con 1 punto.
    // Il chart vero richiede ≥2 punti, altrimenti minX == maxX e fl_chart
    // asserta. Sotto soglia, placeholder "In attesa…".
    final hasAny = st.hrTrace.isNotEmpty && st.startedAt != null;
    final canChart = st.hrTrace.length >= 2 && st.startedAt != null;

    int? currentBpm, dataMin, dataMax, swing;
    if (hasAny) {
      currentBpm = st.hrTrace.last.bpm;
      final bpms = st.hrTrace.map((p) => p.bpm);
      dataMin = bpms.reduce((a, b) => a < b ? a : b);
      dataMax = bpms.reduce((a, b) => a > b ? a : b);
      final from30 =
          st.hrTrace.last.timestamp.subtract(const Duration(seconds: 30));
      final last30 =
          st.hrTrace.where((p) => p.timestamp.isAfter(from30)).toList();
      if (last30.length >= 2) {
        final mn = last30.map((p) => p.bpm).reduce((a, b) => a < b ? a : b);
        final mx = last30.map((p) => p.bpm).reduce((a, b) => a > b ? a : b);
        swing = mx - mn;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChartHeader(
          currentBpm: currentBpm,
          swing: swing,
          range: dataMin == null ? null : '$dataMin–$dataMax',
        ),
        const SizedBox(height: 2),
        _ChartLegend(scheme: scheme, textTheme: theme.textTheme),
        const SizedBox(height: 4),
        Expanded(
          child: canChart
              ? _buildChart(theme, scheme, st)
              : Center(
                  child: Text(
                    'In attesa del watch…',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildChart(ThemeData theme, ColorScheme scheme, TrainingState st) {
    final start = st.startedAt!;
    final pts = st.hrTrace;
    final spots = [
      for (final p in pts)
        FlSpot(
          p.timestamp.difference(start).inMilliseconds / 1000.0,
          p.bpm.toDouble(),
        ),
    ];
    final bpms = pts.map((p) => p.bpm).toList();
    final dataMin = bpms.reduce((a, b) => a < b ? a : b);
    final dataMax = bpms.reduce((a, b) => a > b ? a : b);
    final pad = ((dataMax - dataMin) * 0.2).clamp(3, 10).toDouble();
    final yMin = (dataMin - pad).floorToDouble();
    final yMax = (dataMax + pad).ceilToDouble();
    final yMid = (yMin + yMax) / 2;
    final halfRange = (yMax - yMin) * 0.4;

    final xMin = spots.first.x;
    final xMax = spots.last.x;
    final span = (xMax - xMin) <= 0 ? 1.0 : (xMax - xMin);

    // Sovrapposizione respiro: campiona la curva del pacer e la mappa nel
    // range Y così che HR e respiro siano visivamente confrontabili.
    final breathSpots = <FlSpot>[];
    const n = 150;
    for (int i = 0; i <= n; i++) {
      final t = xMin + span * i / n;
      final amp = pacerAt(st.pattern, t).amplitude; // 0..1
      final y = yMid + (amp - 0.5) * 2 * halfRange;
      breathSpots.add(FlSpot(t, y));
    }

    final yRange = yMax - yMin;
    // interval in [1, range] per evitare assertion fl_chart (interval > range).
    final yInterval = (yRange / 4).clamp(1.0, yRange).toDouble();
    final xInterval = (span / 4).clamp(1.0, span).toDouble();

    return LineChart(
      LineChartData(
        minX: xMin,
        maxX: xMax,
        minY: yMin,
        maxY: yMax,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawHorizontalLine: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) => FlLine(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: yInterval,
              getTitlesWidget: (v, _) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  v.toStringAsFixed(0),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 18,
              interval: xInterval,
              getTitlesWidget: (v, _) {
                final s = v.toInt();
                final mm = (s ~/ 60).toString();
                final ss = (s % 60).toString().padLeft(2, '0');
                return Text('$mm:$ss', style: theme.textTheme.labelSmall);
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left:
                BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            bottom:
                BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: breathSpots,
            isCurved: false,
            barWidth: 1.2,
            color: scheme.secondary.withValues(alpha: 0.55),
            dotData: const FlDotData(show: false),
            dashArray: const [4, 4],
          ),
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            barWidth: 2.2,
            color: scheme.primary,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }
}

class _ChartHeader extends StatelessWidget {
  final int? currentBpm;
  final int? swing;
  final String? range;
  const _ChartHeader({this.currentBpm, this.swing, this.range});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Icon(Icons.favorite, color: scheme.primary, size: 16),
        const SizedBox(width: 4),
        Text(
          currentBpm == null ? '--' : '$currentBpm',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        const SizedBox(width: 3),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text('bpm', style: theme.textTheme.labelSmall),
        ),
        const Spacer(),
        if (swing != null) ...[
          Tooltip(
            message:
                'Oscillazione HR negli ultimi 30s (RSA).\n'
                'Più è ampia, migliore è la coerenza col respiro.',
            child: _Pill(label: 'RSA Δ', value: '$swing bpm'),
          ),
          const SizedBox(width: 6),
        ],
        if (range != null) _Pill(label: 'range', value: range!),
      ],
    );
  }
}

class _ChartLegend extends StatelessWidget {
  final ColorScheme scheme;
  final TextTheme textTheme;
  const _ChartLegend({required this.scheme, required this.textTheme});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 2.5,
          color: scheme.primary,
        ),
        const SizedBox(width: 4),
        Text('HR live', style: textTheme.labelSmall),
        const SizedBox(width: 14),
        SizedBox(
          width: 14,
          height: 2,
          child: CustomPaint(
            painter: _DashPainter(scheme.secondary.withValues(alpha: 0.7)),
          ),
        ),
        const SizedBox(width: 4),
        Text('respiro guida', style: textTheme.labelSmall),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  final Color color;
  _DashPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.butt;
    const dash = 3.0;
    const gap = 2.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dash).clamp(0.0, size.width), y),
        p,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) => old.color != color;
}

class _Pill extends StatelessWidget {
  final String label;
  final String value;
  const _Pill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(width: 4),
          Text(
            value,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveMetrics extends ConsumerWidget {
  const _LiveMetrics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch SOLO le metriche aggregate: cambiano ogni 5s, non ad ogni
    // pacer tick né ad ogni HR sample.
    final m = ref.watch(
      trainingControllerProvider.select((s) => s.liveMetrics),
    );
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _stat(t, 'HR',
            m.meanHrBpm == 0 ? '--' : m.meanHrBpm.toStringAsFixed(0)),
        _stat(t, 'SDNN', m.sdnnMs == 0 ? '--' : m.sdnnMs.toStringAsFixed(0)),
        _stat(t, 'RMSSD',
            m.rmssdMs == 0 ? '--' : m.rmssdMs.toStringAsFixed(0)),
        _stat(t, 'LF peak',
            m.lfPeakHz == 0 ? '--' : m.lfPeakHz.toStringAsFixed(2)),
      ],
    );
  }

  Widget _stat(TextTheme t, String l, String v) => Column(
        children: [
          Text(v, style: t.titleLarge),
          Text(l, style: t.labelSmall),
        ],
      );
}

/// Orb del respiro: ascolta il pacer (20 Hz) ma NON il TrainingState, così
/// che il rebuild del cerchio non trascini chart/metrics/progress.
class _OrbView extends ConsumerWidget {
  const _OrbView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(pacerControllerProvider);
    final theme = Theme.of(context);
    return BreathingOrb(
      amplitude: tick.amplitude,
      phase: tick.phase,
      phaseProgress: tick.progress,
      inhaleColor: theme.colorScheme.primary,
      exhaleColor: theme.colorScheme.secondary,
      size: 260,
    );
  }
}

/// Titolo AppBar con countdown: aggiorna ogni secondo via Timer interno
/// invece di rebuild dal TrainingController (che cambia ad ogni HR sample).
class _TrainingTimerTitle extends ConsumerStatefulWidget {
  const _TrainingTimerTitle();

  @override
  ConsumerState<_TrainingTimerTitle> createState() =>
      _TrainingTimerTitleState();
}

class _TrainingTimerTitleState extends ConsumerState<_TrainingTimerTitle> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.read(trainingControllerProvider);
    // startedAt == null finché non arriva il primo HR sample dal watch:
    // il countdown del phone si allinea a quello del watch così che
    // entrambi terminino nello stesso istante (vedi TrainingController).
    if (st.startedAt == null) {
      return const Text('Training • avvio sul watch…');
    }
    final remaining = Duration(seconds: st.targetDurationSec) - st.elapsed;
    final remSec = remaining.isNegative ? 0 : remaining.inSeconds;
    final m = (remSec ~/ 60).toString().padLeft(2, '0');
    final s = (remSec % 60).toString().padLeft(2, '0');
    return Text('Training • $m:$s');
  }
}

/// LinearProgress che si aggiorna ogni secondo (basta per occhio umano)
/// senza dipendere da rebuild del trainingController.
class _TrainingProgressBar extends ConsumerStatefulWidget {
  const _TrainingProgressBar();

  @override
  ConsumerState<_TrainingProgressBar> createState() =>
      _TrainingProgressBarState();
}

class _TrainingProgressBarState extends ConsumerState<_TrainingProgressBar> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.read(trainingControllerProvider);
    // Indeterminate finché startedAt non è fissato dal primo HR sample:
    // segnala visivamente che stiamo aspettando l'allineamento col watch.
    if (st.startedAt == null) {
      return const LinearProgressIndicator();
    }
    final value = (st.elapsed.inSeconds / st.targetDurationSec).clamp(0.0, 1.0);
    return LinearProgressIndicator(value: value);
  }
}
