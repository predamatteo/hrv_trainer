import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connect_iq/heart_rate_source.dart';
import '../../../shared/connect_iq/hr_source_provider.dart';
import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/rr_interval.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';
import '../../history/history_screen.dart' show sessionsListProvider;
import '../../home/state/readiness_provider.dart';

/// Punto del trace HR live: BPM istantaneo + timestamp del beat.
/// Il timestamp serve a graficare l'HR su un asse temporale reale e a
/// sovrapporre la curva del pacer respiratorio per visualizzare la RSA.
class HrTracePoint {
  final DateTime timestamp;
  final int bpm;
  const HrTracePoint({required this.timestamp, required this.bpm});
}

class TrainingState {
  final bool running;
  final DateTime? startedAt;
  final BreathingPattern pattern;
  final SessionTag tag;
  final List<RrInterval> samples;
  final List<HrTracePoint> hrTrace;
  final HrvMetrics liveMetrics;
  final int targetDurationSec;
  // Id della sessione appena salvata su DB. Valorizzato in `stop(save:true)`
  // dopo il `repo.saveSession()`, in modo che la UI possa navigare al
  // dettaglio della sessione conclusa invece di tornare in home.
  final int? lastSessionId;

  const TrainingState({
    required this.running,
    required this.startedAt,
    required this.pattern,
    required this.tag,
    required this.samples,
    required this.hrTrace,
    required this.liveMetrics,
    required this.targetDurationSec,
    this.lastSessionId,
  });

  TrainingState copyWith({
    bool? running,
    DateTime? startedAt,
    BreathingPattern? pattern,
    SessionTag? tag,
    List<RrInterval>? samples,
    List<HrTracePoint>? hrTrace,
    HrvMetrics? liveMetrics,
    int? targetDurationSec,
    int? lastSessionId,
  }) =>
      TrainingState(
        running: running ?? this.running,
        startedAt: startedAt ?? this.startedAt,
        pattern: pattern ?? this.pattern,
        tag: tag ?? this.tag,
        samples: samples ?? this.samples,
        hrTrace: hrTrace ?? this.hrTrace,
        liveMetrics: liveMetrics ?? this.liveMetrics,
        targetDurationSec: targetDurationSec ?? this.targetDurationSec,
        lastSessionId: lastSessionId ?? this.lastSessionId,
      );

  Duration get elapsed => startedAt == null
      ? Duration.zero
      : DateTime.now().difference(startedAt!);
}

class TrainingController extends StateNotifier<TrainingState> {
  final Ref ref;
  StreamSubscription<HeartRateEvent>? _sub;
  Timer? _metricsTimer;
  Timer? _autoStopTimer;
  // Fallback: parte se il watch non manda HR entro N secondi dopo l'avvio,
  // così che l'utente non resti bloccato in "avvio…" all'infinito.
  Timer? _alignmentFallback;
  static const _watchAlignmentTimeoutSec = 60;

  TrainingController(this.ref)
      : super(TrainingState(
          running: false,
          startedAt: null,
          pattern: BreathingPattern.resonance6bpm,
          tag: SessionTag.general,
          samples: const [],
          hrTrace: const [],
          liveMetrics: HrvMetrics.empty,
          targetDurationSec: 20 * 60,
        ));

  Future<void> start(
    BreathingPattern pattern, {
    int targetDurationSec = 20 * 60,
    SessionTag tag = SessionTag.general,
  }) async {
    // Reset difensivo di eventuali timer/sub residui da una sessione
    // precedente nello stesso ciclo del controller (raro grazie ad
    // autoDispose, ma evita leak di Timer in caso di doppio start).
    _sub?.cancel();
    _metricsTimer?.cancel();
    _autoStopTimer?.cancel();
    _alignmentFallback?.cancel();
    final src = ref.read(heartRateSourceProvider);
    await src.start(
      pattern: pattern,
      targetDurationSec: targetDurationSec,
    );
    ref.read(currentPatternProvider.notifier).state = pattern;
    // Stato fresh costruito a mano (non copyWith) perché il pattern
    // `?? this.startedAt` impedirebbe di azzerare startedAt se per qualche
    // motivo era già valorizzato. startedAt resta null finché il watch
    // non manda il primo HR sample: così il countdown del phone si allinea
    // a quello del watch (il delay BT + openApplication può essere di
    // decine di secondi ed era la causa del "phone finisce 17 s prima del
    // watch").
    state = TrainingState(
      running: true,
      startedAt: null,
      pattern: pattern,
      tag: tag,
      samples: const [],
      hrTrace: const [],
      liveMetrics: HrvMetrics.empty,
      targetDurationSec: targetDurationSec,
    );
    _sub = src.heartRateStream.listen(_onBeat);
    _metricsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _recomputeMetrics();
    });
    // Fallback hard-cap: se per qualsiasi motivo il watch non manda HR
    // (sensore giù, BT instabile), fai partire comunque il timer dopo
    // _watchAlignmentTimeoutSec così la sessione non resta in "avvio…"
    // a vita. Il primo HR sample sostituisce questo fallback.
    _alignmentFallback = Timer(
      const Duration(seconds: _watchAlignmentTimeoutSec),
      () {
        if (state.running && state.startedAt == null) {
          _kickoffSession(DateTime.now());
        }
      },
    );
  }

  /// Avvia il countdown reale: fissa startedAt e crea l'auto-stop timer.
  /// Idempotente — chiamato dal primo HR sample (caso normale) o dal
  /// fallback timeout.
  ///
  /// Il timer viene calcolato sul TEMPO RESIDUO da `startedAt`, non sulla
  /// durata totale: se `startedAt` è retro-datato (caso primo HR sample con
  /// watchElapsedMs > 0), partire con `targetDurationSec` interi farebbe
  /// finire il phone dopo il watch dello stesso delta.
  void _kickoffSession(DateTime startedAt) {
    if (state.startedAt != null) return;
    state = state.copyWith(startedAt: startedAt);
    _alignmentFallback?.cancel();
    _alignmentFallback = null;
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final remainingMs =
        (state.targetDurationSec * 1000 - elapsedMs).clamp(0, 1 << 31);
    _autoStopTimer = Timer(Duration(milliseconds: remainingMs), () {
      if (state.running) stop(save: true);
    });
  }

  void _onBeat(HeartRateEvent e) {
    // Primo battito post-start = il watch è partito davvero. Allinea il
    // timer del phone a questo istante (vedi commento in start()).
    //
    // Se il watch ci dice da quanti ms sta già contando (watchElapsedMs,
    // = Sys.getTimer() - mStartMs lato CIQ), retro-datiamo startedAt di
    // quel delta. Questo elimina lo skew residuo di 3-5 s causato dal
    // tempo di attivazione del sensore HR + latenza BT del primo sample:
    // il watch ha fissato il proprio mStartMs appena ricevuto START_SESSION,
    // ma il primo HR_SAMPLE arriva al phone solo dopo che il sensore
    // produce il primo battito. Senza questa correzione il countdown del
    // phone risultava sempre 3-5 s indietro rispetto al watch.
    if (state.running && state.startedAt == null) {
      final elapsedMs = e.watchElapsedMs;
      final t0 = elapsedMs != null
          ? DateTime.now().subtract(Duration(milliseconds: elapsedMs))
          : DateTime.now();
      _kickoffSession(t0);
    }
    // Mantieni TUTTI i campioni della sessione: il filtro a 5 min era
    // pensato per il calcolo reattivo ma cancellava 15 min di dati su
    // sessioni di 20 min, falsando metriche finali e salvataggio in DB.
    // La finestra rolling vive ora solo dentro _recomputeMetrics.
    final samples = [...state.samples, e.toRr()];
    final hrTrace = [
      ...state.hrTrace,
      HrTracePoint(timestamp: e.timestamp, bpm: e.bpm),
    ];
    state = state.copyWith(
      samples: samples,
      hrTrace: hrTrace.length > 600
          ? hrTrace.sublist(hrTrace.length - 600)
          : hrTrace,
    );
  }

  void _recomputeMetrics() {
    if (state.samples.length < 20) return;
    // Live: ultima finestra di 5 min per reattività + costo CPU contenuto
    // (Lomb-Scargle su 1200 sample sarebbe pesante ogni 5s). Le metriche
    // finali al stop usano comunque tutto il buffer.
    final fromT = DateTime.now().subtract(const Duration(minutes: 5));
    final window =
        state.samples.where((r) => r.timestamp.isAfter(fromT)).toList();
    if (window.length < 20) return;
    state = state.copyWith(liveMetrics: HrvCalculator.compute(window));
  }

  Future<Session?> stop({bool save = true}) async {
    _sub?.cancel();
    _metricsTimer?.cancel();
    _autoStopTimer?.cancel();
    _alignmentFallback?.cancel();
    final src = ref.read(heartRateSourceProvider);
    await src.stop();
    final ended = DateTime.now();
    final metrics = HrvCalculator.compute(state.samples);
    if (!save || state.startedAt == null) {
      // Niente da salvare: transizione semplice a running:false. lastSessionId
      // resta null e la UI ricade sul fallback (pop a home).
      state = state.copyWith(running: false, liveMetrics: metrics);
      return null;
    }
    final session = Session(
      kind: SessionKind.training,
      tag: state.tag,
      startedAt: state.startedAt!,
      endedAt: ended,
      pattern: state.pattern,
      metrics: metrics,
    );
    final repo = ref.read(sessionRepositoryProvider);
    final id = await repo.saveSession(session, state.samples);

    // Invalida i provider che leggono dal DB così la home si aggiorna in
    // tempo reale (Morning Readiness card + storico) appena l'utente torna
    // alla schermata precedente. Senza invalidate il provider resta cached
    // perché HomeScreen rimane montata sotto a /training nello stack di
    // GoRouter, quindi `readinessProvider.autoDispose` non triggera il
    // rebuild al pop e l'utente vede dati stantii fino a kill app.
    //
    // Stesso pattern usato in RemoteSessionPersister._onSummary per le
    // sessioni avviate dal watch.
    ref.invalidate(sessionsListProvider);
    ref.invalidate(readinessProvider);

    // Aggiorna running:false e lastSessionId nello stesso emit così che il
    // ref.listen della TrainingScreen possa decidere subito dove navigare
    // (dettaglio sessione anziché home) sulla base di entrambi i campi.
    state = state.copyWith(
      running: false,
      liveMetrics: metrics,
      lastSessionId: id,
    );
    return session.copyWith(id: id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _metricsTimer?.cancel();
    _autoStopTimer?.cancel();
    _alignmentFallback?.cancel();
    super.dispose();
  }
}

final trainingControllerProvider =
    StateNotifierProvider.autoDispose<TrainingController, TrainingState>(
        (ref) => TrainingController(ref));
