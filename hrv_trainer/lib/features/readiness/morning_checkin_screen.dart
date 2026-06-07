import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/morning_reading.dart';
import '../../shared/hrv/rr_interval.dart';
import 'state/morning_checkin_controller.dart';

/// Flusso di misura mattutina a respiro SPONTANEO (NON guidato): a differenza
/// del training/pacer qui non c'è orb né pacer. La readiness baseline richiede
/// che la HRV sia misurata a riposo senza pacing, altrimenti il respiro lento
/// gonfia artificialmente RSA/RMSSD e falsa il trend (vedi research.md).
///
/// La macchina a stati vive nel controller; questa schermata è una vista
/// stateless-ish che reagisce a [MorningCheckInState.phase]. Lo stato locale
/// (contesto di check-in: sonno, flag, fatica) vive qui finché non viene
/// inviato al controller con `save`.
class MorningCheckInScreen extends ConsumerStatefulWidget {
  const MorningCheckInScreen({super.key});

  @override
  ConsumerState<MorningCheckInScreen> createState() =>
      _MorningCheckInScreenState();
}

class _MorningCheckInScreenState extends ConsumerState<MorningCheckInScreen> {
  // Stato locale del form di contesto (fase review). Lo teniamo qui e non nel
  // controller perché è puro input UI: viene impacchettato in un MorningContext
  // solo al tap su "Salva lettura".
  SleepQuality _sleep = SleepQuality.unknown;
  bool _alcohol = false;
  bool _illness = false;
  bool _stressed = false;
  bool _soreness = false;
  int? _fatigue;
  bool _saving = false;

  @override
  void dispose() {
    // Sicurezza: rilascia il wakelock anche se l'utente esce con back system
    // mentre la misura è in corso (lo abilitiamo in build durante measuring).
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(morningCheckInControllerProvider);

    // Tieni lo schermo acceso solo mentre si misura: l'utente sta fermo e non
    // tocca il telefono, senza wakelock Android farebbe black-out interrompendo
    // il countdown visivo (la cattura prosegue, ma si perde il feedback).
    WakelockPlus.toggle(enable: state.phase == CheckInPhase.measuring);

    return switch (state.phase) {
      CheckInPhase.idle => _buildIdle(context, state),
      CheckInPhase.measuring => _buildMeasuring(context, state),
      CheckInPhase.review => _buildReview(context, state),
      CheckInPhase.saved => _buildSaved(context),
    };
  }

  // --------------------------------------------------------------------------
  // idle: spiegazione + picker postura/protocollo + avvio.
  // --------------------------------------------------------------------------
  Widget _buildIdle(BuildContext context, MorningCheckInState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Morning check-in')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Card di istruzioni: il punto chiave è il respiro spontaneo. Lo
          // ribadiamo perché chi viene dal training è abituato al pacer.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.self_improvement, color: scheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Misura a riposo, respiro SPONTANEO (NON guidato). '
                      'Stai fermo, seduto, subito dopo il risveglio.',
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Postura', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: Posture.values.map((p) {
              return ChoiceChip(
                label: Text(p.label),
                selected: state.posture == p,
                onSelected: (_) => ref
                    .read(morningCheckInControllerProvider.notifier)
                    .setPosture(p),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Text('Durata', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            // Solo i protocolli spontanei: `paced` è legacy (vecchie letture a
            // respiro guidato) e non va proposto per nuove misure baseline.
            children: const [
              MorningProtocol.seated60,
              MorningProtocol.seated180,
            ].map((p) {
              return ChoiceChip(
                label: Text(p.label),
                selected: state.protocol == p,
                onSelected: (_) => ref
                    .read(morningCheckInControllerProvider.notifier)
                    .setProtocol(p),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Text(
            '${MorningCheckInController.settleSec}s di assestamento + '
            '${state.protocol.captureSec}s di cattura.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            label: const Text('Avvia misura'),
            onPressed: () => ref
                .read(morningCheckInControllerProvider.notifier)
                .start(),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // measuring: vista calma a tutto schermo. Back bloccato (conferma annulla).
  // --------------------------------------------------------------------------
  Widget _buildMeasuring(BuildContext context, MorningCheckInState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settling = state.settling;
    final mm = (state.secLeft ~/ 60).toString().padLeft(2, '0');
    final ss = (state.secLeft % 60).toString().padLeft(2, '0');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await _confirmCancel();
        if (confirm == true && context.mounted) {
          await ref.read(morningCheckInControllerProvider.notifier).cancel();
          if (context.mounted && context.canPop()) context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // Niente titolo "ricco": la vista deve restare calma. Solo l'azione
          // per annullare la misura.
          title: Text(settling ? 'Assestamento' : 'Misurazione'),
          actions: [
            TextButton(
              onPressed: () async {
                final confirm = await _confirmCancel();
                if (confirm == true && context.mounted) {
                  await ref
                      .read(morningCheckInControllerProvider.notifier)
                      .cancel();
                  if (context.mounted && context.canPop()) context.pop();
                }
              },
              child: const Text('Annulla'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(
                  settling
                      ? 'Assestamento… stai fermo'
                      : 'Respira normalmente, stai fermo',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                // Countdown grande: resta l'elemento dominante della schermata.
                Text(
                  '$mm:$ss',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w300,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: settling ? scheme.outline : scheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.favorite, color: scheme.primary, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      state.currentBpm == null ? '--' : '${state.currentBpm}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('bpm', style: theme.textTheme.labelMedium),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Grafico HR live: l'oscillazione dei battiti È il respiro (RSA).
                // Nessun pacer/overlay — la misura è a respiro spontaneo.
                const Expanded(child: _MorningHrChart()),
                const SizedBox(height: 8),
                Text(
                  'La linea segue il cuore: sale quando inspiri, scende quando '
                  'espiri (RSA). Respira come viene, non seguirla.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                const _MorningLiveStats(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // review: riepilogo metriche + check-in di contesto + salvataggio.
  // --------------------------------------------------------------------------
  Widget _buildReview(BuildContext context, MorningCheckInState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = state.metrics;
    return Scaffold(
      appBar: AppBar(title: const Text('Lettura mattutina')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (m != null) _MeasureSummaryCard(metrics: m),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Contesto', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    // Il contesto aiuta a spiegare una lettura bassa (alcol,
                    // malattia, ecc.) e a marcare i punti sul trend.
                    'Opzionale, ma utile per leggere i tuoi trend.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Qualità del sonno',
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: SleepQuality.values
                        // `unknown` è il default (= nessuna scelta), non lo
                        // proponiamo come chip selezionabile.
                        .where((s) => s != SleepQuality.unknown)
                        .map((s) {
                      return ChoiceChip(
                        label: Text(s.label),
                        selected: _sleep == s,
                        onSelected: (sel) => setState(
                            () => _sleep = sel ? s : SleepQuality.unknown),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text('Fattori', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _toggleChip('Alcol', _alcohol,
                          (v) => setState(() => _alcohol = v)),
                      _toggleChip('Malato', _illness,
                          (v) => setState(() => _illness = v)),
                      _toggleChip('Stressato', _stressed,
                          (v) => setState(() => _stressed = v)),
                      _toggleChip('Indolenzito', _soreness,
                          (v) => setState(() => _soreness = v)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('Affaticamento',
                          style: theme.textTheme.labelLarge),
                      const Spacer(),
                      Text(
                        _fatigue == null ? '—' : '$_fatigue / 5',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    min: 1,
                    max: 5,
                    divisions: 4,
                    // null = non indicato: parte dal centro ma resta "non
                    // settato" finché l'utente non tocca lo slider.
                    value: (_fatigue ?? 3).toDouble(),
                    label: '${_fatigue ?? 3}',
                    onChanged: (v) => setState(() => _fatigue = v.toInt()),
                  ),
                  Text(
                    '1 = fresco · 5 = sfinito',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            label: const Text('Salva lettura'),
            onPressed: _saving ? null : () => _save(context),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // saved: conferma + navigazione.
  // --------------------------------------------------------------------------
  Widget _buildSaved(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Lettura salvata')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: scheme.primary, size: 72),
              const SizedBox(height: 16),
              Text(
                'Lettura mattutina salvata',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'La tua readiness è stata aggiornata.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                icon: const Icon(Icons.insights),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 14),
                ),
                label: const Text('Vedi readiness'),
                onPressed: () => context.pushReplacement('/readiness'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go('/'),
                child: const Text('Fine'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Helpers.
  // --------------------------------------------------------------------------

  /// FilterChip on/off per i flag di contesto booleani.
  Widget _toggleChip(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label),
      selected: value,
      onSelected: onChanged,
    );
  }

  Future<void> _save(BuildContext context) async {
    setState(() => _saving = true);
    final ctx = MorningContext(
      sleep: _sleep,
      alcohol: _alcohol,
      illness: _illness,
      stressed: _stressed,
      soreness: _soreness,
      fatigue: _fatigue,
    );
    final id =
        await ref.read(morningCheckInControllerProvider.notifier).save(ctx);
    if (!context.mounted) return;
    if (id == null) {
      // Nessuna metrica valida (es. campioni insufficienti): non navighiamo,
      // restiamo in review e segnaliamo l'errore.
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossibile salvare: dati insufficienti'),
        ),
      );
      return;
    }
    // Salvataggio ok: il controller passa già a phase.saved (rebuild su
    // schermata di conferma), ma portiamo l'utente direttamente alla readiness
    // così vede subito l'effetto della nuova lettura sul trend.
    context.pushReplacement('/readiness');
  }

  Future<bool?> _confirmCancel() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Annullare la misura?'),
          content: const Text(
              'I dati raccolti finora verranno scartati.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Continua'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
                backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Annulla misura'),
            ),
          ],
        ),
      );
}

/// Riepilogo compatto della misura: RMSSD/HR/campioni + pill confidenza.
/// Stessa estetica delle card di [SessionDetailScreen].
class _MeasureSummaryCard extends StatelessWidget {
  final HrvMetrics metrics;
  const _MeasureSummaryCard({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Misura', style: theme.textTheme.titleMedium),
                const Spacer(),
                _ConfidencePill(confidence: metrics.confidence),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stat(theme, 'RMSSD',
                    metrics.rmssdMs == 0
                        ? '--'
                        : metrics.rmssdMs.toStringAsFixed(1),
                    'ms'),
                _stat(theme, 'HR',
                    metrics.meanHrBpm == 0
                        ? '--'
                        : metrics.meanHrBpm.toStringAsFixed(0),
                    'bpm'),
                _stat(theme, 'Campioni', '${metrics.samples}', 'RR'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value, String unit) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 3),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(unit, style: theme.textTheme.labelSmall),
            ),
          ],
        ),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}

/// Pill colorata per l'affidabilità della misura: verde alta → rosso
/// insufficiente. Coerente con la palette degli InsightBox.
class _ConfidencePill extends StatelessWidget {
  final HrvConfidence confidence;
  const _ConfidencePill({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (confidence) {
      HrvConfidence.high => Colors.green.shade600,
      HrvConfidence.moderate => Colors.lightGreen.shade700,
      HrvConfidence.low => Colors.amber.shade700,
      HrvConfidence.insufficient => Colors.red.shade600,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            'Affidabilità ${confidence.label}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Grafico HR live durante la misura. Una SOLA linea (i battiti): la sua
/// oscillazione è la visualizzazione del respiro spontaneo (RSA). A differenza
/// del training NON c'è overlay tratteggiato del pacer, perché qui il respiro
/// non è guidato. Stile coerente col chart della sessione standard.
class _MorningHrChart extends ConsumerWidget {
  const _MorningHrChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trace = ref.watch(
      morningCheckInControllerProvider.select((s) => s.hrTrace),
    );

    // Sotto 2 punti minX==maxX e fl_chart asserta: placeholder "in attesa".
    if (trace.length < 2) {
      return Center(
        child: Text(
          'In attesa del watch…',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final start = trace.first.timestamp;
    final spots = [
      for (final p in trace)
        FlSpot(
          p.timestamp.difference(start).inMilliseconds / 1000.0,
          p.bpm.toDouble(),
        ),
    ];
    final bpms = trace.map((p) => p.bpm).toList();
    final dataMin = bpms.reduce((a, b) => a < b ? a : b);
    final dataMax = bpms.reduce((a, b) => a > b ? a : b);
    final pad = ((dataMax - dataMin) * 0.2).clamp(3, 10).toDouble();
    final yMin = (dataMin - pad).floorToDouble();
    final yMax = (dataMax + pad).ceilToDouble();

    final xMin = spots.first.x;
    final xMax = spots.last.x;
    final span = (xMax - xMin) <= 0 ? 1.0 : (xMax - xMin);

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

/// Riga di metriche live durante la cattura: RMSSD (preview), ampiezza RSA e
/// campioni. È un'anteprima — il valore definitivo è nel riepilogo finale —
/// quindi styling più leggero del [_MeasureSummaryCard].
class _MorningLiveStats extends ConsumerWidget {
  const _MorningLiveStats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(morningCheckInControllerProvider);
    final live = state.liveMetrics;

    // RMSSD live: '--' finché non c'è una preview valida (≥20 campioni).
    final rmssd = (live == null || live.rmssdMs == 0)
        ? '--'
        : live.rmssdMs.toStringAsFixed(1);

    final swing = _rsaSwing(state.hrTrace);
    final rsa = swing == null ? '--' : '$swing';

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _stat(theme, 'RMSSD (live)', rmssd, 'ms'),
            _stat(theme, 'RSA Δ', rsa, 'bpm',
                tooltip: 'Ampiezza dell\'oscillazione HR negli ultimi 30s '
                    '(RSA): più è ampia, più il respiro modula il cuore.'),
            _stat(theme, 'Campioni', '${state.sampleCount}', 'RR'),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Anteprima: si stabilizza a fine misura.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Ampiezza RSA: max-min dei BPM negli ultimi 30s di trace. null se non ci
  /// sono almeno 2 punti nella finestra.
  int? _rsaSwing(List<HrTracePoint> trace) {
    if (trace.length < 2) return null;
    final from = trace.last.timestamp.subtract(const Duration(seconds: 30));
    final recent = trace.where((p) => p.timestamp.isAfter(from)).toList();
    if (recent.length < 2) return null;
    final bpms = recent.map((p) => p.bpm);
    final mn = bpms.reduce((a, b) => a < b ? a : b);
    final mx = bpms.reduce((a, b) => a > b ? a : b);
    return mx - mn;
  }

  Widget _stat(ThemeData theme, String label, String value, String unit,
      {String? tooltip}) {
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 3),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(unit, style: theme.textTheme.labelSmall),
            ),
          ],
        ),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
    if (tooltip == null) return col;
    return Tooltip(message: tooltip, child: col);
  }
}
