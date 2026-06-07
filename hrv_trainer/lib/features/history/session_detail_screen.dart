import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/hrv/hrv_interpretation.dart';
import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/morning_reading.dart';
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
        _SpectrumCard(rr: rr, metrics: s.metrics, pattern: s.pattern),
        const SizedBox(height: 12),
        _TachogramCard(
          rr: rr,
          startedAt: s.startedAt,
          metrics: s.metrics,
          pattern: s.pattern,
          kind: s.kind,
          tag: s.tag,
        ),
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
                const SizedBox(width: 8),
                // Pill di affidabilità: comunica a colpo d'occhio se i numeri
                // sotto sono "high/moderate/low/insufficient". Cruciale su
                // Instinct 2X dove gli RR sono stimati da HR a 1 Hz.
                _ConfidencePill(confidence: session.metrics.confidence),
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
            // Strip contestuale Morning: postura + protocollo + eventuali
            // confondenti (sonno/alcol/malattia/stress/dolori). Mostrato solo
            // per le letture mattutine create col check-in dedicato.
            if (session.morning != null) ...[
              const SizedBox(height: 10),
              _MorningStrip(meta: session.morning!),
            ],
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
            const SizedBox(height: 6),
            // L'Instinct Solar 2X non espone RR battito-battito: i campioni
            // sono ricostruiti da HR a ~1 Hz (60000/bpm). RMSSD/SDNN così
            // calcolati sottostimano il valore "clinico" del 5-15% perché la
            // banda HF (0.15-0.40 Hz, vagale puro) è fuori Nyquist.
            _EstimationDisclaimer(),
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
  final HrvMetrics metrics;
  final BreathingPattern pattern;
  final SessionKind kind;
  final SessionTag tag;
  const _TachogramCard({
    required this.rr,
    required this.startedAt,
    required this.metrics,
    required this.pattern,
    required this.kind,
    required this.tag,
  });

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
            // Legenda: mostrata solo quando c'è l'overlay del respiro guida
            // (sessioni con pacer). Per il freestyle resta solo la linea RR.
            if (rr.length >= 5 && _hasPacer) ...[
              const SizedBox(height: 4),
              _TachoLegend(scheme: theme.colorScheme),
            ],
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
            if (rr.length >= 5) ...[
              const SizedBox(height: 12),
              _InsightBox(
                insight: interpretTachogram(
                  rr: rr,
                  metrics: metrics,
                  pattern: pattern,
                  kind: kind,
                  tag: tag,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Un pacer è esistito solo per sessioni con respiro GUIDATO: training e
  /// assessment. NON `reading`: le letture mattutine (Morning check-in) sono a
  /// respiro SPONTANEO, quindi sovrapporre una curva-guida sarebbe fuorviante
  /// (l'utente non la seguiva). Allineato con interpretTachogram, che esclude
  /// anch'esso `reading` dalla coerenza col pacer. Freestyle = respiro libero.
  bool get _hasPacer =>
      kind == SessionKind.training || kind == SessionKind.assessment;

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

    // Sovrapposizione respiro guida: campiona pacerAt(pattern, t).amplitude
    // (0..1) e la mappa nel range Y degli RR così che onda respiratoria e
    // tachogramma siano confrontabili visivamente. Mirror dell'overlay live di
    // training_screen.dart:_buildChart. Solo se è esistito un pacer.
    // Il tachogramma usa minX: 0 (gli RR partono da t0 ≈ inizio sessione):
    // campioniamo il pacer sull'intero asse visibile [0, xMax] così che onda e
    // RR restino allineati anche se il primo battito non è esattamente a 0.
    final breathSpots = <FlSpot>[];
    if (_hasPacer) {
      final span = xMax <= 0 ? 1.0 : xMax;
      final yMid = (yMin + yMax) / 2;
      final halfRange = (yMax - yMin) * 0.4;
      const n = 150;
      for (int i = 0; i <= n; i++) {
        final t = span * i / n;
        final amp = pacerAt(pattern, t).amplitude; // 0..1
        breathSpots.add(FlSpot(t, yMid + (amp - 0.5) * 2 * halfRange));
      }
    }
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
      // clipData: senza clip l'onda guida (campionata su tutto l'asse) può
      // sbordare di un pixel oltre i bordi del plot.
      clipData: const FlClipData.all(),
      lineBarsData: [
        // Onda respiratoria guida (tratteggiata, sotto): disegnata per prima
        // così che la linea RR le resti sopra. Lista vuota per il freestyle.
        if (breathSpots.isNotEmpty)
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
            // L'onda guida è l'unica serie tratteggiata: nessun tooltip "RR"
            // su di essa, altrimenti mostrerebbe ms inesistenti.
            if (s.bar.dashArray != null) return null;
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
            if (rr.length >= 5) ...[
              const SizedBox(height: 12),
              _InsightBox(insight: interpretPoincare(metrics)),
            ],
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

    // Centro della nuvola = RR medio (la diagonale di identità RR n = RR n+1
    // attraversa proprio questo punto). SD1/SD2 dalle metriche già calcolate.
    final meanRr = all.reduce((a, b) => a + b) / all.length;

    // Overlay geometrico (diagonale identità + ellisse SD1/SD2) reso con un
    // LineChart SOTTO lo ScatterChart. I due grafici condividono identici
    // min/max e identici reservedSize/axisName, così le rispettive aree di
    // plotting combaciano pixel-per-pixel: niente CustomPaint con inset
    // fragili da indovinare. I punti restano sopra le linee.
    return Stack(
      children: [
        Positioned.fill(
          child: _buildOverlay(theme, lo, hi, interval, meanRr),
        ),
        ScatterChart(ScatterChartData(
          minX: lo,
          maxX: hi,
          minY: lo,
          maxY: hi,
          scatterSpots: spots,
          // Trasparente così la geometria sottostante resta visibile.
          backgroundColor: Colors.transparent,
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
        )),
      ],
    );
  }

  /// LineChart di SFONDO che disegna la diagonale di identità (y=x) e
  /// l'ellisse SD1/SD2 della nuvola di Poincaré. Replica esattamente bounds,
  /// reservedSize e axisName dello ScatterChart sovrapposto, ma con titoli e
  /// griglia invisibili (li disegna lo scatter) così l'area di plotting è la
  /// stessa e le linee restano allineate ai punti.
  Widget _buildOverlay(
    ThemeData theme,
    double lo,
    double hi,
    double interval,
    double meanRr,
  ) {
    final scheme = theme.colorScheme;
    final sd1 = metrics.sd1Ms;
    final sd2 = metrics.sd2Ms;

    // Diagonale identità RR n = RR n+1: due punti agli estremi dell'asse.
    final diagonal = [FlSpot(lo, lo), FlSpot(hi, hi)];

    // Ellisse: semiasse SD2 lungo la diagonale (+45°), SD1 perpendicolare.
    // Parametrizzazione (SD2·cosθ, SD1·sinθ) ruotata di 45° attorno al centro
    // (meanRr, meanRr). ~48 punti + chiusura.
    const cos45 = math.sqrt1_2; // cos45 = sin45 = 1/√2
    const steps = 48;
    final ellipse = <FlSpot>[];
    for (var i = 0; i <= steps; i++) {
      final th = 2 * math.pi * i / steps;
      final a = sd2 * math.cos(th); // lungo diagonale
      final b = sd1 * math.sin(th); // perpendicolare
      final dx = (a - b) * cos45;
      final dy = (a + b) * cos45;
      ellipse.add(FlSpot(
        (meanRr + dx).clamp(lo, hi),
        (meanRr + dy).clamp(lo, hi),
      ));
    }

    // Titoli invisibili ma con reservedSize/axisName identici allo scatter:
    // è ciò che garantisce l'allineamento dell'area di plotting.
    AxisTitles namedAxis(String name, double reserved) => AxisTitles(
          axisNameWidget: Text(name,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: Colors.transparent)),
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: reserved,
            interval: interval,
            getTitlesWidget: (v, _) => const SizedBox.shrink(),
          ),
        );

    return LineChart(LineChartData(
      minX: lo,
      maxX: hi,
      minY: lo,
      maxY: hi,
      clipData: const FlClipData.all(),
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      lineTouchData: const LineTouchData(enabled: false),
      titlesData: FlTitlesData(
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: namedAxis('RR n+1 (ms)', 36),
        bottomTitles: namedAxis('RR n (ms)', 22),
      ),
      lineBarsData: [
        // Diagonale identità: tratteggio tenue sull'outline.
        LineChartBarData(
          spots: diagonal,
          isCurved: false,
          barWidth: 1,
          color: scheme.outline.withValues(alpha: 0.6),
          dotData: const FlDotData(show: false),
          dashArray: const [5, 4],
        ),
        // Ellisse SD1/SD2: solo contorno. Niente area-fill: fl_chart riempie
        // verso il fondo dell'asse, non "dentro" il loop, quindi un fill qui
        // colorerebbe una regione spuria sotto la polilinea.
        LineChartBarData(
          spots: ellipse,
          isCurved: false,
          barWidth: 1.6,
          color: scheme.primary.withValues(alpha: 0.7),
          dotData: const FlDotData(show: false),
        ),
      ],
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

/// Spettro di potenza: bilancio LF/HF (barra normalizzata, zero ricalcolo) +
/// PSD reale via Lomb-Scargle, con bande LF/HF ombreggiate, marker sulla
/// frequenza del pacer e annotazione del picco. Insight tag-aware in coda.
class _SpectrumCard extends StatelessWidget {
  final List<RrInterval> rr;
  final HrvMetrics metrics;
  final BreathingPattern pattern;
  const _SpectrumCard({
    required this.rr,
    required this.metrics,
    required this.pattern,
  });

  // La banda osservata coincide con quella del calcolo metriche
  // (HrvCalculator.spectrum: 0.04-0.40 Hz). Costanti per disegnare bande.
  static const double _loHz = 0.04;
  static const double _lfHfHz = 0.15; // confine LF | HF
  static const double _hiHz = 0.40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = HrvCalculator.spectrum(rr);
    final hasSpectrum = rr.length >= 20 && spec.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Spettro', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('(potenza per frequenza)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            // Primario: bilancio LF/HF in unità normalizzate (zero ricalcolo).
            _LfHfBar(lfNu: metrics.lfNu, hfNu: metrics.hfNu),
            const SizedBox(height: 16),
            if (!hasSpectrum)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'Spettro non disponibile',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              )
            else ...[
              Text('Periodogramma di Lomb-Scargle',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 8),
              _SpectrumLegend(scheme: theme.colorScheme),
              const SizedBox(height: 8),
              SizedBox(
                height: 170,
                child: _buildPsd(theme, spec),
              ),
              const SizedBox(height: 12),
              _InsightBox(insight: interpretSpectrum(metrics, pattern)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPsd(ThemeData theme, List<(double, double)> spec) {
    final scheme = theme.colorScheme;
    final spots = [for (final (f, p) in spec) FlSpot(f, p)];
    final peakP = spec.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
    // Headroom 18% sopra il picco per far respirare l'annotazione.
    final yMax = peakP <= 0 ? 1.0 : (peakP * 1.18);
    // Picco LF (frequenza già nel modello): è ciò che annotiamo.
    final peakHz = metrics.lfPeakHz > 0 ? metrics.lfPeakHz : pattern.frequencyHz;
    final pacerHz = pattern.frequencyHz;

    return LineChart(LineChartData(
      minX: _loHz,
      maxX: _hiHz,
      minY: 0,
      maxY: yMax,
      clipData: const FlClipData.all(),
      gridData: const FlGridData(show: false),
      // Bande LF (0.04-0.15) e HF (0.15-0.40) come fasce di sfondo verticali.
      rangeAnnotations: RangeAnnotations(
        verticalRangeAnnotations: [
          VerticalRangeAnnotation(
            x1: _loHz,
            x2: _lfHfHz,
            color: scheme.tertiary.withValues(alpha: 0.10),
          ),
          VerticalRangeAnnotation(
            x1: _lfHfHz,
            x2: _hiHz,
            color: scheme.secondary.withValues(alpha: 0.10),
          ),
        ],
      ),
      // Marker verticale sulla frequenza del pacer + linea sul picco LF.
      extraLinesData: ExtraLinesData(
        verticalLines: [
          VerticalLine(
            x: pacerHz,
            color: scheme.primary.withValues(alpha: 0.8),
            strokeWidth: 1.4,
            dashArray: const [4, 3],
            label: VerticalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
              labelResolver: (_) =>
                  'pacer ${pattern.breathsPerMinute.toStringAsFixed(1)}',
            ),
          ),
        ],
      ),
      titlesData: FlTitlesData(
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 18,
            interval: 0.1,
            getTitlesWidget: (v, _) => Text(
              v.toStringAsFixed(2),
              style: theme.textTheme.labelSmall,
            ),
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
          isCurved: true,
          curveSmoothness: 0.15,
          barWidth: 1.6,
          color: scheme.primary,
          dotData: FlDotData(
            // Un solo dot, sul picco LF, come annotazione.
            show: true,
            checkToShowDot: (spot, _) => (spot.x - peakHz).abs() < 1e-6,
            getDotPainter: (s, _, _, _) => FlDotCirclePainter(
              radius: 3,
              color: scheme.primary,
              strokeWidth: 0,
            ),
          ),
          belowBarData: BarAreaData(
            show: true,
            color: scheme.primary.withValues(alpha: 0.12),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          fitInsideVertically: true,
          fitInsideHorizontally: true,
          getTooltipItems: (touched) => touched.map((s) {
            return LineTooltipItem(
              '${s.x.toStringAsFixed(3)} Hz\n'
              '${(s.x * 60).toStringAsFixed(1)} cicli/min',
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

/// Barra orizzontale impilata LF vs HF in unità normalizzate (n.u.).
/// Robusta al fatto che la potenza assoluta di Lomb-Scargle ha unità
/// arbitrarie: qui contano solo le proporzioni LF/(LF+HF) e HF/(LF+HF).
class _LfHfBar extends StatelessWidget {
  final double lfNu;
  final double hfNu;
  const _LfHfBar({required this.lfNu, required this.hfNu});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Difensivo: se entrambi nulli (spettro vuoto) mostriamo 50/50 neutro.
    final total = lfNu + hfNu;
    final lfFrac = total > 0 ? lfNu / total : 0.5;
    final hfFrac = total > 0 ? hfNu / total : 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Bilancio LF / HF',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
            const Spacer(),
            Text(
              'LF ${lfNu.toStringAsFixed(0)}% • HF ${hfNu.toStringAsFixed(0)}%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 16,
            child: Row(
              children: [
                Expanded(
                  flex: (lfFrac * 1000).round().clamp(1, 1000),
                  child: Container(color: scheme.tertiary),
                ),
                Expanded(
                  flex: (hfFrac * 1000).round().clamp(1, 1000),
                  child: Container(color: scheme.secondary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _BandKey(color: scheme.tertiary, label: 'LF 0.04–0.15 Hz'),
            const SizedBox(width: 14),
            _BandKey(color: scheme.secondary, label: 'HF 0.15–0.40 Hz'),
          ],
        ),
      ],
    );
  }
}

class _BandKey extends StatelessWidget {
  final Color color;
  final String label;
  const _BandKey({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}

/// Legenda del periodogramma: fasce di banda + marker pacer.
class _SpectrumLegend extends StatelessWidget {
  final ColorScheme scheme;
  const _SpectrumLegend({required this.scheme});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _BandKey(
            color: scheme.tertiary.withValues(alpha: 0.35), label: 'banda LF'),
        _BandKey(
            color: scheme.secondary.withValues(alpha: 0.35), label: 'banda HF'),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 2,
              child: CustomPaint(painter: _DashPainter(scheme.primary)),
            ),
            const SizedBox(width: 4),
            Text('pacer', style: textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

/// Legenda del tachogramma: linea RR + onda guida tratteggiata. Specchio
/// della legenda live in training_screen.dart.
class _TachoLegend extends StatelessWidget {
  final ColorScheme scheme;
  const _TachoLegend({required this.scheme});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Container(width: 10, height: 2.5, color: scheme.primary),
        const SizedBox(width: 4),
        Text('RR', style: textTheme.labelSmall),
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

/// Tratteggio orizzontale per le legende. Mirror di training_screen._DashPainter.
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

/// Pill di affidabilità della misura (high/moderate/low/insufficient).
class _ConfidencePill extends StatelessWidget {
  final HrvConfidence confidence;
  const _ConfidencePill({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (confidence) {
      HrvConfidence.high => Colors.green.shade600,
      HrvConfidence.moderate => Colors.amber.shade700,
      HrvConfidence.low => Colors.red.shade600,
      HrvConfidence.insufficient => Colors.grey.shade600,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_outlined, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            confidence.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Strip contestuale per le letture mattutine: postura + protocollo + flag di
/// contesto (sonno/alcol/malattia/stress/dolori) come icone compatte.
class _MorningStrip extends StatelessWidget {
  final MorningMeta meta;
  const _MorningStrip({required this.meta});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ctx = meta.context;

    // Flag confondenti → icona + tooltip. Solo quelli effettivamente attivi.
    final flags = <(IconData, String)>[
      if (ctx.sleep == SleepQuality.poor)
        (Icons.bedtime_off_outlined, ctx.sleep.label),
      if (ctx.alcohol) (Icons.local_bar_outlined, 'Alcol'),
      if (ctx.illness) (Icons.sick_outlined, 'Malattia'),
      if (ctx.stressed) (Icons.bolt_outlined, 'Stress'),
      if (ctx.soreness) (Icons.fitness_center_outlined, 'Dolori muscolari'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.accessibility_new, size: 15, color: scheme.primary),
          const SizedBox(width: 4),
          Text(meta.posture.label, style: theme.textTheme.labelMedium),
          const SizedBox(width: 12),
          Icon(Icons.straighten, size: 15, color: scheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              meta.protocol.label,
              style: theme.textTheme.labelMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (flags.isNotEmpty) ...[
            const Spacer(),
            for (final (icon, msg) in flags) ...[
              Tooltip(
                message: msg,
                child: Icon(icon, size: 16, color: scheme.error),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ],
      ),
    );
  }
}

class _EstimationDisclaimer extends StatelessWidget {
  const _EstimationDisclaimer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Valori stimati da HR a ~1 Hz: l\'Instinct Solar 2X non '
              'espone RR battito-battito reali. RMSSD/SDNN così calcolati '
              'tendono a essere 5-15% sotto la "Salute Istantanea" Garmin '
              'nativa, che usa il PPG ad alta frequenza. Utili per '
              'monitorare il proprio trend, non per confronti clinici '
              'inter-individuo.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
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

class _InsightBox extends StatelessWidget {
  final ChartInsight insight;
  const _InsightBox({required this.insight});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _levelColor(insight.level, theme);
    final icon = _levelIcon(insight.level);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  insight.headline,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            insight.body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Color _levelColor(InsightLevel l, ThemeData theme) => switch (l) {
        InsightLevel.excellent => Colors.green.shade600,
        InsightLevel.good => Colors.lightGreen.shade700,
        InsightLevel.fair => Colors.amber.shade700,
        InsightLevel.poor => Colors.red.shade600,
        InsightLevel.neutral => theme.colorScheme.primary,
      };

  IconData _levelIcon(InsightLevel l) => switch (l) {
        InsightLevel.excellent => Icons.star_rounded,
        InsightLevel.good => Icons.check_circle_outline,
        InsightLevel.fair => Icons.info_outline,
        InsightLevel.poor => Icons.warning_amber_rounded,
        InsightLevel.neutral => Icons.lightbulb_outline,
      };
}
