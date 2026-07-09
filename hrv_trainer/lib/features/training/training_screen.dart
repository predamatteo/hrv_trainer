import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/connect_iq/widgets/watch_readiness_gate.dart';
import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/hrv/rr_interval.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/hrv/widgets/live_session_view.dart';
import '../../shared/storage/session_repository.dart';
import '../../shared/ui/ui.dart';
import '../pacer/state/pacer_controller.dart';
import '../pacer/widgets/breathing_orb.dart';
import '../training_plan/widgets/post_session_report_sheet.dart';
import 'state/training_controller.dart';

class TrainingScreen extends ConsumerStatefulWidget {
  final SessionTag initialTag;

  /// Se valorizzati, la sessione è avviata DAL PIANO: pattern e durata sono
  /// pre-compilati dalla settimana corrente, la sessione viene marcata col
  /// piano e a fine sessione si apre il report soggettivo.
  final int? planId;
  final int? durationMin;
  final double? resonanceBpm;

  const TrainingScreen({
    super.key,
    this.initialTag = SessionTag.general,
    this.planId,
    this.durationMin,
    this.resonanceBpm,
  });

  @override
  ConsumerState<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends ConsumerState<TrainingScreen>
    with TickerProviderStateMixin {
  late BreathingPattern _pattern;
  late int _durationMin;
  late SessionTag _tag;

  /// Frequenza di risonanza personale dall'ultimo assessment (resp/min).
  double? _resonanceBpm;
  bool _patternTouched = false;

  /// Tensione catturata prima della sessione del piano (per il Δ calma del
  /// report). null se non è una sessione del piano o se l'utente l'ha saltata.
  int? _preTension;

  /// Mostra/nasconde il grafico RSA durante la sessione (toggle "graphic_eq").
  bool _showChart = true;

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    _applyTagDefaults();
    // Avvio dal piano: pre-compila respiro e durata dalla settimana corrente.
    // _patternTouched=true blocca l'override successivo di _loadResonance.
    if (widget.resonanceBpm != null) {
      _pattern = BreathingPattern.fromBpm(widget.resonanceBpm!);
      _patternTouched = true;
    }
    if (widget.durationMin != null) _durationMin = widget.durationMin!;
    _loadResonance();
  }

  Future<void> _loadResonance() async {
    final rf = await ref.read(sessionRepositoryProvider).latestResonanceBpm();
    if (!mounted || rf == null) return;
    setState(() {
      _resonanceBpm = rf;
      if (!_patternTouched) _applyTagDefaults();
    });
  }

  void _applyTagDefaults() {
    final base = _tag.defaultPattern;
    final rf = _resonanceBpm;
    _pattern = (rf != null && base.breathsPerMinute >= 6.0)
        ? BreathingPattern.fromBpm(rf)
        : base;
    _durationMin = _tag.defaultDurationMin;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TrainingState>(trainingControllerProvider, (prev, next) {
      final wasRegime =
          prev != null && prev.startedAt != null && !prev.preparing;
      final isRegime =
          next.running && next.startedAt != null && !next.preparing;
      if (!wasRegime && isRegime) {
        final offset = DateTime.now().difference(next.startedAt!);
        ref.read(pacerControllerProvider.notifier).start(startOffset: offset);
      }
      if (prev != null && prev.running && !next.running) {
        ref.read(pacerControllerProvider.notifier).pause();

        if (next.abortedNoData) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'L\'orologio non ha inviato dati. Spesso basta riavviare '
                'l\'orologio (memoria Connect IQ piena) o avvicinarlo e '
                'controllare il Bluetooth.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
          return;
        }

        final id = next.lastSessionId;
        if (id == null) {
          if (next.startedAt != null && !next.preparing) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Sessione interrotta: non salvata perché incompleta'),
                duration: Duration(seconds: 3),
              ),
            );
          }
          if (context.canPop()) context.pop();
          return;
        }

        _onSessionSaved(id);
      }
    });

    final running = ref.watch(trainingControllerProvider.select((s) => s.running));
    final waiting = ref.watch(trainingControllerProvider.select((s) => s.waitingForWatch));
    final preparing = ref.watch(trainingControllerProvider.select((s) => s.preparing));

    WakelockPlus.toggle(enable: running);

    if (!running) return _buildSetup(context);

    final pattern = ref.read(trainingControllerProvider).pattern;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onStopPressed();
      },
      child: Scaffold(
        body: SafeArea(
          child: waiting
              ? WatchWaitingView(
                  title: 'Connessione con l\'orologio…',
                  onCancel: () =>
                      ref.read(trainingControllerProvider.notifier).stop(save: false),
                )
              : preparing
                  ? _PrepView(
                      onCancel: () =>
                          ref.read(trainingControllerProvider.notifier).stop(save: false),
                    )
                  : _RunningView(
                      pattern: pattern,
                      showChart: _showChart,
                      onToggleChart: () => setState(() => _showChart = !_showChart),
                      onStop: _onStopPressed,
                    ),
        ),
      ),
    );
  }

  /// Sessione salvata: per le sessioni del piano mostra lo step di report
  /// soggettivo (allegato alla sessione), poi naviga al dettaglio. Per le altre
  /// sessioni conferma e basta.
  Future<void> _onSessionSaved(int id) async {
    if (widget.planId != null) {
      final report =
          await showPostSessionReportSheet(context, preTension: _preTension);
      if (report != null && !report.isEmpty) {
        await ref.read(sessionRepositoryProvider).updateSessionReport(id, report);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sessione completata e salvata'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    if (!mounted) return;
    context.pushReplacement('/history/session/$id');
  }

  Future<void> _onStopPressed() async {
    final confirm = await _confirmStop();
    if (confirm == true && mounted) {
      await ref.read(trainingControllerProvider.notifier).stop(save: false);
    }
  }

  Widget _buildSetup(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final bpm = _pattern.breathsPerMinute;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const HeaderBar(title: 'Nuova sessione', dense: false),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                children: [
                  const SectionHeader(title: 'Contesto'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in SessionTag.values)
                        _ContextChip(
                          icon: _tagIcon(tag),
                          label: tag.label,
                          selected: _tag == tag,
                          onTap: () => setState(() {
                            _tag = tag;
                            _patternTouched = false;
                            _applyTagDefaults();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  AppCard(
                    color: t.tonal,
                    border: Colors.transparent,
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_tagIcon(_tag), size: 18, color: t.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _tag.rationale,
                            style: text.bodySmall?.copyWith(color: t.dim, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('Imposta', style: text.titleMedium),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('pre-compilati dal contesto, regolabili',
                            style: text.labelSmall?.copyWith(color: t.faint)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SettingHeader(
                    label: 'Respiro',
                    value: '${bpm.toStringAsFixed(1)} resp/min',
                    hint: '≈ frequenza di risonanza',
                  ),
                  Slider(
                    min: 4.0,
                    max: 8.0,
                    divisions: 16,
                    value: bpm.clamp(4.0, 8.0),
                    label: bpm.toStringAsFixed(1),
                    onChanged: (v) => setState(() {
                      _patternTouched = true;
                      _pattern = BreathingPattern.fromBpm(v);
                    }),
                  ),
                  const SizedBox(height: 12),
                  _SettingHeader(label: 'Durata', value: '$_durationMin min'),
                  Slider(
                    min: 1,
                    max: 30,
                    divisions: 29,
                    value: _durationMin.toDouble(),
                    label: '$_durationMin min',
                    onChanged: (v) => setState(() => _durationMin = v.toInt()),
                  ),
                  if (_resonanceBpm == null) ...[
                    const SizedBox(height: 14),
                    AppCard(
                      onTap: () => context.push('/assessment'),
                      color: t.primaryTonal,
                      border: Colors.transparent,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(Icons.graphic_eq, size: 18, color: t.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Non hai ancora la tua frequenza di risonanza: fai '
                              'l\'Assessment per personalizzare il respiro.',
                              style: text.bodySmall?.copyWith(color: t.dim, height: 1.35),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: t.primary),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text('Avvia • $_durationMin min a ${bpm.toStringAsFixed(1)} resp/min'),
                      onPressed: _onStart,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Si sincronizza con l\'orologio all\'avvio',
                      style: text.labelSmall?.copyWith(color: t.faint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onStart() async {
    // Sessione del piano: cattura la tensione PRIMA di misurare (più valida che
    // a memoria). È facoltativa — se la salti, il report a fine sessione resta
    // utile, solo senza il Δ calma.
    if (widget.planId != null) {
      final pre = await showPreTensionSheet(context);
      if (!mounted) return;
      _preTension = pre;
    }
    final ready = await ensureWatchReady(context, ref);
    if (!ready || !mounted) return;
    // Aggancia l'orb allo STESSO periodo intero-ms inviato al watch in
    // START_SESSION: phone e orologio condividono il periodo esatto e l'orb
    // non scivola di fase ciclo dopo ciclo sui ritmi non interi (fromBpm).
    final pattern = _pattern.snappedToMs();
    ref.read(pacerPreferencesProvider.notifier).state =
        ref.read(pacerPreferencesProvider).copyWith(pattern: pattern);
    await ref.read(trainingControllerProvider.notifier).start(
          pattern,
          targetDurationSec: _durationMin * 60,
          tag: _tag,
          planId: widget.planId,
        );
  }

  IconData _tagIcon(SessionTag t) => switch (t) {
        SessionTag.morning => Icons.wb_sunny_outlined,
        SessionTag.preWorkout => Icons.fitness_center,
        SessionTag.postWorkout => Icons.ac_unit,
        SessionTag.sleep => Icons.bedtime_outlined,
        SessionTag.stress => Icons.bolt_outlined,
        SessionTag.recovery => Icons.spa_outlined,
        SessionTag.general => Icons.tune,
      };

  Future<bool?> _confirmStop() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Terminare la sessione?'),
          content: const Text(
            'La sessione non è ancora completa: terminandola ora NON verrà '
            'salvata nello storico. Lasciala finire per registrarla.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Continua'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: ctx.tokens.alert,
                backgroundColor: ctx.tokens.alertTonal,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Termina senza salvare'),
            ),
          ],
        ),
      );
}

/// Vista di sessione a regime: header + orb + countdown/cicli + onda RSA +
/// coerenza + controlli. Layout del mockup "Sessione biofeedback".
class _RunningView extends StatelessWidget {
  final BreathingPattern pattern;
  final bool showChart;
  final VoidCallback onToggleChart;
  final Future<void> Function() onStop;

  const _RunningView({
    required this.pattern,
    required this.showChart,
    required this.onToggleChart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        children: [
          // Header: indietro (= stop con conferma) + titolo + pill FC.
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                color: t.dim,
                onPressed: onStop,
              ),
              Expanded(
                child: Column(
                  children: [
                    Text('Risonanza', style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      '${pattern.breathsPerMinute.toStringAsFixed(1).replaceAll('.', ',')} respiri / min',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.faint),
                    ),
                  ],
                ),
              ),
              const _HrPill(),
            ],
          ),
          const _TrainingConnectionBanner(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final orbSize = (constraints.maxHeight * 0.24).clamp(110.0, 170.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Center(child: _OrbView(size: orbSize)),
                    const SizedBox(height: 12),
                    const _RunningCountdown(),
                    const SizedBox(height: 14),
                    if (showChart)
                      Expanded(child: _RsaCard())
                    else
                      const Spacer(),
                    const SizedBox(height: 12),
                    const _CoherenceCard(),
                    const _LiveStatsLine(),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleControlButton(
                icon: showChart ? Icons.graphic_eq : Icons.show_chart,
                tooltip: showChart ? 'Nascondi grafico' : 'Mostra grafico',
                onTap: onToggleChart,
              ),
              const SizedBox(width: 18),
              CircleControlButton(
                icon: Icons.stop,
                primary: true,
                size: 70,
                tooltip: 'Termina',
                onTap: onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pill della frequenza cardiaca corrente (alert-tonal + cuore). Rebuilda ~1 Hz.
class _HrPill extends ConsumerWidget {
  const _HrPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bpm = ref.watch(
      trainingControllerProvider.select((s) => s.hrTrace.isEmpty ? null : s.hrTrace.last.bpm),
    );
    return Pill(
      tone: PillTone.alert,
      icon: Icons.favorite,
      label: bpm == null ? '--' : '$bpm',
    );
  }
}

/// Countdown grande + progresso a cicli respiratori. Ticka ogni secondo.
class _RunningCountdown extends ConsumerStatefulWidget {
  const _RunningCountdown();

  @override
  ConsumerState<_RunningCountdown> createState() => _RunningCountdownState();
}

class _RunningCountdownState extends ConsumerState<_RunningCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final st = ref.read(trainingControllerProvider);
    final period = st.pattern.periodSec;
    final totalCycles = period > 0 ? (st.targetDurationSec / period).round() : 0;

    if (st.startedAt == null) {
      return Column(
        children: [
          BigCountdown(secLeft: st.targetDurationSec, muted: true),
          const SizedBox(height: 5),
          Text('preparazione…', style: text.labelMedium?.copyWith(color: t.faint)),
        ],
      );
    }

    final remaining = Duration(seconds: st.targetDurationSec) - st.elapsed;
    final remSec = remaining.isNegative ? 0 : remaining.inSeconds;
    final elapsedSec = st.elapsed.inSeconds.clamp(0, st.targetDurationSec);
    final current = period > 0 ? (elapsedSec / period).floor() + 1 : 0;
    final curClamped = totalCycles > 0 ? current.clamp(1, totalCycles) : 0;

    return Column(
      children: [
        BigCountdown(secLeft: remSec),
        const SizedBox(height: 5),
        Text(
          totalCycles > 0 ? 'rimanenti · $curClamped di $totalCycles cicli' : 'rimanenti',
          style: text.labelMedium?.copyWith(color: t.faint),
        ),
      ],
    );
  }
}

/// Card dell'onda RSA: battito live (bpm) + respiro guida.
class _RsaCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final st = ref.watch(trainingControllerProvider);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Battito · onda RSA',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: t.dim),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LiveHrChart(
              trace: st.hrTrace,
              startReference: st.startedAt,
              pacer: st.pattern,
            ),
          ),
        ],
      ),
    );
  }
}

/// Card della coerenza cardiaca: ratio dal vivo + barra gradiente.
class _CoherenceCard extends ConsumerWidget {
  const _CoherenceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final coh = ref.watch(trainingControllerProvider.select((s) => s.liveMetrics.coherenceRatio));
    final hasValue = coh > 0;
    final (label, color) = coh >= 2
        ? ('alta', t.good)
        : coh >= 1
            ? ('media', t.accent)
            : ('bassa', t.dim);

    return AppCard(
      color: t.tonal,
      border: Colors.transparent,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Coerenza cardiaca', style: text.bodyMedium?.copyWith(color: t.dim)),
                    Text('sincronia cuore-respiro',
                        style: text.labelSmall?.copyWith(color: t.faint)),
                  ],
                ),
              ),
              if (hasValue) ...[
                Text(coh.toStringAsFixed(1).replaceAll('.', ','),
                    style: text.headlineSmall),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(label, style: text.labelLarge?.copyWith(color: color)),
                ),
              ] else
                Text('--', style: text.headlineSmall?.copyWith(color: t.faint)),
            ],
          ),
          const SizedBox(height: 12),
          CoherenceBar(value: hasValue ? coh : 0, max: 3),
        ],
      ),
    );
  }
}

/// Riga discreta delle statistiche live (anteprima): RMSSD · ampiezza RSA ·
/// campioni RR. Volutamente minimale (una riga attenuata) sotto la coerenza,
/// così il dato c'è ma non ruba la scena all'orb/coerenza.
class _LiveStatsLine extends ConsumerWidget {
  const _LiveStatsLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final st = ref.watch(trainingControllerProvider);
    final rmssd = st.liveMetrics.rmssdMs;
    final rmssdStr = rmssd == 0 ? '--' : rmssd.toStringAsFixed(0);
    final swing = _rsaSwing(st.hrTrace);
    final rsaStr = swing == null ? '--' : '$swing';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        'RMSSD $rmssdStr ms · RSA Δ $rsaStr bpm · ${st.samples.length} RR',
        textAlign: TextAlign.center,
        style: text.labelSmall?.copyWith(color: t.faint),
      ),
    );
  }

  /// Ampiezza RSA: max−min dei bpm negli ultimi 30s. Stessa logica di
  /// LiveSessionStats; null se meno di 2 punti nella finestra.
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
}

/// Chip selezionabile del contesto (setup). Selezionato = primary-tonal.
class _ContextChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ContextChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final fg = selected ? t.primary : t.dim;
    return Material(
      color: selected ? t.primaryTonal : t.tonal,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 7),
              Text(label,
                  style: text.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingHeader extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  const _SettingHeader({required this.label, required this.value, this.hint});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: text.titleSmall)),
            Text(value, style: text.titleMedium?.copyWith(color: t.primary, fontWeight: FontWeight.w700)),
          ],
        ),
        if (hint != null)
          Text(hint!, style: text.labelSmall?.copyWith(color: t.faint)),
      ],
    );
  }
}

/// Vista di PREPARAZIONE coordinata: connessi, respiro guida non ancora partito.
class _PrepView extends ConsumerStatefulWidget {
  final VoidCallback onCancel;
  const _PrepView({required this.onCancel});

  @override
  ConsumerState<_PrepView> createState() => _PrepViewState();
}

class _PrepViewState extends ConsumerState<_PrepView> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final secLeft = ref.read(trainingControllerProvider).prepSecLeft;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.self_improvement, size: 48, color: t.primary),
            const SizedBox(height: 20),
            Text('Preparati', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              secLeft > 0 ? 'Si parte tra $secLeft s' : 'Si parte…',
              style: text.displaySmall?.copyWith(color: t.primary),
            ),
            const SizedBox(height: 12),
            Text(
              'Connesso. Mettiti comodo e tieni il polso fermo: orologio e '
              'telefono partono insieme a fine preparazione.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: t.dim, height: 1.35),
            ),
            const SizedBox(height: 28),
            OutlinedButton(onPressed: widget.onCancel, child: const Text('Annulla')),
          ],
        ),
      ),
    );
  }
}

/// Banner non bloccante quando il flusso di battiti si interrompe a metà.
class _TrainingConnectionBanner extends ConsumerWidget {
  const _TrainingConnectionBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lost = ref.watch(trainingControllerProvider.select((s) => s.connectionLost));
    if (!lost) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: WatchConnectionLostBanner(),
    );
  }
}

/// Orb del respiro: ascolta il pacer (20 Hz), NON il TrainingState.
class _OrbView extends ConsumerWidget {
  final double size;
  const _OrbView({this.size = 160});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(pacerControllerProvider);
    final t = context.tokens;
    return BreathingOrb(
      amplitude: tick.amplitude,
      phase: tick.phase,
      phaseProgress: tick.progress,
      inhaleColor: t.inhale,
      exhaleColor: t.exhale,
      size: size,
    );
  }
}
