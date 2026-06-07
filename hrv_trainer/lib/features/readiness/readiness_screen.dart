import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../shared/hrv/readiness.dart';
import 'state/readiness_providers.dart';

/// Dashboard dedicata alla Morning Readiness.
///
/// Mostra in sequenza (ListView): un hero col semaforo banda + z-score, una
/// card di raccomandazione di carico azionabile (CTA contestuale alla banda),
/// il grafico trend lnRMSSD con media mobile 7gg e banda SWC, e una legenda.
///
/// È la versione "estesa" della [ReadinessCard] usata in home: stessi colori,
/// stessa semantica (banda/CV/saturazione vagale) ma con più contesto e con
/// il grafico storico, che nella card compatta non avrebbe spazio.
class ReadinessScreen extends ConsumerWidget {
  const ReadinessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readinessAsync = ref.watch(readinessSectionProvider);
    final trendAsync = ref.watch(readinessTrendProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Morning Readiness')),
      body: readinessAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(message: 'Errore readiness: $e'),
        data: (r) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _HeroCard(readiness: r),
            const SizedBox(height: 12),
            _RecommendationCard(readiness: r),
            const SizedBox(height: 12),
            _TrendCard(readiness: r, trendAsync: trendAsync),
            const SizedBox(height: 12),
            const _LegendCard(),
          ],
        ),
      ),
    );
  }
}

/// Colore del semaforo coerente con la home card: green→primary,
/// yellow→arancio, red→error, unknown→outline. Centralizzato qui perché
/// banda colore è usato in più punti (hero, CTA, dot del grafico).
Color _bandColor(ThemeData theme, ReadinessBand band) => switch (band) {
      ReadinessBand.green => theme.colorScheme.primary,
      ReadinessBand.yellow => Colors.orange.shade700,
      ReadinessBand.red => theme.colorScheme.error,
      ReadinessBand.unknown => theme.colorScheme.outline,
    };

/// Stessa palette sobria della home per la riga CV: neutro quando stabile,
/// ambra/rosso al crescere dell'instabilità.
Color _cvColor(ThemeData theme, CvStability s) => switch (s) {
      CvStability.stable => theme.colorScheme.onSurfaceVariant,
      CvStability.moderate => Colors.orange.shade700,
      CvStability.unstable => theme.colorScheme.error,
      CvStability.unknown => theme.colorScheme.onSurfaceVariant,
    };

/// z-score formattato con segno e suffisso σ (es. '-1.2σ', '+0.4σ').
String _formatZ(double z) =>
    '${z >= 0 ? '+' : ''}${z.toStringAsFixed(1)}σ';

// =============================================================================
// 1) Hero status card
// =============================================================================

class _HeroCard extends StatelessWidget {
  final Readiness readiness;
  const _HeroCard({required this.readiness});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _bandColor(theme, readiness.band);
    final isUnknown = readiness.band == ReadinessBand.unknown;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Banda colorata in alto: la "striscia semaforo" che dà a colpo
          // d'occhio lo stato senza dover leggere il testo.
          Container(
            height: 8,
            color: color,
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text('Stato di oggi', style: theme.textTheme.labelLarge),
                    const Spacer(),
                    if (readiness.zScore != null)
                      _ZChip(z: readiness.zScore!, color: color),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  readiness.headline,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(readiness.message, style: theme.textTheme.bodyMedium),
                if (!isUnknown && readiness.baselineRmssd != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'RMSSD oggi ${readiness.todayRmssd.toStringAsFixed(0)} ms '
                    '• baseline ${readiness.baselineRmssd!.toStringAsFixed(0)} ms '
                    '(${readiness.baselineDays} gg)',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (readiness.cvPct != null) ...[
                  const SizedBox(height: 6),
                  _CvRow(readiness: readiness),
                ],
                if (readiness.vagalSaturation) ...[
                  const SizedBox(height: 10),
                  _VagalNote(color: color),
                ],
                if (isUnknown) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    icon: const Icon(Icons.wb_sunny_outlined),
                    label: const Text('Nuovo check-in'),
                    onPressed: () => context.push('/readiness/checkin'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ZChip extends StatelessWidget {
  final double z;
  final Color color;
  const _ZChip({required this.z, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        _formatZ(z),
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Riga CV(lnRMSSD) condivisa fra hero e card: 'Stabilità 7gg • CV X% (label)'.
class _CvRow extends StatelessWidget {
  final Readiness readiness;
  const _CvRow({required this.readiness});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _cvColor(theme, readiness.cvStability);
    return Row(
      children: [
        Icon(Icons.show_chart, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          'Stabilità 7gg • CV ${readiness.cvPct!.toStringAsFixed(1)}% '
          '(${readiness.cvLabel})',
          style: theme.textTheme.labelMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// Nota discreta sulla saturazione vagale: RMSSD basso ma HR sotto baseline
/// = dominanza parasimpatica, non fatica. Volutamente sobria (surface, non
/// allarmistica) per non far leggere come "rosso" uno stato di recupero.
class _VagalNote extends StatelessWidget {
  final Color color;
  const _VagalNote({required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.spa_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Possibile saturazione vagale: RMSSD basso con HR sotto il tuo '
              'baseline indica dominanza parasimpatica, non fatica. La banda è '
              'stata ammorbidita di conseguenza.',
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

// =============================================================================
// 2) Recommendation card
// =============================================================================

class _RecommendationCard extends StatelessWidget {
  final Readiness readiness;
  const _RecommendationCard({required this.readiness});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _bandColor(theme, readiness.band);
    final advice = readiness.advice;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(_adviceIcon(advice), color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Raccomandazione', style: theme.textTheme.labelMedium),
                      const SizedBox(height: 2),
                      Text(
                        advice.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (readiness.adviceText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                readiness.adviceText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 14),
            // CTA primaria contestuale alla banda. Per banda unknown il CTA
            // principale è comunque il check-in (non avrebbe senso proporre un
            // allenamento senza readiness), quindi cade nel secondario sotto.
            if (readiness.band != ReadinessBand.unknown)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: Icon(_ctaIcon(readiness.band)),
                  label: Text(_ctaLabel(readiness.band)),
                  onPressed: () => context.push(_ctaRoute(readiness.band)),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.wb_sunny_outlined),
                label: const Text('Nuovo check-in mattutino'),
                onPressed: () => context.push('/readiness/checkin'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _adviceIcon(TrainingAdvice a) => switch (a) {
        TrainingAdvice.trainHard => Icons.bolt,
        TrainingAdvice.trainEasy => Icons.directions_walk,
        TrainingAdvice.rest => Icons.self_improvement,
        TrainingAdvice.unknown => Icons.help_outline,
      };

  // CTA: green→training pieno, yellow→training tag recovery, red→pacer
  // (respirazione lenta come recupero attivo).
  String _ctaRoute(ReadinessBand b) => switch (b) {
        ReadinessBand.green => '/training',
        ReadinessBand.yellow => '/training?tag=recovery',
        ReadinessBand.red => '/pacer',
        ReadinessBand.unknown => '/readiness/checkin',
      };

  String _ctaLabel(ReadinessBand b) => switch (b) {
        ReadinessBand.green => 'Inizia allenamento',
        ReadinessBand.yellow => 'Sessione recovery',
        ReadinessBand.red => 'Respirazione lenta',
        ReadinessBand.unknown => 'Nuovo check-in',
      };

  IconData _ctaIcon(ReadinessBand b) => switch (b) {
        ReadinessBand.green => Icons.play_arrow,
        ReadinessBand.yellow => Icons.spa,
        ReadinessBand.red => Icons.air,
        ReadinessBand.unknown => Icons.wb_sunny_outlined,
      };
}

// =============================================================================
// 3) Trend card
// =============================================================================

class _TrendCard extends StatelessWidget {
  final Readiness readiness;
  final AsyncValue<List<ReadinessTrendPoint>> trendAsync;
  const _TrendCard({required this.readiness, required this.trendAsync});

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
                Text('Trend lnRMSSD', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '(scala log)',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            trendAsync.when(
              loading: () => const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SizedBox(
                height: 120,
                child: Center(child: Text('Errore trend: $e')),
              ),
              data: (points) => _TrendChartArea(
                points: points,
                swcLn: readiness.swcLn,
              ),
            ),
            if (readiness.cvPct != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              _CvRow(readiness: readiness),
            ],
          ],
        ),
      ),
    );
  }
}

/// Area grafico vera e propria: gestisce il placeholder per serie corte e
/// disegna il LineChart quando ci sono abbastanza punti.
///
/// Soglia a 3 punti: sotto, la media mobile e la banda SWC non hanno senso e
/// un grafico con 1-2 punti è solo rumore visivo.
class _TrendChartArea extends StatelessWidget {
  final List<ReadinessTrendPoint> points;
  final double? swcLn;
  const _TrendChartArea({required this.points, required this.swcLn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (points.length < 3) {
      return _ChartPlaceholder(
        text: points.isEmpty
            ? 'Nessuna lettura morning ancora registrata.\n'
                'Fai un check-in mattutino per iniziare il trend.'
            : 'Servono almeno 3 letture morning per il trend '
                '(${points.length} finora).',
      );
    }

    final scheme = theme.colorScheme;
    final df = DateFormat('dd/MM');

    // Spot serie principale (lnRMSSD giornaliero) e media mobile 7gg.
    final lnSpots = <FlSpot>[];
    final meanSpots = <FlSpot>[];
    // Helper invisibili per la banda SWC: media ± swcLn. La banda "viaggia"
    // con la media mobile (non è una fascia orizzontale fissa), così riflette
    // la "current normal" che evolve nel tempo.
    final bandHiSpots = <FlSpot>[];
    final bandLoSpots = <FlSpot>[];
    final swc = swcLn ?? 0.0;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final x = i.toDouble();
      lnSpots.add(FlSpot(x, p.lnRmssd));
      meanSpots.add(FlSpot(x, p.rollingMean7Ln));
      bandHiSpots.add(FlSpot(x, p.rollingMean7Ln + swc));
      bandLoSpots.add(FlSpot(x, p.rollingMean7Ln - swc));
    }

    // Range Y con padding, considerando anche i bordi della banda così la
    // fascia non viene clippata in alto/basso.
    final ys = <double>[
      ...points.map((p) => p.lnRmssd),
      ...bandHiSpots.map((s) => s.y),
      ...bandLoSpots.map((s) => s.y),
    ];
    final yMinData = ys.reduce(math.min);
    final yMaxData = ys.reduce(math.max);
    final pad = ((yMaxData - yMinData) * 0.15).clamp(0.05, 1.0).toDouble();
    final yMin = yMinData - pad;
    final yMax = yMaxData + pad;
    final yRange = (yMax - yMin).abs();
    // clamp ritorna num: forziamo a double perché fl_chart vuole double? per
    // gli interval. L'upper bound non può essere < del lower (assert clamp),
    // quindi quando il range è ~0 lo alziamo a 0.05.
    final yInterval =
        (yRange / 4).clamp(0.05, yRange < 0.05 ? 0.05 : yRange).toDouble();

    // Step label X: come in history TrendCard, ~5 etichette, mai > range.
    final xLabelStep = points.length <= 1
        ? 1.0
        : (points.length / 5).ceil().clamp(1, points.length - 1).toDouble();

    // Indici: 0 = banda alta, 1 = banda bassa (riempite fra loro), 2 = media
    // mobile, 3 = lnRMSSD. L'ordine conta per betweenBarsData (from/to index).
    final hasBand = swc > 0;

    return SizedBox(
      height: 220,
      child: LineChart(LineChartData(
        minX: -0.5,
        maxX: (points.length - 1) + 0.5,
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
                v.toStringAsFixed(1),
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: xLabelStep,
              getTitlesWidget: (v, _) {
                final i = v.round();
                if (i < 0 || i >= points.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    df.format(points[i].date.toLocal()),
                    style: theme.textTheme.labelSmall,
                  ),
                );
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
        betweenBarsData: hasBand
            ? [
                BetweenBarsData(
                  fromIndex: 0,
                  toIndex: 1,
                  color: scheme.primary.withValues(alpha: 0.12),
                ),
              ]
            : const [],
        lineBarsData: [
          // 0: bordo superiore banda SWC (invisibile, serve solo a delimitare
          // l'area di betweenBarsData).
          LineChartBarData(
            spots: bandHiSpots,
            color: Colors.transparent,
            barWidth: 0,
            dotData: const FlDotData(show: false),
          ),
          // 1: bordo inferiore banda SWC.
          LineChartBarData(
            spots: bandLoSpots,
            color: Colors.transparent,
            barWidth: 0,
            dotData: const FlDotData(show: false),
          ),
          // 2: media mobile 7gg (la "current normal").
          LineChartBarData(
            spots: meanSpots,
            color: scheme.secondary,
            barWidth: 2,
            isCurved: true,
            dashArray: const [5, 4],
            dotData: const FlDotData(show: false),
          ),
          // 3: lnRMSSD giornaliero. I punti con context-flag (alcol, malattia,
          // stress…) hanno un dot di colore distinto per spiegare eventuali
          // outlier senza nascondere il dato.
          LineChartBarData(
            spots: lnSpots,
            color: scheme.primary,
            barWidth: 2,
            isCurved: false,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, _, _, _) {
                final i = spot.x.round();
                final flagged =
                    i >= 0 && i < points.length && points[i].hasContextFlags;
                return FlDotCirclePainter(
                  radius: flagged ? 4 : 3,
                  color: flagged ? Colors.orange.shade700 : scheme.primary,
                  strokeWidth: flagged ? 1.5 : 0,
                  strokeColor: scheme.surface,
                );
              },
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            fitInsideVertically: true,
            fitInsideHorizontally: true,
            tooltipMargin: 8,
            getTooltipItems: (spots) => spots.map((s) {
              // Mostriamo il tooltip solo per le due barre "vere" (media e
              // lnRMSSD): le barre helper della banda sono trasparenti e un
              // loro tooltip confonderebbe.
              if (s.barIndex != 2 && s.barIndex != 3) return null;
              final i = s.x.round();
              if (i < 0 || i >= points.length) return null;
              final p = points[i];
              final isMean = s.barIndex == 2;
              final label = isMean ? 'Media 7gg' : 'lnRMSSD';
              final flag = (!isMean && p.hasContextFlags) ? '\n⚑ con note' : '';
              return LineTooltipItem(
                '${df.format(p.date.toLocal())}\n'
                '$label: ${s.y.toStringAsFixed(2)}$flag',
                TextStyle(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w500,
                ),
              );
            }).toList(),
          ),
        ),
      )),
    );
  }
}

class _ChartPlaceholder extends StatelessWidget {
  final String text;
  const _ChartPlaceholder({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 160,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 4) Stability / legend explainer
// =============================================================================

class _LegendCard extends StatelessWidget {
  const _LegendCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Come leggere il grafico', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            _LegendRow(
              swatch: _LineSwatch(color: scheme.primary),
              label: 'lnRMSSD giornaliero',
              hint: 'La singola lettura morning (scala log).',
            ),
            const SizedBox(height: 8),
            _LegendRow(
              swatch: _LineSwatch(color: scheme.secondary, dashed: true),
              label: 'Media mobile 7gg',
              hint: 'La "current normal": tendenza recente.',
            ),
            const SizedBox(height: 8),
            _LegendRow(
              swatch: _BandSwatch(color: scheme.primary),
              label: 'Banda SWC (media ± 0.5·SD)',
              hint: 'Variazione attesa: fuori banda = cambiamento reale.',
            ),
            const SizedBox(height: 8),
            _LegendRow(
              swatch: _DotSwatch(color: Colors.orange.shade700),
              label: 'Giorno con note di contesto',
              hint: 'Alcol, malattia, stress o sonno scarso segnalati al '
                  'check-in: utile per spiegare un outlier.',
            ),
            const Divider(height: 28),
            Text(
              'Stabilità (CV lnRMSSD 7gg): <5% stabile, 5-10% oscillante, '
              '≥10% instabile. Il segnale forte è il trend del CV nel tempo, '
              'non il valore assoluto: un CV in salita anticipa l\'instabilità '
              'autonomica prima che la media crolli.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final Widget swatch;
  final String label;
  final String hint;
  const _LegendRow({
    required this.swatch,
    required this.label,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: SizedBox(width: 28, child: Center(child: swatch)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
              Text(
                hint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Campioncino "linea" per la legenda: piena o tratteggiata.
class _LineSwatch extends StatelessWidget {
  final Color color;
  final bool dashed;
  const _LineSwatch({required this.color, this.dashed = false});

  @override
  Widget build(BuildContext context) {
    if (!dashed) {
      return Container(
        width: 22,
        height: 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    // Tratteggio: tre segmentini per evocare la linea dashed della media.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (_) => Container(
          width: 5,
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Campioncino "banda" per la legenda: rettangolino semitrasparente come la
/// fascia SWC del grafico.
class _BandSwatch extends StatelessWidget {
  final Color color;
  const _BandSwatch({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 22,
        height: 12,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
      );
}

/// Campioncino "dot" per la legenda: pallino come quello dei giorni flaggati.
class _DotSwatch extends StatelessWidget {
  final Color color;
  const _DotSwatch({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

// =============================================================================
// Errori a tutto schermo (con escape verso il check-in)
// =============================================================================

class _ErrorBody extends StatelessWidget {
  final String message;
  const _ErrorBody({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.wb_sunny_outlined),
              label: const Text('Nuovo check-in'),
              onPressed: () => context.push('/readiness/checkin'),
            ),
          ],
        ),
      ),
    );
  }
}
