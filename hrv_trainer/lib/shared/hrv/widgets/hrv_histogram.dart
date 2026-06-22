import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../ui/ui.dart';
import '../session_models.dart';

/// Istogramma della distribuzione di HRV score (0-100) sulle sessioni
/// in [sessions]. Buckets da 10 punti per visualizzare la propria
/// "forma tipica" nel range.
class HrvHistogram extends StatelessWidget {
  final List<Session> sessions;
  final String title;

  const HrvHistogram({
    super.key,
    required this.sessions,
    this.title = 'Distribuzione HRV score',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    if (sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    // Buckets: 0-10, 10-20, ..., 90-100 (10 bucket da 10 punti).
    final buckets = List<int>.filled(10, 0);
    for (final s in sessions) {
      final score = s.metrics.hrvScore.clamp(0.0, 99.99);
      buckets[(score / 10).floor()]++;
    }
    final maxCount = buckets.reduce((a, b) => a > b ? a : b);

    return AppCard(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                Text(
                  '${sessions.length} sessioni',
                  style: theme.textTheme.labelSmall?.copyWith(color: t.faint),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: (maxCount + 1).toDouble(),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        interval: 1,
                        getTitlesWidget: (v, meta) {
                          final idx = v.toInt();
                          if (idx % 2 != 0) return const SizedBox.shrink();
                          return Text(
                            '${idx * 10}',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: t.faint),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < buckets.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: buckets[i].toDouble(),
                            color: t.primary,
                            width: 14,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
      ),
    );
  }
}
