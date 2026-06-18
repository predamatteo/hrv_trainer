import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../session_chart_utils.dart';
import '../session_models.dart';

/// Trend principale in spazio **lnRMSSD** (spostato qui dallo Storico: è una
/// vista d'analisi cronica, non parte del registro).
///
///  - Serie primaria = ln(RMSSD): trasformazione standard per normalizzare la
///    distribuzione skewed dell'RMSSD ed è lo spazio in cui la readiness calcola
///    baseline/SWC. Confrontare giorni in lnRMSSD evita che un singolo valore
///    alto schiacci visivamente tutto il resto.
///  - Banda baseline ombreggiata = media mobile ± 1 SD del lnRMSSD sulle
///    sessioni mostrate: dà il "corridoio normale". Punti sopra/sotto la banda
///    sono fuori dalla propria variabilità abituale.
///  - Pallini colorati per tag: post-workout, morning, stress... hanno vago in
///    stati fisiologicamente diversi; colorarli evita di leggere come "calo HRV"
///    ciò che è solo un contesto diverso mescolato sulla stessa linea.
///  - L'HRV score (0-100) è relegato a una sparkline sottile separata per
///    evitare la collisione di scala con lnRMSSD (~3-5).
///
/// [sessions] deve essere in ordine cronologico (vecchie → recenti).
class LnRmssdTrendCard extends StatelessWidget {
  final List<Session> sessions;
  const LnRmssdTrendCard({super.key, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Spot lnRMSSD: indici di posizione, non di tempo (asse categorico). I
    // valori non finiti vengono saltati ma l'indice X resta allineato all'array
    // `sessions` per il tap-to-detail.
    final lnSpots = <FlSpot>[];
    final lnValues = <double>[]; // per media/SD/CV (solo valori validi)
    for (var i = 0; i < sessions.length; i++) {
      final ln = lnRmssdOf(sessions[i]);
      if (ln == null) continue;
      lnSpots.add(FlSpot(i.toDouble(), ln));
      lnValues.add(ln);
    }
    final scoreSpots = <FlSpot>[
      for (var i = 0; i < sessions.length; i++)
        FlSpot(i.toDouble(), sessions[i].metrics.hrvScore),
    ];

    // Banda baseline: media e SD (campionaria) del lnRMSSD sulle sessioni
    // mostrate. È volutamente una statistica "trailing semplice" sull'intera
    // finestra visibile, non la baseline rolling-7 della readiness: qui serve
    // come riferimento visivo del corridoio normale del periodo guardato.
    final mean = lnValues.isEmpty
        ? 0.0
        : lnValues.reduce((a, b) => a + b) / lnValues.length;
    final sd = lnValues.length < 2
        ? 0.0
        : math.sqrt(lnValues
                .map((v) => (v - mean) * (v - mean))
                .reduce((a, b) => a + b) /
            (lnValues.length - 1));
    final bandLow = mean - sd;
    final bandHigh = mean + sd;

    // CV(lnRMSSD) sugli ultimi 7 giorni: indicatore di stabilità autonomica.
    final cv7 = _cvLnLast7Days(sessions);

    // Range Y con un po' di margine attorno a banda e dati per non clippare i
    // pallini estremi né la banda.
    final allY = <double>[...lnValues, bandLow, bandHigh];
    var minY = allY.isEmpty ? 0.0 : allY.reduce(math.min);
    var maxY = allY.isEmpty ? 1.0 : allY.reduce(math.max);
    final pad = (maxY - minY) * 0.12 + 0.05;
    minY -= pad;
    maxY += pad;

    // interval per i label dell'asse X: almeno 1, mai > numero di sessioni
    // (fl_chart asserta interval <= range). Per liste corte si vede ogni label.
    final xLabelStep = sessions.length <= 1
        ? 1.0
        : (sessions.length / 5).ceil().clamp(1, sessions.length - 1).toDouble();
    final df = DateFormat('dd/MM');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Trend lnRMSSD (${sessions.length} sessioni)',
                      style: theme.textTheme.titleMedium),
                ),
                Text('Tap punto = dettaglio',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minX: -0.5,
                maxX: (sessions.length - 1) + 0.5,
                minY: minY,
                maxY: maxY,
                // Banda baseline ombreggiata: due linee orizzontali invisibili
                // (a bandLow e bandHigh) riempite in mezzo con betweenBarsData.
                rangeAnnotations: RangeAnnotations(
                  horizontalRangeAnnotations: [
                    if (lnValues.length >= 2)
                      HorizontalRangeAnnotation(
                        y1: bandLow,
                        y2: bandHigh,
                        color: scheme.primary.withValues(alpha: 0.10),
                      ),
                  ],
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: 0.5,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
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
                        final i = v.toInt();
                        if (i < 0 || i >= sessions.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            df.format(sessions[i].startedAt.toLocal()),
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
                // Linea della media baseline come riferimento al centro della
                // fascia (tratteggiata, neutra).
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (lnValues.isNotEmpty)
                      HorizontalLine(
                        y: mean,
                        color: scheme.outline.withValues(alpha: 0.6),
                        strokeWidth: 1,
                        dashArray: const [3, 4],
                      ),
                  ],
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: lnSpots,
                    // Linea neutra di collegamento: il segnale di contesto sta
                    // nei pallini, non nel colore della linea.
                    color: scheme.primary.withValues(alpha: 0.55),
                    barWidth: 2,
                    dotData: FlDotData(
                      show: true,
                      // Pallino colorato per tag della sessione corrispondente.
                      getDotPainter: (spot, _, _, _) {
                        final i = spot.x.toInt();
                        final c = (i >= 0 && i < sessions.length)
                            ? tagColor(sessions[i].tag)
                            : scheme.primary;
                        return FlDotCirclePainter(
                          radius: 3.5,
                          color: c,
                          strokeWidth: 1.2,
                          strokeColor: scheme.surface,
                        );
                      },
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideVertically: true,
                    fitInsideHorizontally: true,
                    tooltipMargin: 8,
                    getTooltipItems: (spots) => spots.map((s) {
                      final i = s.x.toInt();
                      if (i < 0 || i >= sessions.length) return null;
                      final sess = sessions[i];
                      return LineTooltipItem(
                        '${df.format(sess.startedAt.toLocal())}\n'
                        '${sess.tag.label}\n'
                        'lnRMSSD ${s.y.toStringAsFixed(2)} '
                        '(RMSSD ${sess.metrics.rmssdMs.toStringAsFixed(0)})',
                        TextStyle(color: scheme.onInverseSurface),
                      );
                    }).toList(),
                  ),
                  touchCallback: (event, response) {
                    if (event is! FlTapUpEvent) return;
                    final spots = response?.lineBarSpots;
                    if (spots == null || spots.isEmpty) return;
                    final idx = spots.first.x.toInt();
                    if (idx < 0 || idx >= sessions.length) return;
                    final id = sessions[idx].id;
                    if (id != null) {
                      context.push('/history/session/$id');
                    }
                  },
                ),
              )),
            ),
            const SizedBox(height: 10),
            // Stat compatta CV(lnRMSSD) 7gg + legenda banda.
            Wrap(
              spacing: 16,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'CV(lnRMSSD) 7gg: '
                  '${cv7 == null ? '—' : '${cv7.toStringAsFixed(1)}%'}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _bandLegend(scheme, 'Baseline ±1 SD'),
              ],
            ),
            const SizedBox(height: 8),
            // Sparkline secondaria sottile per l'HRV score (0-100), separata
            // dall'asse principale per evitare la collisione di scala.
            _ScoreSparkline(spots: scoreSpots),
            const SizedBox(height: 8),
            // Legenda dei tag: una sola riga scrollabile coi colori usati nei
            // pallini, così l'utente sa come leggere i contesti.
            SizedBox(
              height: 22,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in SessionTag.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _legend(tagColor(t), t.label),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// CV(lnRMSSD) sulle sessioni delle ultime 168h. null se < 2 valori validi.
  static double? _cvLnLast7Days(List<Session> sessions) {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final vals = <double>[];
    for (final s in sessions) {
      if (s.startedAt.isBefore(cutoff)) continue;
      final ln = lnRmssdOf(s);
      if (ln != null) vals.add(ln);
    }
    if (vals.length < 2) return null;
    final m = vals.reduce((a, b) => a + b) / vals.length;
    if (m == 0) return null;
    final variance =
        vals.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) /
            (vals.length - 1);
    return 100.0 * math.sqrt(variance) / m.abs();
  }

  Widget _legend(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label),
        ],
      );

  Widget _bandLegend(ColorScheme scheme, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 12,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.5),
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      );
}

/// Sparkline sottile e separata per l'HRV score (0-100). Tenuta fuori dall'asse
/// principale lnRMSSD per non avere due scale incompatibili sullo stesso grafico
/// (lnRMSSD ~3-5 vs score 0-100). Niente assi/griglia: serve solo l'andamento.
class _ScoreSparkline extends StatelessWidget {
  final List<FlSpot> spots;
  const _ScoreSparkline({required this.spots});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (spots.length < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HRV score (0-100)',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.outline)),
        const SizedBox(height: 2),
        SizedBox(
          height: 36,
          child: LineChart(LineChartData(
            minY: 0,
            maxY: 100,
            minX: spots.first.x - 0.5,
            maxX: spots.last.x + 0.5,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                color: scheme.secondary,
                barWidth: 1.5,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: scheme.secondary.withValues(alpha: 0.12),
                ),
              ),
            ],
          )),
        ),
      ],
    );
  }
}
