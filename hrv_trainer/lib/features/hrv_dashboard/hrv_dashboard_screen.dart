import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/hrv/dashboard_stats.dart';
import '../../shared/hrv/hrv_trend.dart';
import '../../shared/hrv/readiness.dart' show CvStability;
import '../../shared/hrv/session_models.dart';
import '../../shared/hrv/widgets/hrv_histogram.dart';
import '../../shared/hrv/widgets/ln_rmssd_trend_card.dart';
import '../../shared/hrv/widgets/weekly_lnrmssd_card.dart';
import '../../shared/ui/ui.dart';
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
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final sessionsAsync = ref.watch(hrvDashboardSessionsProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(hrvDashboardSessionsProvider);
            ref.invalidate(morningReadingsProvider);
            ref.invalidate(hrvGeneralStatusProvider);
            await ref.read(hrvDashboardSessionsProvider.future);
          },
          child: sessionsAsync.when(
            loading: () => const _ScrollableMessage(
              child: CircularProgressIndicator(),
            ),
            error: (e, _) => _ScrollableMessage(
              child: Text(
                'Errore nel caricamento: $e',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: t.dim),
              ),
            ),
            data: (sessions) => _Body(sessions: sessions),
          ),
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
    final text = Theme.of(context).textTheme;

    if (sessions.isEmpty) {
      return const _ScrollableMessage(
        child: EmptyState(
          icon: Icons.insights,
          message:
              'Nessuna sessione negli ultimi $kHrvDashboardWindowDays giorni.\n'
              'Registra qualche allenamento e check-in mattutino: qui vedrai '
              'come si evolve la tua HRV nel tempo.',
        ),
      );
    }

    // Grafici cronici: ordine cronologico (vecchie → recenti); il provider
    // restituisce newest-first.
    final chrono = sessions.reversed.toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      children: [
        Row(
          children: [
            const _BackButton(),
            const SizedBox(width: 4),
            Expanded(child: Text('Andamento HRV', style: text.headlineSmall)),
          ],
        ),
        const SizedBox(height: 14),
        // Spiegazione in lingua-utente: la vista cronica è dove un non-esperto
        // si perde. Frame: autoconfronto, tendenza > valore del giorno.
        const Callout(
          text: 'Qui guardi la tua tendenza nel tempo, non il valore di oggi. '
              'Conta il confronto con il tuo solito: una linea che sale piano, '
              'settimana dopo settimana, è il progresso vero.',
        ),
        const SizedBox(height: 18),
        const _GeneralStatusCard(),
        const SizedBox(height: 20),

        // Trend cronico in lnRMSSD: spostato qui dallo Storico, che non mostra
        // più analisi cross-sessione. Serve un minimo di 3 punti per leggerlo.
        if (chrono.length >= 3) ...[
          const SectionHeader(title: 'Trend lnRMSSD'),
          LnRmssdTrendCard(sessions: chrono),
          const SizedBox(height: 20),
          // Media settimanale: smussa il rumore giornaliero (si auto-nasconde
          // con meno di 2 settimane).
          WeeklyLnRmssdCard(sessions: chrono),
          const SizedBox(height: 20),
        ],

        // Distribuzione dell'HRV score: anch'essa migrata dallo Storico.
        const SectionHeader(title: 'Distribuzione'),
        HrvHistogram(sessions: chrono),
        const SizedBox(height: 20),

        const SectionHeader(title: 'Biofeedback'),
        _CoherenceTrendCard(sessions: sessions),
        const SizedBox(height: 12),
        _HabitImpactCard(sessions: sessions),
      ],
    );
  }
}

/// Pulsante "indietro" tondo coerente col design system (la schermata è
/// raggiunta via push dalla home).
class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.tonal,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.pop(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.arrow_back, size: 20, color: t.dim),
        ),
      ),
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
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final async = ref.watch(hrvGeneralStatusProvider);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quadro cronico', style: text.titleMedium),
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
              style: text.bodyMedium?.copyWith(color: t.dim),
            ),
            data: (s) => _GeneralStatusBody(status: s),
          ),
        ],
      ),
    );
  }
}

class _GeneralStatusBody extends StatelessWidget {
  final HrvGeneralStatus status;
  const _GeneralStatusBody({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    if (!status.hasLevel) {
      return Text(
        'L\'andamento comparirà dopo qualche lettura morning.',
        style: text.bodyMedium?.copyWith(color: t.dim),
      );
    }

    final (dirIcon, dirColor, dirLabel) = _direction(t, status.direction);
    final pct = status.deltaPct;
    final pctStr =
        pct == null ? '' : '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%';
    final span = status.spanWeeks == null ? '' : ' · ~${status.spanWeeks} sett.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.favorite_outline, size: 18, color: t.primary),
            const SizedBox(width: 8),
            Text('HRV tipico', style: text.bodyMedium),
            const SizedBox(width: 8),
            Text(
              'RMSSD ${status.levelRmssd!.toStringAsFixed(0)} · '
              'score ${status.levelScore!.toStringAsFixed(0)}',
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (status.direction == HrvTrendDirection.unknown)
          Row(
            children: [
              Icon(Icons.timeline, size: 18, color: t.dim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Andamento disponibile dopo più letture morning.',
                  style: text.bodySmall?.copyWith(color: t.dim),
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
                style: text.bodyMedium
                    ?.copyWith(color: dirColor, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$pctStr$span',
                    style: text.bodySmall?.copyWith(color: t.dim)),
              ),
            ],
          ),
        if (status.cvPct != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.show_chart, size: 16, color: _cvColor(t, status.cvStability)),
              const SizedBox(width: 8),
              Text(
                'Stabilità: ${_cvLabel(status.cvStability)} '
                '(CV ${_comma(status.cvPct!, 1)}%)',
                style: text.bodySmall?.copyWith(color: _cvColor(t, status.cvStability)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

(IconData, Color, String) _direction(AppTokens t, HrvTrendDirection d) {
  return switch (d) {
    // In calo = warn (cautela, non allarme).
    HrvTrendDirection.improving => (Icons.trending_up, t.good, 'In miglioramento'),
    HrvTrendDirection.declining => (Icons.trending_down, t.warn, 'In calo'),
    HrvTrendDirection.stable => (Icons.trending_flat, t.dim, 'Stabile'),
    HrvTrendDirection.unknown => (Icons.timeline, t.dim, '—'),
  };
}

Color _cvColor(AppTokens t, CvStability s) => switch (s) {
      CvStability.stable => t.good,
      CvStability.moderate => t.warn,
      CvStability.unstable => t.alert,
      CvStability.unknown => t.dim,
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
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final pts = DashboardStats.coherenceTrend(sessions);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights, size: 20, color: t.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Coerenza nel training', style: text.titleMedium),
              ),
              if (pts.isNotEmpty)
                Text('${pts.length} sessioni',
                    style: text.labelSmall?.copyWith(color: t.faint)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Quanto l\'oscillazione cardiaca si concentra in un picco netto '
            '(respiro in risonanza). Più alta = meglio.',
            style: text.labelSmall?.copyWith(color: t.dim, height: 1.3),
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
    );
  }
}

class _CoherenceChartArea extends StatelessWidget {
  final List<CoherenceTrendPoint> points;
  const _CoherenceChartArea({required this.points});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
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
                color: t.grid,
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
                    _comma(v, 1),
                    style: text.labelSmall?.copyWith(color: t.faint),
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
                        style: text.labelSmall?.copyWith(color: t.faint),
                      ),
                    );
                  },
                ),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border(
                left: BorderSide(color: t.line),
                bottom: BorderSide(color: t.line),
              ),
            ),
            lineBarsData: [
              // Media mobile (linea di tendenza, tratteggiata).
              LineChartBarData(
                spots: rollSpots,
                color: t.accent,
                barWidth: 2,
                isCurved: true,
                dashArray: const [5, 4],
                dotData: const FlDotData(show: false),
              ),
              // Coerenza per sessione, dot colorato per livello.
              LineChartBarData(
                spots: lineSpots,
                color: t.primary.withValues(alpha: 0.5),
                barWidth: 2,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, _, _, _) {
                    final i = spot.x.toInt();
                    final coh =
                        (i >= 0 && i < values.length) ? values[i] : 0.0;
                    return FlDotCirclePainter(
                      radius: 3.5,
                      color: _coherenceColor(t, coh),
                      strokeWidth: 1.2,
                      strokeColor: t.surface,
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
                    'coerenza ${_comma(p.coherence, 1)} '
                    '(${_coherenceLabel(p.coherence)})\n'
                    '${_comma(p.bpm, 1)} bpm',
                    TextStyle(color: t.onPrimary),
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
            Text('Media ${_comma(avg, 1)}',
                style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Icon(
              trendPct >= 3
                  ? Icons.trending_up
                  : (trendPct <= -3 ? Icons.trending_down : Icons.trending_flat),
              size: 16,
              color: trendPct >= 3
                  ? t.good
                  : (trendPct <= -3 ? t.warn : t.dim),
            ),
            const SizedBox(width: 4),
            Text(
              '${trendPct >= 0 ? '+' : ''}${trendPct.toStringAsFixed(0)}% nel periodo',
              style: text.labelSmall?.copyWith(color: t.dim),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _legendDot(context, t.primary, 'netta (≥2.5)'),
            _legendDot(context, t.accent, 'discreta (1-2.5)'),
            _legendDot(context, t.warn, 'diffusa (<1)'),
          ],
        ),
      ],
    );
  }
}

Color _coherenceColor(AppTokens t, double coh) {
  if (coh >= 2.5) return t.primary;
  if (coh >= 1.0) return t.accent;
  return t.warn;
}

String _coherenceLabel(double coh) {
  if (coh >= 2.5) return 'netta';
  if (coh >= 1.0) return 'discreta';
  return 'diffusa';
}

Widget _legendDot(BuildContext context, Color c, String label) {
  final t = context.tokens;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Dot(c, size: 10),
      const SizedBox(width: 5),
      Text(label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: t.dim)),
    ],
  );
}

// =============================================================================
// 2) Impatto abitudini (RMSSD nei giorni con un fattore vs mattine pulite)
// =============================================================================

class _HabitImpactCard extends StatelessWidget {
  final List<Session> sessions;
  const _HabitImpactCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final res = DashboardStats.habitImpact(sessions);
    final maxAbs = res.impacts.isEmpty
        ? 1.0
        : res.impacts
            .map((i) => (i.deltaPct ?? 0).abs())
            .reduce(math.max)
            .clamp(1.0, double.infinity);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.nightlife_outlined, size: 20, color: t.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Impatto abitudini', style: text.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Quanto certi fattori muovono la tua HRV mattutina, rispetto alle '
            'mattine senza alcun fattore segnalato.',
            style: text.labelSmall?.copyWith(color: t.dim, height: 1.3),
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
              style: text.labelSmall?.copyWith(color: t.dim),
            ),
          ],
        ],
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
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final delta = impact.deltaPct ?? 0;
    // Calo HRV = warn (cautela, non allarme); aumento = primary.
    final color = delta < 0 ? t.warn : t.primary;
    final factor = (delta.abs() / maxAbs).clamp(0.03, 1.0);
    final sign = delta >= 0 ? '+' : '';

    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(impact.label,
              overflow: TextOverflow.ellipsis, style: text.labelMedium),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 18,
              color: t.tonal2,
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
            style: text.labelMedium
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

String _comma(double v, int digits) =>
    v.toStringAsFixed(digits).replaceAll('.', ',');

/// Placeholder compatto dentro una card quando i dati non bastano per un grafico.
class _CardPlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;
  const _CardPlaceholder({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: t.tonal,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: t.faint),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: t.dim, height: 1.35),
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

