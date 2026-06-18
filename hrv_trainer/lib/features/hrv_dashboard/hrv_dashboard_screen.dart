import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../shared/hrv/dashboard_stats.dart';
import '../../shared/hrv/hrv_trend.dart';
import '../../shared/hrv/readiness.dart' show CvStability;
import '../../shared/hrv/session_models.dart';
import '../../shared/hrv/widgets/ln_rmssd_trend_card.dart';
import '../readiness/state/readiness_providers.dart';
import 'state/hrv_dashboard_providers.dart';

/// Cruscotto "Andamento HRV": la vista CRONICA e interpretata dell'adattamento
/// nel tempo. Complementare alle altre due superfici:
///  - Morning Readiness = acuto ("mi alleno oggi?")
///  - Andamento HRV (questa) = cronico ("mi sto adattando? il training funziona?")
///  - Storico = registro ("cosa ho fatto, esporta i dati")
///
/// Ci si arriva dalla card "Stato generale HRV" in home. Raccoglie gli aggregati
/// (trend lnRMSSD, media settimanale, distribuzione) più le analisi specifiche
/// del biofeedback di risonanza che prima non avevano casa: coerenza nel
/// training, HRV per contesto, impatto delle abitudini.
class HrvDashboardScreen extends ConsumerWidget {
  const HrvDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(hrvDashboardSessionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Andamento HRV')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(hrvDashboardSessionsProvider);
          ref.invalidate(morningReadingsProvider);
          ref.invalidate(hrvGeneralStatusProvider);
          await ref.read(hrvDashboardSessionsProvider.future);
        },
        child: sessionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ScrollableMessage(
            child: Text('Errore nel caricamento: $e'),
          ),
          data: (sessions) => _Body(sessions: sessions),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final List<Session> sessions;
  const _Body({required this.sessions});

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const _ScrollableMessage(child: _EmptyState());
    }

    // Grafico generale: ordine cronologico (vecchie → recenti); il provider
    // restituisce newest-first.
    final chrono = sessions.reversed.toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        const _GeneralStatusCard(),
        const SizedBox(height: 12),
        // Grafico generale sotto il quadro cronico: andamento lnRMSSD di tutte
        // le sessioni della finestra, pallini colorati per contesto.
        if (chrono.length >= 3) ...[
          LnRmssdTrendCard(sessions: chrono),
          const SizedBox(height: 12),
        ],
        _CoherenceTrendCard(sessions: sessions),
        const SizedBox(height: 12),
        _HabitImpactCard(sessions: sessions),
      ],
    );
  }
}

// =============================================================================
// Quadro cronico (riusa lo stato generale calcolato per la card di home)
// =============================================================================

class _GeneralStatusCard extends ConsumerWidget {
  const _GeneralStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final async = ref.watch(hrvGeneralStatusProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quadro cronico', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            async.when(
              loading: () => const SizedBox(
                height: 40,
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (_, _) => Text(
                'Stato HRV non disponibile.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              data: (s) => _GeneralStatusBody(status: s),
            ),
          ],
        ),
      ),
    );
  }
}

class _GeneralStatusBody extends StatelessWidget {
  final HrvGeneralStatus status;
  const _GeneralStatusBody({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!status.hasLevel) {
      return Text(
        'L\'andamento comparirà dopo qualche lettura morning.',
        style:
            theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    final (dirIcon, dirColor, dirLabel) = _direction(theme, status.direction);
    final pct = status.deltaPct;
    final pctStr =
        pct == null ? '' : '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%';
    final span = status.spanWeeks == null ? '' : ' · ~${status.spanWeeks} sett.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.favorite_outline, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text('HRV tipico', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 8),
            Text(
              'RMSSD ${status.levelRmssd!.toStringAsFixed(0)} · '
              'score ${status.levelScore!.toStringAsFixed(0)}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (status.direction == HrvTrendDirection.unknown)
          Row(
            children: [
              Icon(Icons.timeline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Andamento disponibile dopo più letture morning.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              Icon(dirIcon, size: 18, color: dirColor),
              const SizedBox(width: 8),
              Text(
                dirLabel,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: dirColor, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$pctStr$span',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
        if (status.cvPct != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.show_chart, size: 16, color: _cvColor(theme, status.cvStability)),
              const SizedBox(width: 8),
              Text(
                'Stabilità: ${_cvLabel(status.cvStability)} '
                '(CV ${status.cvPct!.toStringAsFixed(1)}%)',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: _cvColor(theme, status.cvStability)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

(IconData, Color, String) _direction(ThemeData theme, HrvTrendDirection d) {
  final scheme = theme.colorScheme;
  return switch (d) {
    HrvTrendDirection.improving => (Icons.trending_up, scheme.primary, 'In miglioramento'),
    HrvTrendDirection.declining => (Icons.trending_down, Colors.orange.shade700, 'In calo'),
    HrvTrendDirection.stable => (Icons.trending_flat, scheme.onSurfaceVariant, 'Stabile'),
    HrvTrendDirection.unknown => (Icons.timeline, scheme.onSurfaceVariant, '—'),
  };
}

Color _cvColor(ThemeData theme, CvStability s) => switch (s) {
      CvStability.stable => theme.colorScheme.onSurfaceVariant,
      CvStability.moderate => Colors.orange.shade700,
      CvStability.unstable => theme.colorScheme.error,
      CvStability.unknown => theme.colorScheme.onSurfaceVariant,
    };

String _cvLabel(CvStability s) => switch (s) {
      CvStability.stable => 'stabile',
      CvStability.moderate => 'oscillante',
      CvStability.unstable => 'instabile',
      CvStability.unknown => '—',
    };

// =============================================================================
// 1) Coerenza nel training
// =============================================================================

class _CoherenceTrendCard extends StatelessWidget {
  final List<Session> sessions;
  const _CoherenceTrendCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pts = DashboardStats.coherenceTrend(sessions);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insights, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Coerenza nel training',
                      style: theme.textTheme.titleMedium),
                ),
                if (pts.isNotEmpty)
                  Text('${pts.length} sessioni',
                      style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Quanto l\'oscillazione cardiaca si concentra in un picco netto '
              '(respiro in risonanza). Più alta = meglio.',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.3),
            ),
            const SizedBox(height: 12),
            if (pts.length < 3)
              _CardPlaceholder(
                icon: Icons.self_improvement,
                text: 'Servono almeno 3 sessioni di training con segnale '
                    'valido per vedere il trend (${pts.length} finora).',
              )
            else
              _CoherenceChartArea(points: pts),
          ],
        ),
      ),
    );
  }
}

class _CoherenceChartArea extends StatelessWidget {
  final List<CoherenceTrendPoint> points;
  const _CoherenceChartArea({required this.points});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final df = DateFormat('dd/MM');

    final values = [for (final p in points) p.coherence];
    final roll = DashboardStats.rollingMean(
        values, DashboardStats.coherenceRollWindow);
    final lineSpots = [
      for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), values[i]),
    ];
    final rollSpots = [
      for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), roll[i]),
    ];

    final maxData = [...values, ...roll].reduce(math.max);
    final maxY = maxData * 1.18 + 0.1;
    final xStep = points.length <= 1
        ? 1.0
        : (points.length / 5).ceil().clamp(1, points.length - 1).toDouble();

    // Tendenza: media mobile finale vs iniziale → "stai migliorando?".
    final trendPct = roll.first > 0
        ? (roll.last / roll.first - 1) * 100.0
        : 0.0;
    final avg = values.reduce((a, b) => a + b) / values.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 180,
          child: LineChart(LineChartData(
            minX: -0.5,
            maxX: (points.length - 1) + 0.5,
            minY: 0,
            maxY: maxY,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
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
                  interval: xStep,
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
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
                left:
                    BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                bottom:
                    BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
            ),
            lineBarsData: [
              // Media mobile (linea di tendenza, tratteggiata).
              LineChartBarData(
                spots: rollSpots,
                color: scheme.secondary,
                barWidth: 2,
                isCurved: true,
                dashArray: const [5, 4],
                dotData: const FlDotData(show: false),
              ),
              // Coerenza per sessione, dot colorato per livello.
              LineChartBarData(
                spots: lineSpots,
                color: scheme.primary.withValues(alpha: 0.5),
                barWidth: 2,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, _, _, _) {
                    final i = spot.x.toInt();
                    final coh =
                        (i >= 0 && i < values.length) ? values[i] : 0.0;
                    return FlDotCirclePainter(
                      radius: 3.5,
                      color: _coherenceColor(scheme, coh),
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
                  // Solo la serie dei punti reali (barIndex 1), non la media.
                  if (s.barIndex != 1) return null;
                  final i = s.x.toInt();
                  if (i < 0 || i >= points.length) return null;
                  final p = points[i];
                  return LineTooltipItem(
                    '${df.format(p.date.toLocal())}\n'
                    'coerenza ${p.coherence.toStringAsFixed(1)} '
                    '(${_coherenceLabel(p.coherence)})\n'
                    '${p.bpm.toStringAsFixed(1)} bpm',
                    TextStyle(color: scheme.onInverseSurface),
                  );
                }).toList(),
              ),
              touchCallback: (event, response) {
                if (event is! FlTapUpEvent) return;
                final spots = response?.lineBarSpots;
                if (spots == null || spots.isEmpty) return;
                final idx = spots.first.x.toInt();
                if (idx < 0 || idx >= points.length) return;
                final id = points[idx].sessionId;
                if (id != null) context.push('/history/session/$id');
              },
            ),
          )),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('Media ${avg.toStringAsFixed(1)}',
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Icon(
              trendPct >= 3
                  ? Icons.trending_up
                  : (trendPct <= -3 ? Icons.trending_down : Icons.trending_flat),
              size: 16,
              color: trendPct >= 3
                  ? scheme.primary
                  : (trendPct <= -3
                      ? Colors.orange.shade700
                      : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 4),
            Text(
              '${trendPct >= 0 ? '+' : ''}${trendPct.toStringAsFixed(0)}% nel periodo',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _legendDot(theme, scheme.primary, 'netta (≥2.5)'),
            _legendDot(theme, scheme.secondary, 'discreta (1-2.5)'),
            _legendDot(theme, Colors.orange.shade700, 'diffusa (<1)'),
          ],
        ),
      ],
    );
  }
}

Color _coherenceColor(ColorScheme scheme, double coh) {
  if (coh >= 2.5) return scheme.primary;
  if (coh >= 1.0) return scheme.secondary;
  return Colors.orange.shade700;
}

String _coherenceLabel(double coh) {
  if (coh >= 2.5) return 'netta';
  if (coh >= 1.0) return 'discreta';
  return 'diffusa';
}

Widget _legendDot(ThemeData theme, Color c, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );

// =============================================================================
// 2) Impatto abitudini (RMSSD nei giorni con un fattore vs mattine pulite)
// =============================================================================

class _HabitImpactCard extends StatelessWidget {
  final List<Session> sessions;
  const _HabitImpactCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final res = DashboardStats.habitImpact(sessions);
    final maxAbs = res.impacts.isEmpty
        ? 1.0
        : res.impacts
            .map((i) => (i.deltaPct ?? 0).abs())
            .reduce(math.max)
            .clamp(1.0, double.infinity);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.nightlife_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Impatto abitudini',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Quanto certi fattori muovono la tua HRV mattutina, rispetto alle '
              'mattine senza alcun fattore segnalato.',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.3),
            ),
            const SizedBox(height: 14),
            if (!res.hasData)
              _CardPlaceholder(
                icon: Icons.local_bar_outlined,
                text: 'Servono almeno ${DashboardStats.minSamples} mattine '
                    '"pulite" e ${DashboardStats.minSamples} con un fattore '
                    '(alcol, sonno scarso, malattia…) segnalato al check-in.',
              )
            else ...[
              for (final imp in res.impacts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: _HabitBarRow(impact: imp, maxAbs: maxAbs),
                ),
              const SizedBox(height: 10),
              Text(
                'Baseline mattine pulite: '
                'RMSSD ${res.cleanBaseline!.toStringAsFixed(0)} ms '
                '(${res.cleanCount} mattine).',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HabitBarRow extends StatelessWidget {
  final HabitImpact impact;
  final double maxAbs;
  const _HabitBarRow({required this.impact, required this.maxAbs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final delta = impact.deltaPct ?? 0;
    // Calo HRV = arancio (cautela, non allarme); aumento = primary.
    final color = delta < 0 ? Colors.orange.shade700 : scheme.primary;
    final factor = (delta.abs() / maxAbs).clamp(0.03, 1.0);
    final sign = delta >= 0 ? '+' : '';

    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(impact.label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 18,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: factor,
                child: Container(color: color),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '$sign${delta.toStringAsFixed(0)}%',
            textAlign: TextAlign.end,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Helper condivisi della schermata
// =============================================================================

/// Placeholder compatto dentro una card quando i dati non bastano per un grafico.
class _CardPlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;
  const _CardPlaceholder({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: scheme.outline),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// Wrapper scrollabile per messaggi a tutto schermo (empty/errore), così il
/// pull-to-refresh resta utilizzabile anche senza dati.
class _ScrollableMessage extends StatelessWidget {
  final Widget child;
  const _ScrollableMessage({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insights, size: 64, color: scheme.outline),
        const SizedBox(height: 12),
        Text(
          'Nessuna sessione negli ultimi $kHrvDashboardWindowDays giorni.\n'
          'Registra qualche allenamento e check-in mattutino: qui vedrai '
          'come si evolve la tua HRV nel tempo.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
        ),
      ],
    );
  }
}
