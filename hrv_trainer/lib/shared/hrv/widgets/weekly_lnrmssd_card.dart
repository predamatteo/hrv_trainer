import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../session_chart_utils.dart';
import '../session_models.dart';

/// Aggregato settimanale del lnRMSSD: bucket per settimana ISO, barre della
/// MEDIA lnRMSSD della settimana con il numero di sessioni come label/tooltip.
///
/// Aggregare per settimana smussa il rumore giornaliero (sonno, idratazione,
/// orario di misura) e rende visibile il trend di fondo dell'adattamento. Pura
/// aggregazione in memoria sulla lista già caricata; non mostrato con meno di
/// 2 settimane di dati (un'unica barra non è un trend).
///
/// [sessions] in ordine cronologico (vecchie → recenti).
class WeeklyLnRmssdCard extends StatelessWidget {
  final List<Session> sessions;
  const WeeklyLnRmssdCard({super.key, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final weeks = _aggregateByIsoWeek(sessions);
    if (weeks.length < 2) return const SizedBox.shrink();

    final maxMean = weeks.map((w) => w.meanLn).fold<double>(0, math.max);
    // Label X: data del lunedì della settimana, ridotta per non affollare.
    final df = DateFormat('dd/MM');
    final int labelStep = (weeks.length / 6).ceil().clamp(1, weeks.length);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Media settimanale lnRMSSD',
                      style: theme.textTheme.titleMedium),
                ),
                Text('${weeks.length} settimane',
                    style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: BarChart(BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxMean * 1.18 + 0.05,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: 0.5,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
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
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= weeks.length) {
                          return const SizedBox.shrink();
                        }
                        if (i % labelStep != 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            df.format(weeks[i].weekStart),
                            style: theme.textTheme.labelSmall,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    fitInsideVertically: true,
                    fitInsideHorizontally: true,
                    getTooltipItem: (group, _, rod, _) {
                      final w = weeks[group.x];
                      return BarTooltipItem(
                        'Sett. ${df.format(w.weekStart)}\n'
                        'lnRMSSD medio ${w.meanLn.toStringAsFixed(2)}\n'
                        '${w.count} sessioni',
                        TextStyle(color: scheme.onInverseSurface),
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < weeks.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: weeks[i].meanLn,
                          color: scheme.primary,
                          width: 14,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    ),
                ],
              )),
            ),
            const SizedBox(height: 6),
            Text(
              'Ogni barra = media lnRMSSD della settimana; '
              'tocca per il numero di sessioni.',
              style:
                  theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  /// Bucket per settimana ISO (lunedì come inizio), ordinati cronologicamente.
  /// La chiave è il lunedì (a mezzanotte locale) della settimana che contiene
  /// `startedAt`; aggreghiamo solo lnRMSSD validi.
  static List<_WeekBucket> _aggregateByIsoWeek(List<Session> sessions) {
    final byWeek = <DateTime, List<double>>{};
    for (final s in sessions) {
      final ln = lnRmssdOf(s);
      if (ln == null) continue;
      final local = s.startedAt.toLocal();
      // Lunedì della settimana: weekday 1=lun..7=dom → sottrai (weekday-1) gg.
      final day = DateTime(local.year, local.month, local.day);
      final monday = day.subtract(Duration(days: day.weekday - 1));
      (byWeek[monday] ??= <double>[]).add(ln);
    }
    final out = byWeek.entries
        .map((e) => _WeekBucket(
              weekStart: e.key,
              meanLn: e.value.reduce((a, b) => a + b) / e.value.length,
              count: e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.weekStart.compareTo(b.weekStart));
    return out;
  }
}

/// Aggregato di una singola settimana ISO per [WeeklyLnRmssdCard].
class _WeekBucket {
  final DateTime weekStart;
  final double meanLn;
  final int count;
  const _WeekBucket({
    required this.weekStart,
    required this.meanLn,
    required this.count,
  });
}
