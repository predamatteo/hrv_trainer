import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connect_iq/heart_rate_source.dart';
import '../../../shared/connect_iq/hr_source_provider.dart';
import '../../../shared/connect_iq/watch_readiness.dart';
import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/rr_interval.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/notifications/reminder_settings.dart';
import '../../../shared/storage/session_repository.dart';
import '../../history/history_screen.dart' show sessionsListProvider;
import '../../home/state/readiness_provider.dart';
import '../../pacer/state/pacer_controller.dart';

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

  /// True quando la sessione è stata annullata perché l'orologio non ha mai
  /// inviato un battito entro [kWatchFirstSampleTimeout]. La UI lo usa per
  /// mostrare un errore ("nessun dato dall'orologio") e tornare al setup,
  /// invece di salvare/navigare a una sessione fantasma vuota.
  final bool abortedNoData;

  /// True quando, durante una cattura già avviata, il flusso di battiti si è
  /// interrotto oltre [kWatchStaleDataTimeout]. Mostra un banner non bloccante;
  /// si azzera appena i battiti riprendono.
  final bool connectionLost;

  /// True finché stiamo aspettando il primo battito dall'orologio (sessione
  /// avviata ma `startedAt` non ancora fissato). Derivato, comodo per la UI.
  bool get waitingForWatch => running && startedAt == null;

  /// True durante la fase di PREPARAZIONE coordinata: il primo battito è
  /// arrivato (startedAt fissato all'istante di inizio pacing = mStartMs del
  /// watch + prep), ma quell'istante è ancora nel futuro. Sia orologio che
  /// telefono restano "silenziosi" (nessun respiro guida, nessuna vibrazione)
  /// finché la prep non finisce, così partono a regime nello stesso istante.
  final bool preparing;

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
    this.abortedNoData = false,
    this.connectionLost = false,
    this.preparing = false,
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
    bool? abortedNoData,
    bool? connectionLost,
    bool? preparing,
  }) => TrainingState(
    running: running ?? this.running,
    startedAt: startedAt ?? this.startedAt,
    pattern: pattern ?? this.pattern,
    tag: tag ?? this.tag,
    samples: samples ?? this.samples,
    hrTrace: hrTrace ?? this.hrTrace,
    liveMetrics: liveMetrics ?? this.liveMetrics,
    targetDurationSec: targetDurationSec ?? this.targetDurationSec,
    lastSessionId: lastSessionId ?? this.lastSessionId,
    abortedNoData: abortedNoData ?? this.abortedNoData,
    connectionLost: connectionLost ?? this.connectionLost,
    preparing: preparing ?? this.preparing,
  );

  /// Secondi rimanenti di preparazione (0 se non in prep). Time-dependent: i
  /// widget che lo leggono rebuildano via timer.
  int get prepSecLeft {
    final s = startedAt;
    if (s == null || !preparing) return 0;
    final ms = s.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);
}

class TrainingController extends StateNotifier<TrainingState> {
  final Ref ref;
  StreamSubscription<HeartRateEvent>? _sub;
  Timer? _metricsTimer;
  Timer? _autoStopTimer;
  // Guardia "nessun dato": se il watch non manda alcun battito entro
  // [kWatchFirstSampleTimeout] dall'avvio, ANNULLIAMO la sessione con un errore
  // invece di farla partire comunque a vuoto (vecchio comportamento: dopo il
  // timeout fissava startedAt e registrava una sessione fantasma senza HR).
  Timer? _firstSampleTimeout;
  // Watchdog del flusso battiti DURANTE la cattura: se i battiti si fermano
  // oltre [kWatchStaleDataTimeout] alza il flag connectionLost (banner), senza
  // annullare la misura. Resettato ad ogni battito.
  Timer? _staleDataTimer;
  // Un solo tentativo di auto-recupero (reconnect) per stallo del flusso;
  // riabilitato quando i battiti riprendono. Evita un reconnect storm.
  bool _healingRequested = false;
  // Timer di fine PREPARAZIONE: scatta quando l'istante di inizio pacing è
  // raggiunto, abbassando `preparing` così UI e orb passano a regime allineati
  // al watch (che parte a ritmo nello stesso istante).
  Timer? _prepTimer;
  // Guardia di rientranza per stop(): da quando l'auto-stop a fine durata
  // chiama stop(save:true), c'è una breve finestra `await repo.saveSession`
  // in cui `running` è ancora true. Senza questa guardia un tap "Termina senza
  // salvare" proprio in quell'istante (stop(save:false)) potrebbe eseguire il
  // ramo di scarto e mostrare "non salvata perché incompleta" mentre il
  // salvataggio dell'auto-stop sta comunque committando la riga. Settata in
  // testa a stop() prima di qualunque await; il primo stop "vince", i
  // successivi sono no-op. Resettata in start() per sicurezza in caso di
  // riuso dell'istanza (di norma il controller è autoDispose e si ricrea).
  bool _stopping = false;

  /// Durata della fase di preparazione coordinata (s). L'orologio resta
  /// silenzioso e il telefono mostra "Preparati" per questo tempo dopo aver
  /// fissato l'inizio sessione, poi entrambi partono a regime insieme. Inviata
  /// al watch come `prepMs` in START_SESSION.
  static const kTrainingPrepSec = 10;

  /// Compensazione vibrazione (ms): l'orb viene tenuto INDIETRO di questo
  /// scarto rispetto al clock-sessione del watch, perché la vibrazione del
  /// watch viene avvertita ~100-130 ms dopo il bordo di fase reale (il watch
  /// rileva il cambio fase solo sul suo tick da 200 ms + spin-up aptico).
  /// Senza, l'orb (sul clock esatto) cambia PRIMA della vibrazione e sembra in
  /// anticipo. L'utente segue la vibrazione, quindi allineiamo l'orb a quella.
  /// Tunabile in base alla percezione.
  static const kOrbVibCompMs = 120;

  TrainingController(this.ref)
    : super(
        TrainingState(
          running: false,
          startedAt: null,
          pattern: BreathingPattern.resonance6bpm,
          tag: SessionTag.general,
          samples: const [],
          hrTrace: const [],
          liveMetrics: HrvMetrics.empty,
          targetDurationSec: 20 * 60,
        ),
      );

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
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _prepTimer?.cancel();
    _stopping = false;
    final src = ref.read(heartRateSourceProvider);
    // prepMs: l'orologio resta silenzioso (niente vibrazione/respiro) per
    // questo tempo dopo START, poi parte a regime; il telefono fa lo stesso.
    // Allinea l'avvio del respiro guida sui due dispositivi ed evita l'orb
    // congelato nei secondi di warm-up/connessione.
    await src.start(
      pattern: pattern,
      targetDurationSec: targetDurationSec,
      prepMs: kTrainingPrepSec * 1000,
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
    // Guardia "nessun dato": se entro il timeout non è arrivato ALCUN battito,
    // annulla la sessione con errore invece di farla partire a vuoto. Il primo
    // HR sample disarma questa guardia (vedi _kickoffSession). Una misura senza
    // HR non ha alcun valore: meglio dirlo all'utente che registrare 20 min di
    // nulla.
    _firstSampleTimeout = Timer(kWatchFirstSampleTimeout, () {
      if (state.running && state.startedAt == null) {
        _abortNoData();
      }
    });
  }

  /// Annulla la sessione perché l'orologio non ha inviato dati: ferma la
  /// sorgente e porta lo stato a `running:false` con `abortedNoData:true`, senza
  /// salvare nulla. La UI mostra l'errore e torna al setup.
  Future<void> _abortNoData() async {
    _sub?.cancel();
    _metricsTimer?.cancel();
    _autoStopTimer?.cancel();
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _prepTimer?.cancel();
    try {
      await ref.read(heartRateSourceProvider).stop();
    } catch (_) {}
    state = state.copyWith(running: false, abortedNoData: true);
  }

  /// (Ri)arma il watchdog del flusso battiti durante la cattura. Se non arriva
  /// un nuovo battito entro [kWatchStaleDataTimeout], alza connectionLost.
  void _armStaleDataWatchdog() {
    _staleDataTimer?.cancel();
    _staleDataTimer = Timer(kWatchStaleDataTimeout, () {
      if (state.running && state.startedAt != null && !state.connectionLost) {
        state = state.copyWith(connectionLost: true);
        // Auto-recupero: uno stallo del flusso è spesso il listener app-event
        // nativo caduto durante una rinegoziazione BT. reconnect() ri-scansiona
        // il device e ri-registra il listener, così i battiti riprendono senza
        // killare l'app. Un solo tentativo per stallo (riarmato in _onBeat).
        if (!_healingRequested) {
          _healingRequested = true;
          unawaited(ref.read(heartRateSourceProvider).reconnect());
        }
      }
    });
  }

  /// Fissa l'inizio sessione e arma auto-stop + fine-prep.
  /// Idempotente — chiamato dal primo HR sample.
  ///
  /// [pacingStart] è l'istante in cui il respiro guida deve PARTIRE su entrambi
  /// i dispositivi (= mStartMs del watch + prep). È nel futuro durante la prep:
  /// in quel caso `preparing` resta true finché `_prepTimer` non scatta. Se la
  /// connessione è stata così lenta che pacingStart è già passato, si parte
  /// subito a regime (preparing false).
  ///
  /// L'auto-stop è sul TEMPO RESIDUO da pacingStart: durante la prep elapsedMs
  /// è negativo, quindi remainingMs include la prep e il phone si ferma allo
  /// stesso istante del watch (mStartMs + prep + durata).
  void _kickoffSession(DateTime pacingStart) {
    if (state.startedAt != null) return;
    final now = DateTime.now();
    final preparing = pacingStart.isAfter(now);
    state = state.copyWith(startedAt: pacingStart, preparing: preparing);
    _firstSampleTimeout?.cancel();
    _firstSampleTimeout = null;
    _armStaleDataWatchdog();
    final elapsedMs = now.difference(pacingStart).inMilliseconds;
    final remainingMs = (state.targetDurationSec * 1000 - elapsedMs).clamp(
      0,
      1 << 31,
    );
    _autoStopTimer = Timer(Duration(milliseconds: remainingMs), () {
      if (state.running) stop(save: true);
    });
    if (preparing) {
      _prepTimer?.cancel();
      _prepTimer = Timer(pacingStart.difference(now), () {
        if (state.running && state.preparing) {
          state = state.copyWith(preparing: false);
        }
      });
    }
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
      // Primo battito: fissa l'istante di INIZIO PACING.
      final pacer = e.watchPacerMs;
      final maxMs = state.targetDurationSec * 1000;
      if (pacer != null) {
        // Watch con prep coordinata: pacer = tempo di sessione (negativo
        // durante la prep). pacingStart = adesso - pacer (nel futuro durante la
        // prep → preparing). Guardia anti-stale: deve stare in
        // [-(prep) .. durata]; fuori range (residuo loop sensori) → parti ora.
        final p = (pacer >= -(kTrainingPrepSec * 1000) - 1000 && pacer <= maxMs)
            ? pacer
            : 0;
        _kickoffSession(DateTime.now().subtract(Duration(milliseconds: p)));
      } else {
        // Firmware vecchio senza prep: nessuna preparazione, allinea a mStartMs
        // del watch via watchElapsedMs come nel comportamento precedente.
        final raw = e.watchElapsedMs;
        final elapsedMs = (raw != null && raw >= 0 && raw <= maxMs) ? raw : null;
        final t0 = elapsedMs != null
            ? DateTime.now().subtract(Duration(milliseconds: elapsedMs))
            : DateTime.now();
        _kickoffSession(t0);
      }
    } else if (state.running && !state.preparing) {
      // Re-sync continuo (closed-loop) dell'orb sul TEMPO DI SESSIONE del watch
      // (master del ritmo). Senza, l'errore dell'aggancio iniziale + il drift
      // fra i due oscillatori restavano congelati e l'orb finiva qualche
      // secondo dietro la vibrazione. Nudga solo l'offset dell'orb, MAI
      // auto-stop/countdown. Solo a regime. Con watch vecchio (no pacerMs)
      // ricade su watchElapsedMs (nessuna prep).
      // Bersaglio dell'orb = clock-sessione del watch MENO la compensazione
      // vibrazione, così l'orb cade sulla vibrazione avvertita (non sul bordo
      // teorico). Vedi kOrbVibCompMs.
      final maxMs = state.targetDurationSec * 1000;
      final pacer = e.watchPacerMs;
      if (pacer != null) {
        final target = pacer - kOrbVibCompMs;
        if (target >= 0 && pacer <= maxMs) {
          ref.read(pacerControllerProvider.notifier).resync(target);
        }
      } else {
        final raw = e.watchElapsedMs;
        if (raw != null && raw >= 0 && raw <= maxMs) {
          final target = raw - kOrbVibCompMs;
          if (target >= 0) {
            ref.read(pacerControllerProvider.notifier).resync(target);
          }
        }
      }
    }
    // Battito ricevuto: il flusso è vivo. Rilancia il watchdog.
    _armStaleDataWatchdog();
    // Battiti in arrivo → riabilita l'auto-recupero per un eventuale stallo futuro.
    _healingRequested = false;
    // Raccogli RR/HR SOLO a regime: i battiti durante la prep sono warm-up a
    // respiro NON guidato (orologio silenzioso) e contaminerebbero
    // metriche/grafico. Mantieni TUTTI i campioni della sessione (la finestra
    // rolling vive solo dentro _recomputeMetrics).
    if (state.startedAt != null && !state.preparing) {
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
        connectionLost: false,
      );
    } else if (state.connectionLost) {
      state = state.copyWith(connectionLost: false);
    }
  }

  void _recomputeMetrics() {
    if (state.samples.length < 20) return;
    // Live: ultima finestra di 5 min per reattività + costo CPU contenuto
    // (Lomb-Scargle su 1200 sample sarebbe pesante ogni 5s). Le metriche
    // finali al stop usano comunque tutto il buffer.
    final fromT = DateTime.now().subtract(const Duration(minutes: 5));
    final window = state.samples
        .where((r) => r.timestamp.isAfter(fromT))
        .toList();
    if (window.length < 20) return;
    state = state.copyWith(liveMetrics: HrvCalculator.compute(window));
  }

  Future<Session?> stop({bool save = true}) async {
    // Guardia di rientranza: il primo stop vince. Evita che un secondo stop
    // concorrente (es. tap "Termina senza salvare" proprio mentre l'auto-stop
    // a fine durata è dentro `await repo.saveSession`) esegua il ramo di scarto
    // e contraddica un salvataggio già in corso. Vedi `_stopping`.
    if (_stopping) return null;
    _stopping = true;
    _sub?.cancel();
    _metricsTimer?.cancel();
    _autoStopTimer?.cancel();
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _prepTimer?.cancel();
    // Ferma il watch in BACKGROUND, senza bloccare la transizione della UI.
    // L'handshake di stop lato GarminCiqSource (attesa ACK ~3s + eventuale
    // forceStop ~5s) poteva tenere `await src.stop()` appeso fino a ~8s: in
    // quell'intervallo `running` restava true e l'utente vedeva la sessione
    // "continuare ad andare" (orb che pulsa + countdown che scorre) per una
    // decina di secondi dopo aver premuto stop. Spostandolo fuori dall'await,
    // lo stato passa subito a running:false e l'orologio viene fermato dietro
    // le quinte (il fallback forceStop continua a funzionare lì).
    final src = ref.read(heartRateSourceProvider);
    unawaited(src.stop());
    final ended = DateTime.now();
    final metrics = HrvCalculator.compute(state.samples);
    if (!save || state.startedAt == null) {
      // Niente da salvare: sessione annullata in connessione/preparazione,
      // OPPURE interrotta manualmente prima del termine (incompleta → per
      // scelta non la salviamo, vedi pulsante stop). lastSessionId resta null
      // e la UI ricade sul fallback (pop a home, niente "completata").
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

    // Modalità promemoria "smart skip": ora che oggi risulta allenato,
    // riallinea lo scheduling così l'eventuale promemoria odierno successivo
    // viene saltato. Fire-and-forget; no-op se la modalità skip è off.
    unawaited(ref.read(reminderControllerProvider.notifier).refresh());

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
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _prepTimer?.cancel();
    super.dispose();
  }
}

final trainingControllerProvider =
    StateNotifierProvider.autoDispose<TrainingController, TrainingState>(
      (ref) => TrainingController(ref),
    );
