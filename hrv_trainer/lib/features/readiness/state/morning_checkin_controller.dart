import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connect_iq/heart_rate_source.dart';
import '../../../shared/connect_iq/hr_source_provider.dart';
import '../../../shared/connect_iq/watch_readiness.dart';
import '../../../shared/hrv/breathing_pacer.dart';
import '../../../shared/hrv/hrv_metrics.dart';
import '../../../shared/hrv/morning_reading.dart';
import '../../../shared/hrv/rr_interval.dart';
import '../../../shared/hrv/session_models.dart';
import '../../../shared/storage/session_repository.dart';
import '../../history/history_screen.dart' show sessionsListProvider;
import '../../home/state/readiness_provider.dart';
import 'readiness_providers.dart';

/// Fasi del check-in mattutino.
/// - [idle]: scelta postura/protocollo, pronto a partire.
/// - [measuring]: assestamento + cattura RR a respiro spontaneo.
/// - [review]: misura conclusa, raccolta contesto e salvataggio.
/// - [saved]: lettura persistita.
enum CheckInPhase { idle, measuring, review, saved }

class MorningCheckInState {
  final CheckInPhase phase;
  final Posture posture;
  final MorningProtocol protocol;

  /// True dall'avvio finché non arriva il PRIMO battito dall'orologio. Durante
  /// l'attesa il countdown NON parte (niente più cattura a vuoto se il watch
  /// non risponde). La schermata mostra una vista "in attesa".
  final bool waitingForWatch;

  /// True quando la misura è stata annullata perché l'orologio non ha mai
  /// inviato un battito entro [kWatchFirstSampleTimeout]: la UI segnala
  /// l'errore e resta su idle invece di passare a una review vuota.
  final bool abortedNoData;

  /// True quando, a cattura avviata, il flusso di battiti si interrompe oltre
  /// [kWatchStaleDataTimeout]. Banner non bloccante; si azzera alla ripresa.
  final bool connectionLost;

  /// True durante i secondi iniziali di assestamento (no raccolta dati).
  final bool settling;

  /// Secondi rimanenti nella fase corrente (assestamento o cattura).
  final int secLeft;

  final int? currentBpm;
  final int sampleCount;

  /// Trace HR live per il grafico durante la misura: l'oscillazione dei battiti
  /// è la visualizzazione del respiro spontaneo (RSA). Riempito in `_onBeat`
  /// anche durante l'assestamento, capped per non crescere indefinitamente.
  final List<HrTracePoint> hrTrace;

  /// Anteprima metriche ricalcolata ogni 5s durante la cattura (preview, NON il
  /// risultato: su misure brevi è rumorosa e differisce dal valore finale).
  /// Distinta da [metrics], che è il valore definitivo prodotto in `_finish`.
  final HrvMetrics? liveMetrics;

  /// Metriche calcolate al termine della cattura (fase review/saved).
  final HrvMetrics? metrics;
  final int? savedSessionId;

  const MorningCheckInState({
    required this.phase,
    required this.posture,
    required this.protocol,
    this.waitingForWatch = false,
    this.abortedNoData = false,
    this.connectionLost = false,
    this.settling = false,
    this.secLeft = 0,
    this.currentBpm,
    this.sampleCount = 0,
    this.hrTrace = const [],
    this.liveMetrics,
    this.metrics,
    this.savedSessionId,
  });

  MorningCheckInState copyWith({
    CheckInPhase? phase,
    Posture? posture,
    MorningProtocol? protocol,
    bool? waitingForWatch,
    bool? abortedNoData,
    bool? connectionLost,
    bool? settling,
    int? secLeft,
    int? currentBpm,
    int? sampleCount,
    List<HrTracePoint>? hrTrace,
    HrvMetrics? liveMetrics,
    HrvMetrics? metrics,
    int? savedSessionId,
  }) => MorningCheckInState(
    phase: phase ?? this.phase,
    posture: posture ?? this.posture,
    protocol: protocol ?? this.protocol,
    waitingForWatch: waitingForWatch ?? this.waitingForWatch,
    abortedNoData: abortedNoData ?? this.abortedNoData,
    connectionLost: connectionLost ?? this.connectionLost,
    settling: settling ?? this.settling,
    secLeft: secLeft ?? this.secLeft,
    currentBpm: currentBpm ?? this.currentBpm,
    sampleCount: sampleCount ?? this.sampleCount,
    hrTrace: hrTrace ?? this.hrTrace,
    liveMetrics: liveMetrics ?? this.liveMetrics,
    metrics: metrics ?? this.metrics,
    savedSessionId: savedSessionId ?? this.savedSessionId,
  );
}

class MorningCheckInController extends StateNotifier<MorningCheckInState> {
  final Ref ref;
  StreamSubscription<HeartRateEvent>? _sub;
  Timer? _timer;
  Timer? _metricsTimer;
  // Guardia "nessun dato": annulla la misura se nessun battito arriva entro
  // [kWatchFirstSampleTimeout]. Disarmata dal primo battito.
  Timer? _firstSampleTimeout;
  // Watchdog del flusso battiti durante la cattura: alza connectionLost se i
  // battiti si interrompono. Resettato ad ogni battito.
  Timer? _staleDataTimer;
  // Un solo tentativo di auto-recupero (reconnect) per stallo del flusso;
  // riabilitato quando i battiti riprendono. Evita un reconnect storm su un
  // link che resta muto.
  bool _healingRequested = false;
  DateTime? _phaseStart;
  final List<RrInterval> _window = [];

  /// Massimo numero di punti nel trace HR live (copre seated180 con margine).
  static const _maxTracePoints = 240;

  /// Secondi di assestamento iniziale prima di iniziare a raccogliere RR:
  /// scarta i primi battiti instabili (attivazione sensore, transitorio).
  static const settleSec = 10;

  MorningCheckInController(this.ref)
    : super(
        const MorningCheckInState(
          phase: CheckInPhase.idle,
          posture: Posture.seated,
          protocol: MorningProtocol.seated60,
        ),
      );

  void setPosture(Posture p) {
    if (state.phase != CheckInPhase.idle) return;
    state = state.copyWith(posture: p);
  }

  void setProtocol(MorningProtocol p) {
    if (state.phase != CheckInPhase.idle) return;
    state = state.copyWith(protocol: p);
  }

  Future<void> start() async {
    if (state.phase == CheckInPhase.measuring) return;
    _sub?.cancel();
    _timer?.cancel();
    _metricsTimer?.cancel();
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _window.clear();
    // Il countdown NON parte qui: _phaseStart resta null finché non arriva il
    // primo battito (vedi _onBeat). Così l'assestamento + cattura cominciano a
    // contare solo quando il watch sta davvero misurando, invece di scorrere a
    // vuoto se l'orologio non risponde.
    _phaseStart = null;

    final src = ref.read(heartRateSourceProvider);
    final total = settleSec + state.protocol.captureSec;
    // Niente pattern → misura SPONTANEA (nessun pacer). Inviamo la durata REALE
    // (assestamento + cattura): così il countdown mostrato dall'orologio coincide
    // con quello del telefono. Il margine di backup che impedisce all'auto-stop
    // del watch di troncare la finestra NON sta più qui: gonfiarlo lato telefono
    // faceva apparire il countdown dell'orologio 10s avanti rispetto al telefono.
    // Ora vive lato orologio, applicato SOLO al suo auto-stop di backup per le
    // sessioni phone-driven (vedi HrvTrainerView.onTick, AUTOSTOP_BACKUP_GUARD_MS).
    // Il telefono resta il driver e ferma a fine cattura (_finish → src.stop()).
    await src.start(targetDurationSec: total);

    state = MorningCheckInState(
      phase: CheckInPhase.measuring,
      posture: state.posture,
      protocol: state.protocol,
      waitingForWatch: true,
      settling: true,
      secLeft: settleSec,
    );

    _sub = src.heartRateStream.listen(_onBeat);
    // Guardia "nessun dato": se l'orologio non manda alcun battito entro il
    // timeout, annulla con errore invece di passare a una review vuota.
    _firstSampleTimeout = Timer(kWatchFirstSampleTimeout, () {
      if (state.phase == CheckInPhase.measuring && _phaseStart == null) {
        _abortNoData();
      }
    });
    // _timer e _metricsTimer vengono avviati dal primo battito in _onBeat.
  }

  /// Annulla la misura perché l'orologio non ha inviato dati: ferma la
  /// sorgente e torna a idle con `abortedNoData:true`. La UI mostra l'errore.
  Future<void> _abortNoData() async {
    _timer?.cancel();
    _timer = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _firstSampleTimeout?.cancel();
    _firstSampleTimeout = null;
    _staleDataTimer?.cancel();
    _staleDataTimer = null;
    _sub?.cancel();
    _sub = null;
    try {
      await ref.read(heartRateSourceProvider).stop();
    } catch (_) {}
    _window.clear();
    state = MorningCheckInState(
      phase: CheckInPhase.idle,
      posture: state.posture,
      protocol: state.protocol,
      abortedNoData: true,
    );
  }

  /// (Ri)arma il watchdog del flusso battiti durante la cattura.
  void _armStaleDataWatchdog() {
    _staleDataTimer?.cancel();
    _staleDataTimer = Timer(kWatchStaleDataTimeout, () {
      if (state.phase == CheckInPhase.measuring &&
          _phaseStart != null &&
          !state.connectionLost) {
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

  void _tick() {
    final startedAt = _phaseStart;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt).inSeconds;
    final captureTarget = state.protocol.captureSec;
    if (elapsed < settleSec) {
      state = state.copyWith(settling: true, secLeft: settleSec - elapsed);
      return;
    }
    final captureElapsed = elapsed - settleSec;
    if (captureElapsed >= captureTarget) {
      _finish();
      return;
    }
    state = state.copyWith(
      settling: false,
      secLeft: captureTarget - captureElapsed,
    );
  }

  void _onBeat(HeartRateEvent e) {
    // Primo battito: il watch sta misurando davvero. Ancoriamo qui l'inizio di
    // assestamento+cattura e facciamo partire i timer (prima erano fermi). Da
    // questo istante disarmiamo la guardia "nessun dato".
    if (_phaseStart == null) {
      // Aggancia l'inizio al clock del watch (come il training): retro-data
      // _phaseStart di watchElapsedMs, così assestamento+cattura del telefono
      // contano dallo STESSO istante del watch (mStartMs) invece di partire
      // 3-5s dopo (warm-up sensore + latenza BT) e far divergere i due
      // countdown. Stessa guardia anti-stale del training: un watchElapsedMs
      // fuori range (residuo di un loop sensori non resettato) ancorerebbe il
      // countdown a ~0 facendo finire subito la misura → in quel caso si
      // parte da adesso.
      final raw = e.watchElapsedMs;
      final maxMs = (settleSec + state.protocol.captureSec) * 1000;
      final elapsedMs = (raw != null && raw >= 0 && raw <= maxMs) ? raw : null;
      _phaseStart = elapsedMs != null
          ? DateTime.now().subtract(Duration(milliseconds: elapsedMs))
          : DateTime.now();
      _firstSampleTimeout?.cancel();
      _firstSampleTimeout = null;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      // Anteprima metriche ogni 5s (come nel training): RMSSD "live" mentre si
      // misura. È un preview, il valore definitivo è calcolato in `_finish`.
      _metricsTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _recomputeLive(),
      );
      _armStaleDataWatchdog();
      state = state.copyWith(waitingForWatch: false);
    } else {
      // Flusso vivo: rilancia il watchdog e azzera l'eventuale "connessione persa".
      _armStaleDataWatchdog();
      if (state.connectionLost) {
        state = state.copyWith(connectionLost: false);
      }
    }
    // Battiti in arrivo: il flusso è vivo → riabilita l'auto-recupero per un
    // eventuale stallo futuro.
    _healingRequested = false;
    final startedAt = _phaseStart!;
    final elapsed = DateTime.now().difference(startedAt).inSeconds;
    final bpm = e.bpm;
    // Trace HR sempre (anche in assestamento): riempie subito la curva e mostra
    // che il watch è connesso. Capped per non crescere indefinitamente.
    final trace = [
      ...state.hrTrace,
      HrTracePoint(timestamp: e.timestamp, bpm: bpm),
    ];
    final capped = trace.length > _maxTracePoints
        ? trace.sublist(trace.length - _maxTracePoints)
        : trace;
    // Raccogli RR solo DOPO l'assestamento.
    if (elapsed >= settleSec) {
      _window.add(e.toRr());
      state = state.copyWith(
        currentBpm: bpm,
        sampleCount: _window.length,
        hrTrace: capped,
      );
    } else {
      state = state.copyWith(currentBpm: bpm, hrTrace: capped);
    }
  }

  /// Anteprima metriche durante la cattura: ricalcola su TUTTO il window (la
  /// cattura è breve, ≤190s, niente rolling). Gate a ≥20 campioni come la
  /// `spectrum` di HrvCalculator; sotto soglia la UI mostra `--`.
  void _recomputeLive() {
    if (_window.length < 20) return;
    state = state.copyWith(liveMetrics: HrvCalculator.compute(_window));
  }

  Future<void> _finish() async {
    _timer?.cancel();
    _timer = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _firstSampleTimeout?.cancel();
    _firstSampleTimeout = null;
    _staleDataTimer?.cancel();
    _staleDataTimer = null;
    _sub?.cancel();
    _sub = null;
    final src = ref.read(heartRateSourceProvider);
    final metrics = HrvCalculator.compute(_window);
    // Passa SUBITO al riepilogo; il watch viene fermato in background.
    // L'handshake di stop (ACK ~3s + eventuale forceStop ~5s) non deve
    // ritardare di una decina di secondi la comparsa della review a 00:00.
    state = state.copyWith(phase: CheckInPhase.review, metrics: metrics);
    unawaited(src.stop());
  }

  /// Salva la lettura con il contesto raccolto. Ritorna l'id della sessione
  /// (o null se non c'erano metriche valide).
  Future<int?> save(MorningContext context) async {
    final metrics = state.metrics;
    if (metrics == null) return null;
    final now = DateTime.now();
    final started = _phaseStart ?? now;
    final session = Session(
      kind: SessionKind.reading,
      tag: SessionTag.morning,
      startedAt: started,
      endedAt: now,
      pattern: BreathingPattern.resonance6bpm, // placeholder: misura spontanea
      metrics: metrics,
      morning: MorningMeta(
        posture: state.posture,
        protocol: state.protocol,
        context: context,
      ),
    );
    final repo = ref.read(sessionRepositoryProvider);
    final id = await repo.saveSession(session, _window);

    // Refresh di tutto ciò che dipende dalle letture morning.
    ref.invalidate(sessionsListProvider);
    ref.invalidate(readinessProvider);
    // Nasconde subito la card-promemoria in home (check-in di oggi: fatto).
    ref.invalidate(morningCheckInDoneTodayProvider);
    ref.invalidate(morningReadingsProvider);
    ref.invalidate(readinessSectionProvider);
    ref.invalidate(readinessTrendProvider);

    state = state.copyWith(phase: CheckInPhase.saved, savedSessionId: id);
    return id;
  }

  /// Annulla una misura in corso e ferma la sorgente.
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _firstSampleTimeout?.cancel();
    _firstSampleTimeout = null;
    _staleDataTimer?.cancel();
    _staleDataTimer = null;
    _sub?.cancel();
    _sub = null;
    final wasMeasuring = state.phase == CheckInPhase.measuring;
    _window.clear();
    // Torna SUBITO a idle (così la schermata si chiude all'istante); il watch
    // viene fermato in background, senza far attendere l'utente l'handshake di
    // stop (~8s nel caso peggiore con fallback forceStop).
    state = MorningCheckInState(
      phase: CheckInPhase.idle,
      posture: state.posture,
      protocol: state.protocol,
    );
    if (wasMeasuring) {
      unawaited(ref.read(heartRateSourceProvider).stop());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _metricsTimer?.cancel();
    _firstSampleTimeout?.cancel();
    _staleDataTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

final morningCheckInControllerProvider =
    StateNotifierProvider.autoDispose<
      MorningCheckInController,
      MorningCheckInState
    >((ref) => MorningCheckInController(ref));
