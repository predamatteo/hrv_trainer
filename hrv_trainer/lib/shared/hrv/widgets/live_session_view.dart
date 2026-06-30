import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../breathing_pacer.dart';
import '../hrv_metrics.dart';
import '../rr_interval.dart';

/// Widget condivisi della "vista di misura" live, usati identici da Morning
/// check-in (respiro spontaneo) e Training (respiro guidato), così che le due
/// schermate combacino in grafici e dati a schermo. L'UNICA differenza voluta è
/// l'overlay del respiro guida nel chart (presente solo nel training) e l'orb
/// del pacer, che vive nella schermata di training.

/// Grande countdown mm:ss, elemento di tempo dominante della misura. [muted] lo
/// rende grigio (fase di assestamento morning / attesa del watch training);
/// altrimenti è colorato come la primary.
class BigCountdown extends StatelessWidget {
  final int secLeft;
  final bool muted;
  const BigCountdown({super.key, required this.secLeft, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mm = (secLeft ~/ 60).toString().padLeft(2, '0');
    final ss = (secLeft % 60).toString().padLeft(2, '0');
    return Text(
      '$mm:$ss',
      textAlign: TextAlign.center,
      style: theme.textTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w300,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: muted ? scheme.outline : scheme.primary,
      ),
    );
  }
}

/// Riga BPM corrente: cuore + valore grande + unità. Identica nelle due
/// schermate (il valore è l'ultimo battito ricevuto dal watch).
class LiveBpmRow extends StatelessWidget {
  final int? bpm;
  const LiveBpmRow({super.key, required this.bpm});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.favorite, color: scheme.primary, size: 20),
        const SizedBox(width: 6),
        Text(
          bpm == null ? '--' : '$bpm',
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
    );
  }
}

/// Tachogramma live condiviso. Una linea: l'intervallo RR (ms, = 60000/bpm) nel
/// tempo, la cui oscillazione È la visualizzazione del respiro (RSA). Usa la
/// STESSA grandezza, orientazione e stile (linea spezzata, auto-zoom in ms) del
/// tachogramma dello storico (`session_detail_screen.dart` `_TachogramCard`),
/// così che il grafico live sia la versione "che cresce in tempo reale" di
/// quello finale — niente più effetto capovolto fra le due viste (prima il live
/// era in bpm, l'inverso dell'RR). Se [pacer] è fornito (training a respiro
/// guidato) disegna anche la curva tratteggiata del respiro guida + una legenda
/// compatta; se è null (misura spontanea) mostra solo l'RR.
class LiveHrChart extends StatelessWidget {
  final List<HrTracePoint> trace;

  /// Origine dell'asse X (t=0). Se null usa il timestamp del primo punto.
  final DateTime? startReference;

  /// Respiro guida da sovrapporre. null = nessun overlay (misura spontanea).
  final BreathingPattern? pacer;

  const LiveHrChart({
    super.key,
    required this.trace,
    this.startReference,
    this.pacer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Sotto 2 punti minX==maxX e fl_chart asserta: placeholder "in attesa".
    final Widget content = trace.length < 2
        ? Center(
            child: Text(
              'In attesa del watch…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        : _buildChart(theme, scheme);

    // Senza overlay (morning) il grafico riempie tutto lo spazio del genitore.
    if (pacer == null) return content;
    // Con overlay (training) una legenda compatta sopra spiega le due linee.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Legend(scheme: scheme, textTheme: theme.textTheme),
        const SizedBox(height: 4),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildChart(ThemeData theme, ColorScheme scheme) {
    final start = startReference ?? trace.first.timestamp;
    // Asse Y in RR (ms): RR = 60000/bpm. Stessa grandezza del tachogramma dello
    // storico, così l'oscillazione punta nello stesso verso (in relax l'RR sale)
    // e le due viste combaciano. I battiti con bpm non valido vengono saltati.
    final spots = [
      for (final p in trace)
        if (p.bpm > 0)
          FlSpot(
            p.timestamp.difference(start).inMilliseconds / 1000.0,
            60000.0 / p.bpm,
          ),
    ];
    // Difensivo: tutti i battiti scartati (bpm non validi) → placeholder.
    if (spots.length < 2) {
      return Center(
        child: Text(
          'In attesa del watch…',
          style:
              theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final ys = spots.map((s) => s.y).toList();
    final dataMin = ys.reduce((a, b) => a < b ? a : b);
    final dataMax = ys.reduce((a, b) => a > b ? a : b);
    // Padding identico al tachogramma dello storico (range in ms).
    final pad = ((dataMax - dataMin) * 0.15).clamp(20, 100).toDouble();
    final yMin = (dataMin - pad).floorToDouble();
    final yMax = (dataMax + pad).ceilToDouble();

    final xMin = spots.first.x;
    final xMax = spots.last.x;
    final span = (xMax - xMin) <= 0 ? 1.0 : (xMax - xMin);

    final yRange = yMax - yMin;
    // interval in [1, range] per evitare assertion fl_chart (interval > range).
    final yInterval = (yRange / 4).clamp(1.0, yRange).toDouble();
    final xInterval = (span / 4).clamp(1.0, span).toDouble();

    final lines = <LineChartBarData>[];
    final p = pacer;
    if (p != null) {
      // Overlay respiro guida: campiona la curva del pacer e la mappa nel
      // range Y (in ms) così che RR e respiro siano visivamente confrontabili.
      // Identico all'overlay del tachogramma storico.
      final yMid = (yMin + yMax) / 2;
      final halfRange = (yMax - yMin) * 0.4;
      final breathSpots = <FlSpot>[];
      const n = 150;
      for (int i = 0; i <= n; i++) {
        final t = xMin + span * i / n;
        final amp = pacerAt(p, t).amplitude; // 0..1
        breathSpots.add(FlSpot(t, yMid + (amp - 0.5) * 2 * halfRange));
      }
      lines.add(LineChartBarData(
        spots: breathSpots,
        isCurved: false,
        barWidth: 1.2,
        color: scheme.secondary.withValues(alpha: 0.55),
        dotData: const FlDotData(show: false),
        dashArray: const [4, 4],
      ));
    }
    // Linea RR: spezzata (non curva) e sottile come nel tachogramma storico —
    // ogni punto è un intervallo reale, niente smoothing che inventerebbe valori.
    lines.add(LineChartBarData(
      spots: spots,
      isCurved: false,
      barWidth: 1.4,
      color: scheme.primary,
      dotData: const FlDotData(show: false),
    ));

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
              // 36 (non 30) per far stare i valori RR a 3-4 cifre (es. 1000 ms).
              reservedSize: 36,
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
        lineBarsData: lines,
      ),
    );
  }
}

/// Legenda compatta del chart con overlay: linea piena = RR, tratteggiata =
/// respiro guida. Mostrata solo dal training.
class _Legend extends StatelessWidget {
  final ColorScheme scheme;
  final TextTheme textTheme;
  const _Legend({required this.scheme, required this.textTheme});

  @override
  Widget build(BuildContext context) {
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

/// Riga di statistiche live durante la cattura: RMSSD (preview), ampiezza RSA e
/// campioni. È un'anteprima — il valore definitivo è nel riepilogo finale —
/// quindi styling più leggero (titleMedium). Condivisa identica fra morning e
/// training.
class LiveSessionStats extends StatelessWidget {
  final List<HrTracePoint> trace;
  final HrvMetrics? liveMetrics;
  final int sampleCount;

  const LiveSessionStats({
    super.key,
    required this.trace,
    required this.liveMetrics,
    required this.sampleCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = liveMetrics;

    // RMSSD live: '--' finché non c'è una preview valida (≥20 campioni).
    final rmssd =
        (live == null || live.rmssdMs == 0) ? '--' : live.rmssdMs.toStringAsFixed(1);

    final swing = _rsaSwing(trace);
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
            _stat(theme, 'Campioni', '$sampleCount', 'RR'),
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
