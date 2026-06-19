import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../shared/connect_iq/widgets/watch_readiness_gate.dart';
import '../../shared/hrv/breathing_pacer.dart';
import '../../shared/hrv/session_models.dart';
import '../../shared/hrv/widgets/live_session_view.dart';
import '../../shared/storage/session_repository.dart';
import '../pacer/state/pacer_controller.dart';
import '../pacer/widgets/breathing_orb.dart';
import 'state/training_controller.dart';

class TrainingScreen extends ConsumerStatefulWidget {
  final SessionTag initialTag;

  const TrainingScreen({super.key, this.initialTag = SessionTag.general});

  @override
  ConsumerState<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends ConsumerState<TrainingScreen>
    with TickerProviderStateMixin {
  late BreathingPattern _pattern;
  late int _durationMin;
  late SessionTag _tag;

  /// Frequenza di risonanza personale dall'ultimo assessment (resp/min), se
  /// disponibile: diventa il default del respiro per i contesti a ~6 bpm.
  double? _resonanceBpm;

  /// True dopo che l'utente tocca lo slider del respiro: evita che il caricamento
  /// asincrono della RF sovrascriva una scelta manuale.
  bool _patternTouched = false;

  @override
  void dispose() {
    // Sicurezza: se l'utente esce con back system, assicurati che il
    // wakelock venga rilasciato anche se ref.listen non era ancora attivo.
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    _applyTagDefaults();
    _loadResonance();
  }

  /// Carica la RF personale dall'ultimo assessment e, se l'utente non ha ancora
  /// toccato lo slider, riapplica i default così i contesti a ~6 bpm partono
  /// dalla risonanza personale invece che dai 6.0 generici.
  Future<void> _loadResonance() async {
    final rf = await ref.read(sessionRepositoryProvider).latestResonanceBpm();
    if (!mounted || rf == null) return;
    setState(() {
      _resonanceBpm = rf;
      if (!_patternTouched) _applyTagDefaults();
    });
  }

  // Quando l'utente cambia tag aggiorniamo pattern e durata ai default del
  // contesto (es. sleep → 5 bpm 10 min, postWorkout → 6 bpm 15 min). Gli
  // slider restano modificabili dopo: il tag fornisce un punto di partenza
  // sensato, non un vincolo.
  void _applyTagDefaults() {
    final base = _tag.defaultPattern;
    // Per i contesti la cui andatura di default è la risonanza generica
    // (~6 bpm) usa la RF personale dall'assessment, se disponibile. I contesti
    // volutamente più lenti (sleep 5.0, stress/recovery 5.5) mantengono la loro
    // andatura, che è una scelta clinica e non la RF.
    final rf = _resonanceBpm;
    _pattern = (rf != null && base.breathsPerMinute >= 6.0)
        ? BreathingPattern.fromBpm(rf)
        : base;
    _durationMin = _tag.defaultDurationMin;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TrainingState>(trainingControllerProvider, (prev, next) {
      // Avvia il pacer dell'orb solo quando inizia il REGIME (fine prep), non
      // al primo battito: durante la prep watch e telefono restano silenziosi e
      // partono insieme. startOffset = now - startedAt: a fine prep ≈ 0 (orb a
      // inizio respiro); se la connessione è stata lenta e la prep è già
      // passata, l'orb parte a metà ciclo già allineato al watch.
      final wasRegime =
          prev != null && prev.startedAt != null && !prev.preparing;
      final isRegime =
          next.running && next.startedAt != null && !next.preparing;
      if (!wasRegime && isRegime) {
        final offset = DateTime.now().difference(next.startedAt!);
        ref.read(pacerControllerProvider.notifier).start(startOffset: offset);
      }
      if (prev != null && prev.running && !next.running) {
        // Ferma il pacer ticker quando la sessione termina (auto-stop o
        // stop manuale). Provider non è più autoDispose quindi va spento.
        ref.read(pacerControllerProvider.notifier).pause();

        // Annullata per assenza di dati dall'orologio (timeout 35 s): NON è una
        // sessione completata. Errore + resta sul setup (running false →
        // _buildSetup), niente sessione fantasma.
        if (next.abortedNoData) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Nessun dato dall\'orologio: misura annullata. '
                'Controlla la connessione e riprova.',
              ),
              duration: Duration(seconds: 4),
            ),
          );
          return;
        }

        // Nessuna sessione salvata. Due casi:
        //  - misura interrotta MANUALMENTE prima del termine (a regime, quindi
        //    startedAt fissato e prep finita): per scelta non salviamo le
        //    sessioni incomplete → avvisiamo che non è stata registrata.
        //  - annullata in connessione/preparazione (startedAt nullo o ancora in
        //    prep): nulla di misurato, esci in silenzio.
        final id = next.lastSessionId;
        if (id == null) {
          if (next.startedAt != null && !next.preparing) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Sessione interrotta: non salvata perché incompleta',
                ),
                duration: Duration(seconds: 3),
              ),
            );
          }
          if (context.canPop()) context.pop();
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sessione completata e salvata'),
            duration: Duration(seconds: 2),
          ),
        );
        // Mostra subito il dettaglio della sessione conclusa, sostituendo la
        // route /training nello stack così che il back riporti in home.
        context.pushReplacement('/history/session/$id');
      }
    });

    // Watch SOLO il flag running: cambio solo quando si avvia/ferma sessione.
    // Tutti i sotto-widget watchano in autonomia ciò che gli serve, così il
    // pacer (20 Hz) non ricostruisce chart/metrics/progress.
    final running = ref.watch(
      trainingControllerProvider.select((s) => s.running),
    );

    // Fase di connessione: sessione avviata ma primo battito non ancora
    // arrivato (warm-up sensore + latenza BT, osservata 3-14 s). Mostriamo una
    // vista d'attesa dedicata invece dell'orb fermo — che sembrava un guasto di
    // connessione. I minuti partono a regime solo quando l'orologio inizia
    // davvero a inviare battiti (startedAt fissato).
    final waiting = ref.watch(
      trainingControllerProvider.select((s) => s.waitingForWatch),
    );

    // Fase di PREPARAZIONE coordinata: connesso (primo battito arrivato), ma
    // l'inizio del pacing è ancora nel futuro. Orologio e telefono restano
    // silenziosi e mostrano "Preparati" finché non parte il regime, insieme.
    final preparing = ref.watch(
      trainingControllerProvider.select((s) => s.preparing),
    );

    // Tieni lo schermo acceso durante la sessione (biofeedback richiede
    // di vedere orb e dati senza black-out Android).
    WakelockPlus.toggle(enable: running);

    if (!running) {
      return _buildSetup(context);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await _confirmStop();
        if (confirm == true && context.mounted) {
          // Stop manuale = sessione incompleta → non salvata (save:false).
          await ref.read(trainingControllerProvider.notifier).stop(save: false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const _TrainingTitle(),
          actions: [
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () async {
                final confirm = await _confirmStop();
                if (confirm == true && context.mounted) {
                  // Stop manuale = sessione incompleta → non salvata (save:false).
                  await ref
                      .read(trainingControllerProvider.notifier)
                      .stop(save: false);
                }
              },
            ),
          ],
        ),
        // Stesso layout della misura morning check-in: status → countdown →
        // BPM → grafico HR (Expanded) → statistiche. L'UNICA aggiunta è l'orb
        // del respiro guida in cima (rimpicciolito).
        body: SafeArea(
          child: waiting
              ? WatchWaitingView(
                  title: 'Connessione con l\'orologio…',
                  onCancel: () => ref
                      .read(trainingControllerProvider.notifier)
                      .stop(save: false),
                )
              : preparing
              ? _PrepView(
                  onCancel: () => ref
                      .read(trainingControllerProvider.notifier)
                      .stop(save: false),
                )
              : Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            // L'orb è dimensionato sull'altezza disponibile (cap 160): su
            // schermi bassi (split-screen, testo ingrandito) si rimpicciolisce
            // da solo così il readout sotto non manda la Column in overflow.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final orbSize = (constraints.maxHeight * 0.24).clamp(
                  96.0,
                  160.0,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _TrainingConnectionBanner(),
                    // Indicatore inspira/espira: unico elemento in più rispetto
                    // al morning check-in.
                    Center(child: _OrbView(size: orbSize)),
                    const SizedBox(height: 8),
                    const _TrainingStatus(),
                    const SizedBox(height: 20),
                    const _TrainingCountdown(),
                    const SizedBox(height: 16),
                    const _TrainingBpm(),
                    const SizedBox(height: 16),
                    const Expanded(child: _TrainingChart()),
                    const SizedBox(height: 16),
                    const _TrainingStats(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bpm = _pattern.breathsPerMinute;
    return Scaffold(
      appBar: AppBar(title: const Text('Nuova sessione')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                children: [
                  // ── Contesto: scelta primaria, precompila respiro e durata ──
                  Text('Contesto', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in SessionTag.values)
                        ChoiceChip(
                          avatar: Icon(
                            _tagIcon(t),
                            size: 18,
                            color: _tag == t
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                          label: Text(t.label),
                          selected: _tag == t,
                          onSelected: (_) => setState(() {
                            _tag = t;
                            _patternTouched = false;
                            _applyTagDefaults();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Razionale del contesto scelto, ben visibile.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_tagIcon(_tag), size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _tag.rationale,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  // ── Imposta: default del contesto, regolabili ──
                  Row(
                    children: [
                      Text('Imposta', style: theme.textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'pre-compilati dal contesto, regolabili',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _SettingHeader(
                    label: 'Respiro',
                    value: '${bpm.toStringAsFixed(1)} resp/min',
                    hint: '≈ frequenza di risonanza',
                  ),
                  Slider(
                    min: 4.0,
                    max: 8.0,
                    divisions: 16,
                    value: bpm,
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
                    const SizedBox(height: 12),
                    _AssessmentHint(onTap: () => context.push('/assessment')),
                  ],
                ],
              ),
            ),
            // ── CTA pinnata in basso, sempre visibile ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        'Avvia • $_durationMin min a '
                        '${bpm.toStringAsFixed(1)} resp/min',
                      ),
                      onPressed: _onStart,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Si sincronizza con l\'orologio all\'avvio',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
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

  Future<void> _onStart() async {
    debugPrint('[TRAIN] Avvia pressed');
    // Gate di connettività: senza un link confermato col watch NON avviamo la
    // sessione (niente più "aspetta e parti comunque" senza dati). Il gate
    // offre le azioni per risolvere (Attiva BT / Riconnetti / Cerca orologio).
    final ready = await ensureWatchReady(context, ref);
    if (!ready || !mounted) return;
    ref.read(pacerPreferencesProvider.notifier).state = ref
        .read(pacerPreferencesProvider)
        .copyWith(pattern: _pattern);
    await ref
        .read(trainingControllerProvider.notifier)
        .start(_pattern, targetDurationSec: _durationMin * 60, tag: _tag);
    // Il pacer NON parte qui: lo avvia il ref.listen quando arriva il primo HR
    // sample dal watch, così ciclo ispira/espira su phone e watch combaciano.
    debugPrint('[TRAIN] training started, pacer waiting for watch');
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
            foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
            backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Termina senza salvare'),
        ),
      ],
    ),
  );
}

/// Intestazione di una riga di impostazione: etichetta a sinistra, valore in
/// evidenza a destra, hint opzionale sotto. Usata per Respiro e Durata nel setup.
class _SettingHeader extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  const _SettingHeader({required this.label, required this.value, this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        if (hint != null)
          Text(
            hint!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Suggerimento mostrato nel setup quando manca una RF personale: invita a fare
/// l'Assessment così il respiro può partire dalla frequenza di risonanza reale.
class _AssessmentHint extends StatelessWidget {
  final VoidCallback onTap;
  const _AssessmentHint({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.tune, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Non hai ancora la tua frequenza di risonanza: fai '
                'l\'Assessment per personalizzare il respiro.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Titolo AppBar calmo, come nel morning check-in. Cambia solo allo scatto del
/// primo HR sample (startedAt fissato), quindi basta un watch sul flag.
class _TrainingTitle extends ConsumerWidget {
  const _TrainingTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(
      trainingControllerProvider.select((s) => s.startedAt == null),
    );
    return Text(waiting ? 'Allenamento • avvio…' : 'Allenamento');
  }
}

/// Riga di stato sopra il countdown. Parallela al morning check-in: in attesa
/// dell'allineamento col watch invita a prepararsi, poi a seguire il respiro.
class _TrainingStatus extends ConsumerWidget {
  const _TrainingStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final waiting = ref.watch(
      trainingControllerProvider.select((s) => s.startedAt == null),
    );
    return Text(
      waiting ? 'Avvio sul watch… stai pronto' : 'Segui il respiro guida',
      textAlign: TextAlign.center,
      style: theme.textTheme.titleMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Vista della fase di PREPARAZIONE coordinata: connessi, ma il respiro guida
/// non è ancora partito. Mostra "Preparati" + countdown dei secondi che mancano
/// all'avvio; nello stesso intervallo l'orologio resta silenzioso e mostra la
/// sua "Preparati", così i due partono a regime insieme. Ticka via timer
/// interno perché [TrainingState.prepSecLeft] dipende dall'ora corrente.
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
    _ticker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secLeft = ref.read(trainingControllerProvider).prepSecLeft;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.self_improvement, size: 48, color: scheme.primary),
            const SizedBox(height: 20),
            Text('Preparati', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              secLeft > 0 ? 'Si parte tra $secLeft s' : 'Si parte…',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w300,
                color: scheme.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Connesso. Mettiti comodo e tieni il polso fermo: orologio e '
              'telefono partono insieme a fine preparazione.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: widget.onCancel,
              child: const Text('Annulla'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner non bloccante mostrato quando il flusso di battiti si interrompe a
/// metà sessione (connessione persa). Watcha solo il flag dedicato così non
/// ricostruisce al ritmo dei battiti. Occupa spazio solo quando attivo.
class _TrainingConnectionBanner extends ConsumerWidget {
  const _TrainingConnectionBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lost = ref.watch(
      trainingControllerProvider.select((s) => s.connectionLost),
    );
    if (!lost) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: WatchConnectionLostBanner(),
    );
  }
}

/// Countdown grande nel body (come il morning check-in). Si auto-aggiorna ogni
/// secondo via Timer interno invece di dipendere dal rebuild del controller
/// (che cambia ad ogni HR sample). Mostra il tempo residuo; finché il watch non
/// si allinea (startedAt == null) resta in grigio sulla durata piena.
class _TrainingCountdown extends ConsumerStatefulWidget {
  const _TrainingCountdown();

  @override
  ConsumerState<_TrainingCountdown> createState() => _TrainingCountdownState();
}

class _TrainingCountdownState extends ConsumerState<_TrainingCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.read(trainingControllerProvider);
    if (st.startedAt == null) {
      // In attesa dell'allineamento col watch: durata piena, in grigio.
      return BigCountdown(secLeft: st.targetDurationSec, muted: true);
    }
    final remaining = Duration(seconds: st.targetDurationSec) - st.elapsed;
    final remSec = remaining.isNegative ? 0 : remaining.inSeconds;
    return BigCountdown(secLeft: remSec);
  }
}

/// BPM corrente: ultimo battito ricevuto dal watch. Watcha solo l'ultimo bpm
/// del trace così rebuilda ~1 Hz, non al ritmo del pacer.
class _TrainingBpm extends ConsumerWidget {
  const _TrainingBpm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bpm = ref.watch(
      trainingControllerProvider.select(
        (s) => s.hrTrace.isEmpty ? null : s.hrTrace.last.bpm,
      ),
    );
    return LiveBpmRow(bpm: bpm);
  }
}

/// Grafico HR live con overlay del respiro guida. Stesso widget condiviso del
/// morning check-in, ma con [pacer] valorizzato così disegna la curva guida
/// tratteggiata + legenda.
class _TrainingChart extends ConsumerWidget {
  const _TrainingChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(trainingControllerProvider);
    return LiveHrChart(
      trace: st.hrTrace,
      startReference: st.startedAt,
      pacer: st.pattern,
    );
  }
}

/// Statistiche live (RMSSD preview · RSA Δ · campioni), identiche al morning.
class _TrainingStats extends ConsumerWidget {
  const _TrainingStats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(trainingControllerProvider);
    return LiveSessionStats(
      trace: st.hrTrace,
      liveMetrics: st.liveMetrics,
      sampleCount: st.samples.length,
    );
  }
}

/// Orb del respiro: ascolta il pacer (20 Hz) ma NON il TrainingState, così che
/// il rebuild del cerchio non trascini chart/countdown/statistiche. Più piccolo
/// che in passato (160) per lasciare spazio al readout in stile morning sotto.
class _OrbView extends ConsumerWidget {
  final double size;
  const _OrbView({this.size = 160});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = ref.watch(pacerControllerProvider);
    final theme = Theme.of(context);
    return BreathingOrb(
      amplitude: tick.amplitude,
      phase: tick.phase,
      phaseProgress: tick.progress,
      inhaleColor: theme.colorScheme.primary,
      exhaleColor: theme.colorScheme.secondary,
      size: size,
    );
  }
}
