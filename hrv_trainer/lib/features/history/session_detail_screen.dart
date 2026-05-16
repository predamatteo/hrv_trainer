import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/rr_interval.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/storage/session_repository.dart';
import '../home/state/readiness_provider.dart';
import 'history_screen.dart' show sessionsListProvider;

class SessionDetail {
  final Session session;
  final List<RrInterval> rrSamples;
  const SessionDetail({required this.session, required this.rrSamples});
}

final sessionDetailProvider = FutureProvider.autoDispose
    .family<SessionDetail?, int>((ref, id) async {
  final repo = ref.watch(sessionRepositoryProvider);
  final session = await repo.getSession(id);
  if (session == null) return null;
  final rr = await repo.getSessionRrSamples(id);
  return SessionDetail(session: session, rrSamples: rr);
});

class SessionDetailScreen extends ConsumerWidget {
  final int sessionId;
  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailProvider(sessionId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dettaglio sessione'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Elimina sessione',
            onPressed: detail.maybeWhen(
              data: (d) => d == null
                  ? null
                  : () => _confirmDelete(context, ref, d.session.id!),
              orElse: () => null,
            ),
          ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore: $e')),
        data: (d) {
          if (d == null) {
            return const Center(child: Text('Sessione non trovata'));
          }
          return _DetailBody(detail: d);
        },
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminare la sessione?'),
        content: const Text(
            'L\'operazione è irreversibile. Verranno rimossi anche tutti i campioni RR registrati.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await ref.read(sessionRepositoryProvider).deleteSession(id);
    ref.invalidate(sessionsListProvider);
    // Se la sessione cancellata era un Morning, la baseline 30gg cambia.
    // Senza questa invalidazione la card readiness mostrava ancora la
    // baseline calcolata sulla sessione appena eliminata.
    ref.invalidate(readinessProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Sessione eliminata')));
      if (context.canPop()) context.pop();
    }
  }
}

class _DetailBody extends StatelessWidget {
  final SessionDetail detail;
  const _DetailBody({required this.detail});

  @override
  Widget build(BuildContext context) {
    final s = detail.session;
    final rr = detail.rrSamples;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _HeaderCard(session: s),
        const SizedBox(height: 12),
        _ScoreCard(metrics: s.metrics),
        const SizedBox(height: 12),
        _MetricsCard(metrics: s.metrics),
        const SizedBox(height: 12),
        _TachogramCard(rr: rr, startedAt: s.startedAt),
        const SizedBox(height: 12),
        _PoincareCard(rr: rr, metrics: s.metrics),
        const SizedBox(height: 12),
        _QualityCard(metrics: s.metrics),
        if (s.notes != null && s.notes!.isNotEmpty) ...[
          const SizedBox(height: 12),
          _NotesCard(notes: s.notes!),
        ],
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Session session;
  const _HeaderCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('EEEE d MMMM • HH:mm');
    final iE = '${session.pattern.inhaleSec.toStringAsFixed(1)}s : '
        '${session.pattern.exhaleSec.toStringAsFixed(1)}s';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_kindIcon(session.kind),
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  session.tag.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${session.duration.inMinutes} min',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(df.format(session.startedAt.toLocal()),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(
                  icon: Icons.air,
                  label:
                      '${session.pattern.breathsPerMinute.toStringAsFixed(1)} bpm',
                ),
                _Chip(icon: Icons.compare_arrows, label: 'I:E $iE'),
                _Chip(icon: Icons.timer_outlined, label: _kindLabel(session.kind)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _kindIcon(SessionKind k) => switch (k) {
        SessionKind.assessment => Icons.tune,
        SessionKind.training => Icons.self_improvement,
        SessionKind.reading => Icons.wb_sunny_outlined,
        SessionKind.freestyle => Icons.air,
      };

  String _kindLabel(SessionKind k) => switch (k) {
        SessionKind.assessment => 'Assessment',
        SessionKind.training => 'Training',
        SessionKind.reading => 'Reading',
        SessionKind.freestyle => 'Freestyle',
      };
}

class _ScoreCard extends StatelessWidget {
  final HrvMetrics metrics;
  const _ScoreCard({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = metrics.hrvScore;
    final color = _scoreColor(score, theme);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                score.toStringAsFixed(0),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('HRV Score',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 2),
                  Text(_scoreLabel(score),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w500,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    '15.385 × ln(RMSSD)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _scoreColor(double s, ThemeData theme) {
    if (s >= 65) return Colors.green.shade600;
    if (s >= 50) return Colors.lightGreen.shade600;
    if (s >= 35) return Colors.amber.shade700;
    return Colors.red.shade600;
  }

  String _scoreLabel(double s) {
    if (s >= 65) return 'Eccellente';
    if (s >= 50) return 'Buono';
    if (s >= 35) return 'Discreto';
    if (s > 0) return 'Basso';
    return 'Dati insufficienti';
  }
}

class _MetricsCard extends StatelessWidget {
  final HrvMetrics metrics;
  const _MetricsCard({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Metriche', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _section(theme, 'Time-domain', [
              _row('HR media',
                  '${metrics.meanHrBpm.toStringAsFixed(0)} bpm'),
              _row('SDNN', '${metrics.sdnnMs.toStringAsFixed(1)} ms',
                  hint: 'Variabilità complessiva'),
              _row('RMSSD', '${metrics.rmssdMs.toStringAsFixed(1)} ms',
                  hint: 'Tono parasimpatico'),
              _row('pNN50', '${metrics.pnn50Pct.toStringAsFixed(1)} %'),
              _row('Peak-to-trough',
                  '${metrics.peakToTroughMs.toStringAsFixed(0)} ms',
                  hint: 'Ampiezza RSA'),
              _row('Campioni RR', '${metrics.samples}'),
            ]),
            const SizedBox(height: 8),
            _section(theme, 'Frequency-domain (Lomb-Scargle)', [
              _row('LF peak',
                  '${metrics.lfPeakHz.toStringAsFixed(3)} Hz',
                  hint: 'Banda 0.04-0.15 Hz'),
              _row('LF power',
                  metrics.lfPower.toStringAsFixed(1)),
              _row('HF peak',
                  '${metrics.hfPeakHz.toStringAsFixed(3)} Hz',
                  hint: 'Banda 0.15-0.40 Hz'),
              _row('HF power',
                  metrics.hfPower.toStringAsFixed(1)),
              _row('LF/HF ratio',
                  metrics.lfHfRatio.toStringAsFixed(2),
                  hint: 'Bilancio simpato/vagale'),
              _row('Total power',
                  metrics.totalPower.toStringAsFixed(1)),
            ]),
            const SizedBox(height: 8),
            _section(theme, 'Poincaré', [
              _row('SD1', '${metrics.sd1Ms.toStringAsFixed(1)} ms',
                  hint: 'Variabilità a breve termine'),
              _row('SD2', '${metrics.sd2Ms.toStringAsFixed(1)} ms',
                  hint: 'Variabilità a lungo termine'),
              _row('SD1/SD2',
                  metrics.sd1Sd2Ratio.toStringAsFixed(2)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...rows,
      ],
    );
  }

  Widget _row(String label, String value, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (hint != null)
                  Text(
                    hint,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
          ),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontFeatures: [
                FontFeature.tabularFigures(),
              ])),
        ],
      ),
    );
  }
}

class _TachogramCard extends StatelessWidget {
  final List<RrInterval> rr;
  final DateTime startedAt;
  const _TachogramCard({required this.rr, required this.startedAt});

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
                Text('Tachogram',
                    style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('(RR vs tempo)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: rr.length < 5
                  ? Center(
                      child: Text(
                        'Campioni RR insufficienti',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : _buildChart(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(ThemeData theme) {
    final scheme = theme.colorScheme;
    final t0 = startedAt.millisecondsSinceEpoch / 1000.0;
    final spots = [
      for (final r in rr)
        FlSpot(
          r.timestamp.millisecondsSinceEpoch / 1000.0 - t0,
          r.ms.toDouble(),
        ),
    ];
    final ys = rr.map((r) => r.ms).toList();
    final yMinData = ys.reduce((a, b) => a < b ? a : b);
    final yMaxData = ys.reduce((a, b) => a > b ? a : b);
    final pad = ((yMaxData - yMinData) * 0.15).clamp(20, 100).toDouble();
    final yMin = (yMinData - pad).floorToDouble();
    final yMax = (yMaxData + pad).ceilToDouble();
    final xMax = spots.last.x;
    // Interval = range/4 con un floor minimo, ma MAI sopra il range stesso
    // (fl_chart asserta interval <= asse range).
    final xRange = xMax > 0 ? xMax : 1.0;
    final yRange = yMax - yMin;
    final xInterval =
        (xRange / 4).clamp(1.0, xRange.toDouble()).toDouble();
    final yInterval =
        (yRange / 4).clamp(1.0, yRange.toDouble()).toDouble();

    return LineChart(LineChartData(
      minX: 0,
      maxX: xMax,
      minY: yMin,
      maxY: yMax,
      gridData: FlGridData(
        show: true,
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
            reservedSize: 36,
            interval: yInterval,
            getTitlesWidget: (v, _) => Text(
              v.toStringAsFixed(0),
              style: theme.textTheme.labelSmall,
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
              return Text('$mm:$ss',
                  style: theme.textTheme.labelSmall);
            },
          ),
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border(
          left: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5)),
          bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          color: scheme.primary,
          barWidth: 1.4,
          isCurved: false,
          dotData: const FlDotData(show: false),
        ),
      ],
      // Tooltip esplicito: senza questo blocco fl_chart usa come colore del
      // testo lo stesso colore della linea (scheme.primary, blu) sopra a uno
      // sfondo blueGrey scuro → blu su blu, illeggibile. Forziamo i colori
      // sul contrasto inverseSurface/onInverseSurface della scheme così che
      // il tooltip si legga bene in entrambi i temi.
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          fitInsideVertically: true,
          fitInsideHorizontally: true,
          tooltipMargin: 8,
          getTooltipItems: (spots) => spots.map((s) {
            final secs = s.x.toInt();
            final mm = (secs ~/ 60).toString();
            final ss = (secs % 60).toString().padLeft(2, '0');
            return LineTooltipItem(
              '$mm:$ss\nRR: ${s.y.toStringAsFixed(0)} ms',
              TextStyle(
                color: scheme.onInverseSurface,
                fontWeight: FontWeight.w500,
              ),
            );
          }).toList(),
        ),
      ),
    ));
  }
}

class _PoincareCard extends StatelessWidget {
  final List<RrInterval> rr;
  final HrvMetrics metrics;
  const _PoincareCard({required this.rr, required this.metrics});

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
                Text('Poincaré',
                    style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('(RR n vs RR n+1)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    )),
                const Spacer(),
                Text(
                  'SD1 ${metrics.sd1Ms.toStringAsFixed(1)} • '
                  'SD2 ${metrics.sd2Ms.toStringAsFixed(1)}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: rr.length < 5
                  ? Center(
                      child: Text(
                        'Campioni RR insufficienti',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : _buildScatter(theme),
            ),
            const SizedBox(height: 6),
            Text(
              'Più la nuvola è compatta lungo la diagonale, più il ritmo è regolare; '
              'una nuvola arrotondata indica buona variabilità a breve termine (SD1).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScatter(ThemeData theme) {
    final scheme = theme.colorScheme;
    final spots = <ScatterSpot>[];
    for (var i = 0; i < rr.length - 1; i++) {
      spots.add(ScatterSpot(
        rr[i].ms.toDouble(),
        rr[i + 1].ms.toDouble(),
      ));
    }
    final all = rr.map((r) => r.ms).toList();
    final mn = all.reduce((a, b) => a < b ? a : b);
    final mx = all.reduce((a, b) => a > b ? a : b);
    final pad = ((mx - mn) * 0.15).clamp(20, 150).toDouble();
    final lo = (mn - pad).floorToDouble();
    final hi = (mx + pad).ceilToDouble();
    final range = hi - lo;
    final interval = (range / 4).clamp(1.0, range).toDouble();

    return ScatterChart(ScatterChartData(
      minX: lo,
      maxX: hi,
      minY: lo,
      maxY: hi,
      scatterSpots: spots,
      gridData: FlGridData(
        show: true,
        horizontalInterval: interval,
        verticalInterval: interval,
        getDrawingHorizontalLine: (_) => FlLine(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
          strokeWidth: 0.5,
        ),
        getDrawingVerticalLine: (_) => FlLine(
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
          axisNameWidget: Text('RR n+1 (ms)',
              style: theme.textTheme.labelSmall),
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: interval,
            getTitlesWidget: (v, _) => Text(
              v.toStringAsFixed(0),
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: Text('RR n (ms)',
              style: theme.textTheme.labelSmall),
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: interval,
            getTitlesWidget: (v, _) => Text(
              v.toStringAsFixed(0),
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      scatterTouchData: ScatterTouchData(enabled: false),
      scatterLabelSettings: ScatterLabelSettings(showLabel: false),
    ));
  }
}

class _QualityCard extends StatelessWidget {
  final HrvMetrics metrics;
  const _QualityCard({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = metrics.percentArtifactual;
    final color = pct < 5
        ? Colors.green.shade600
        : pct < 15
            ? Colors.amber.shade700
            : Colors.red.shade600;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Qualità segnale',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.health_and_safety_outlined, color: color),
                const SizedBox(width: 8),
                Text(
                  '${pct.toStringAsFixed(1)}% artefattuale',
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Rimossi: ${metrics.artifactsRemoved} • '
                'Interpolati: ${metrics.artifactsInterpolated}'),
          ],
        ),
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  final String notes;
  const _NotesCard({required this.notes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Note', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(notes),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}
