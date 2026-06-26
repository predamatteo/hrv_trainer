import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_tokens.dart';
import '../../shared/connect_iq/widgets/watch_readiness_gate.dart';
import '../../shared/hrv/hrv_metrics.dart';
import '../../shared/hrv/morning_reading.dart';
import '../../shared/hrv/readiness.dart';
import '../../shared/hrv/widgets/live_session_view.dart';
import '../../shared/ui/ui.dart';
import 'state/morning_checkin_controller.dart';
import 'state/readiness_providers.dart';

/// Flusso di misura mattutina a respiro SPONTANEO (NON guidato). La readiness
/// baseline richiede una misura a riposo senza pacing.
///
/// Flusso: idle (intro) → measuring (cattura) → review (step contesto separato)
/// → saved (dashboard di prontezza, mockup "Check-in mattutino").
class MorningCheckInScreen extends ConsumerStatefulWidget {
  const MorningCheckInScreen({super.key});

  @override
  ConsumerState<MorningCheckInScreen> createState() => _MorningCheckInScreenState();
}

class _MorningCheckInScreenState extends ConsumerState<MorningCheckInScreen> {
  // Stato locale del form di contesto (step review).
  SleepQuality _sleep = SleepQuality.unknown;
  bool _alcohol = false;
  bool _illness = false;
  bool _stressed = false;
  bool _soreness = false;
  int? _fatigue;
  bool _saving = false;

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(morningCheckInControllerProvider);

    ref.listen<MorningCheckInState>(morningCheckInControllerProvider, (prev, next) {
      if (next.abortedNoData && (prev == null || !prev.abortedNoData)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nessun dato dall\'orologio: misura annullata. '
              'Controlla la connessione e riprova.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    });

    WakelockPlus.toggle(enable: state.phase == CheckInPhase.measuring);

    return switch (state.phase) {
      CheckInPhase.idle => _buildIdle(context, state),
      CheckInPhase.measuring => _buildMeasuring(context, state),
      CheckInPhase.review => _buildReview(context, state),
      CheckInPhase.saved => _buildDashboard(context, state),
    };
  }

  // ---------------------------------------------------------------------------
  // idle: intro + postura/durata + avvio.
  // ---------------------------------------------------------------------------
  Widget _buildIdle(BuildContext context, MorningCheckInState state) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const HeaderBar(title: 'Check-in mattutino', subtitle: 'lettura di prontezza a riposo'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                children: [
                  AppCard(
                    color: t.tonal,
                    border: Colors.transparent,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.self_improvement, color: t.primary, size: 26),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Misura a riposo, respiro SPONTANEO (non guidato). '
                            'Stai fermo, seduto, subito dopo il risveglio.',
                            style: text.bodyMedium?.copyWith(height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  const SectionHeader(title: 'Postura'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in Posture.values)
                        _SelChip(
                          label: p.label,
                          selected: state.posture == p,
                          onTap: () =>
                              ref.read(morningCheckInControllerProvider.notifier).setPosture(p),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const SectionHeader(title: 'Durata'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in const [MorningProtocol.seated60, MorningProtocol.seated180])
                        _SelChip(
                          label: p.label,
                          selected: state.protocol == p,
                          onTap: () =>
                              ref.read(morningCheckInControllerProvider.notifier).setProtocol(p),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${MorningCheckInController.settleSec}s di assestamento + '
                    '${state.protocol.captureSec}s di cattura.',
                    style: text.bodySmall?.copyWith(color: t.faint),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Avvia misura'),
                  onPressed: () async {
                    final ready = await ensureWatchReady(context, ref);
                    if (!ready || !context.mounted) return;
                    await ref.read(morningCheckInControllerProvider.notifier).start();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // measuring: vista calma a tutto schermo. Back bloccato (conferma annulla).
  // ---------------------------------------------------------------------------
  Widget _buildMeasuring(BuildContext context, MorningCheckInState state) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final settling = state.settling;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _cancelMeasure(context);
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              HeaderBar(
                showBack: false,
                title: state.waitingForWatch
                    ? 'Avvio…'
                    : settling
                        ? 'Assestamento'
                        : 'Misurazione',
                centerTitle: true,
                dense: true,
                trailing: TextButton(
                  onPressed: () => _cancelMeasure(context),
                  child: const Text('Annulla'),
                ),
              ),
              Expanded(
                child: state.waitingForWatch
                    ? WatchWaitingView(onCancel: () => _cancelMeasure(context))
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (state.connectionLost) ...[
                              const WatchConnectionLostBanner(),
                              const SizedBox(height: 8),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              settling ? 'Assestamento… stai fermo' : 'Respira normalmente, stai fermo',
                              textAlign: TextAlign.center,
                              style: text.titleMedium?.copyWith(color: t.dim),
                            ),
                            const SizedBox(height: 20),
                            BigCountdown(secLeft: state.secLeft, muted: settling),
                            const SizedBox(height: 16),
                            LiveBpmRow(bpm: state.currentBpm),
                            const SizedBox(height: 16),
                            Expanded(
                              child: AppCard(
                                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                                child: LiveHrChart(trace: state.hrTrace),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'La linea segue il cuore: sale quando inspiri, scende quando '
                              'espiri (RSA). Respira come viene, non seguirla.',
                              textAlign: TextAlign.center,
                              style: text.bodySmall?.copyWith(color: t.faint, height: 1.35),
                            ),
                            const SizedBox(height: 16),
                            LiveSessionStats(
                              trace: state.hrTrace,
                              liveMetrics: state.liveMetrics,
                              sampleCount: state.sampleCount,
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cancelMeasure(BuildContext context) async {
    final confirm = await _confirmCancel();
    if (confirm == true && context.mounted) {
      await ref.read(morningCheckInControllerProvider.notifier).cancel();
      if (context.mounted && context.canPop()) context.pop();
    }
  }

  // ---------------------------------------------------------------------------
  // review: STEP CONTESTO separato (sonno/fattori/fatica) + salvataggio.
  // ---------------------------------------------------------------------------
  Widget _buildReview(BuildContext context, MorningCheckInState state) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final m = state.metrics;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const HeaderBar(
              showBack: false,
              title: 'Com\'è andata la notte?',
              subtitle: 'opzionale, ma aiuta a leggere i tuoi trend',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                children: [
                  if (m != null)
                    Row(
                      children: [
                        Expanded(child: StatTile(value: m.rmssdMs == 0 ? '--' : m.rmssdMs.toStringAsFixed(0), label: 'RMSSD ms')),
                        const SizedBox(width: 10),
                        Expanded(child: StatTile(value: m.meanHrBpm == 0 ? '--' : m.meanHrBpm.toStringAsFixed(0), label: 'FC bpm')),
                        const SizedBox(width: 10),
                        Expanded(child: StatTile(value: '${m.samples}', label: 'campioni')),
                      ],
                    ),
                  const SizedBox(height: 20),
                  const SectionHeader(title: 'Qualità del sonno'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in SleepQuality.values.where((s) => s != SleepQuality.unknown))
                        _SelChip(
                          label: s.label,
                          selected: _sleep == s,
                          onTap: () => setState(() => _sleep = _sleep == s ? SleepQuality.unknown : s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const SectionHeader(title: 'Fattori'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SelChip(label: 'Alcol', selected: _alcohol, onTap: () => setState(() => _alcohol = !_alcohol)),
                      _SelChip(label: 'Malato', selected: _illness, onTap: () => setState(() => _illness = !_illness)),
                      _SelChip(label: 'Stressato', selected: _stressed, onTap: () => setState(() => _stressed = !_stressed)),
                      _SelChip(label: 'Indolenzito', selected: _soreness, onTap: () => setState(() => _soreness = !_soreness)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: Text('Affaticamento', style: text.labelLarge?.copyWith(color: t.dim))),
                      Text(_fatigue == null ? '—' : '$_fatigue / 5',
                          style: text.labelLarge?.copyWith(color: t.primary)),
                    ],
                  ),
                  Slider(
                    min: 1,
                    max: 5,
                    divisions: 4,
                    value: (_fatigue ?? 3).toDouble(),
                    label: '${_fatigue ?? 3}',
                    onChanged: (v) => setState(() => _fatigue = v.toInt()),
                  ),
                  Text('1 = fresco · 5 = sfinito', style: text.bodySmall?.copyWith(color: t.faint)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Salva e vedi prontezza'),
                  onPressed: _saving ? null : () => _save(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // saved: DASHBOARD di prontezza (mockup "Check-in mattutino").
  // ---------------------------------------------------------------------------
  Widget _buildDashboard(BuildContext context, MorningCheckInState state) {
    final text = Theme.of(context).textTheme;
    final m = state.metrics;
    final readinessAsync = ref.watch(readinessSectionProvider);

    final durationMin = ((MorningCheckInController.settleSec + state.protocol.captureSec) / 60).ceil();
    final timeStr = DateFormat('HH:mm').format(DateTime.now());

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            HeaderBar(
              showBack: false,
              title: 'Check-in mattutino',
              subtitle: 'lettura di $durationMin min · ore $timeStr',
            ),
            Expanded(
              child: readinessAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Lettura salvata, ma non è stato possibile calcolare la prontezza ora.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium,
                    ),
                  ),
                ),
                data: (r) => ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  children: [
                    _ReadinessHeroCard(readiness: r, metrics: m),
                    const SizedBox(height: 16),
                    if (m != null) _MetricsCard(metrics: m),
                    if (m != null) ...[
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Pill(
                          icon: Icons.verified_outlined,
                          label: 'Qualità del segnale: ${m.confidence.label.toLowerCase()} · '
                              '${(100 - m.percentArtifactual).clamp(0, 100).round()}% battiti validi',
                        ),
                      ),
                    ],
                  ],
                ),
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
                      icon: const Icon(Icons.monitor_heart),
                      label: Text(_ctaLabel(readinessAsync.valueOrNull)),
                      onPressed: () => context.pushReplacement(_ctaRoute(readinessAsync.valueOrNull)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/'),
                    child: const Text('Salta per oggi'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ctaLabel(Readiness? r) => switch (r?.advice) {
        TrainingAdvice.rest => 'Sessione di recupero',
        TrainingAdvice.trainEasy => 'Sessione leggera consigliata',
        _ => 'Avvia la sessione di risonanza',
      };

  String _ctaRoute(Readiness? r) => switch (r?.advice) {
        TrainingAdvice.rest || TrainingAdvice.trainEasy => '/training?tag=recovery',
        _ => '/training',
      };

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------
  Future<void> _save(BuildContext context) async {
    setState(() => _saving = true);
    final ctx = MorningContext(
      sleep: _sleep,
      alcohol: _alcohol,
      illness: _illness,
      stressed: _stressed,
      soreness: _soreness,
      fatigue: _fatigue,
    );
    final id = await ref.read(morningCheckInControllerProvider.notifier).save(ctx);
    if (!context.mounted) return;
    if (id == null) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossibile salvare: dati insufficienti')),
      );
      return;
    }
    // Successo: il controller passa a phase.saved → build mostra la dashboard.
    setState(() => _saving = false);
  }

  Future<bool?> _confirmCancel() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Annullare la misura?'),
          content: const Text('I dati raccolti finora verranno scartati.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Continua')),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: ctx.tokens.alert,
                backgroundColor: ctx.tokens.alertTonal,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Annulla misura'),
            ),
          ],
        ),
      );
}

/// Card eroe della prontezza: anello + stato + z-score + paragrafo, su sfondo
/// tonale della banda.
class _ReadinessHeroCard extends StatelessWidget {
  final Readiness readiness;
  final HrvMetrics? metrics;
  const _ReadinessHeroCard({required this.readiness, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final r = readiness;

    final (bg, color, word, title) = switch (r.band) {
      ReadinessBand.green => (t.goodTonal, t.good, 'PRONTO', 'Verde · ben recuperato'),
      ReadinessBand.yellow => (t.warnTonal, t.warn, 'ATTENZIONE', 'Giallo · sotto la norma'),
      ReadinessBand.red => (t.alertTonal, t.alert, 'RECUPERO', 'Rosso · priorità recupero'),
      ReadinessBand.unknown => (t.tonal, t.primary, '—', 'Baseline in costruzione'),
    };

    final score = metrics == null ? 0.0 : HrvMetrics.scoreFromRmssd(metrics!.rmssdMs);

    return AppCard(
      color: bg,
      border: Colors.transparent,
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          ReadinessRing(
            progress: score / 100,
            color: color,
            trackColor: color.withValues(alpha: 0.22),
            size: 128,
            strokeWidth: 9,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${score.round()}', style: text.displaySmall?.copyWith(height: 1, color: t.text)),
                const SizedBox(height: 2),
                Text(word, style: text.labelMedium?.copyWith(color: color, letterSpacing: 0.6)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(title, style: text.titleLarge, textAlign: TextAlign.center),
          if (r.zScore != null) ...[
            const SizedBox(height: 12),
            Pill(
              child: RichText(
                text: TextSpan(
                  style: text.labelLarge?.copyWith(color: t.dim),
                  children: [
                    TextSpan(
                      text: '${r.zScore! >= 0 ? '+' : ''}${r.zScore!.toStringAsFixed(1).replaceAll('.', ',')} SD ',
                      style: TextStyle(color: t.text, fontWeight: FontWeight.w700),
                    ),
                    const TextSpan(text: 'rispetto a te'),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            r.message.isEmpty ? r.headline : r.message,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: t.dim, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// Card delle metriche: lnRMSSD / RMSSD / FC a riposo.
class _MetricsCard extends StatelessWidget {
  final HrvMetrics metrics;
  const _MetricsCard({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final lnRmssd = m.rmssdMs > 0 ? math.log(m.rmssdMs).toStringAsFixed(2).replaceAll('.', ',') : '--';
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          MetricRow(label: 'lnRMSSD', sublabel: 'tono parasimpatico', value: lnRmssd, unit: 'ln ms'),
          MetricRow(
            label: 'RMSSD',
            sublabel: 'variabilità battito-battito',
            value: m.rmssdMs == 0 ? '--' : m.rmssdMs.toStringAsFixed(0),
            unit: 'ms',
          ),
          MetricRow(
            label: 'FC a riposo',
            sublabel: 'media della lettura',
            value: m.meanHrBpm == 0 ? '--' : m.meanHrBpm.toStringAsFixed(0),
            unit: 'bpm',
            divider: false,
          ),
        ],
      ),
    );
  }
}

/// Chip selezionabile (singola o toggle): selezionato = primary-tonal.
class _SelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SelChip({required this.label, required this.selected, required this.onTap});

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
        // minHeight 48 → area tappabile conforme a Material/WCAG 2.5.5: il
        // check-in mattutino è usato da appena svegli, target piccoli (~35dp
        // prima) e ravvicinati erano facili da mancare. Center widthFactor 1
        // mantiene la larghezza a contenuto dentro il Wrap.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Text(
                label,
                style: text.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
