import 'dart:async';

import 'package:flutter/services.dart';

import '../hrv/breathing_pacer.dart';
import 'heart_rate_source.dart';
import 'remote_session_summary.dart';

/// Sorgente HR che comunica con l'app Connect IQ sul Garmin Instinct Solar 2X
/// attraverso un MethodChannel nativo che wrappa il Connect IQ Mobile SDK
/// (Android: Java lib, iOS: Obj-C lib fornite da Garmin).
///
/// Protocollo messaggi (JSON) fra app CIQ e telefono:
/// ```
/// App -> Watch:  {"type":"START_SESSION", "hz":4}
/// App -> Watch:  {"type":"REQUEST_HRV"}
/// App -> Watch:  {"type":"STOP_SESSION"}
///
/// Watch -> App:  {"type":"HR_SAMPLE", "t":<unixMs>, "bpm":<int>, "rr":<int?>}
/// Watch -> App:  {"type":"HRV_RESULT", "t":<unixMs>, "rmssd":<int>, "sdnn":<int>, "rr":[...]}
/// Watch -> App:  {"type":"STATE", "v":"READY|ACTIVE|ERROR", "msg":"..."}
/// ```
class GarminCiqSource implements HeartRateSource {
  static const _channel = MethodChannel('dev.hrv/garmin_ciq');
  static const _events = EventChannel('dev.hrv/garmin_ciq_events');

  final _hrController = StreamController<HeartRateEvent>.broadcast();
  final _stateController = StreamController<HrSourceState>.broadcast();
  final _summaryController =
      StreamController<RemoteSessionSummary>.broadcast();
  final Map<int, Completer<HrvOnDemandResult?>> _pendingHrv = {};
  int _nextHrvReq = 1;

  // Handshake di stop: armato in stop(), completato quando arriva un evento
  // STATE con `stopped:true` dal watch. Permette di capire se lo STOP è stato
  // davvero consegnato e, in caso contrario, ricadere su forceStop.
  Completer<bool>? _pendingStopAck;

  StreamSubscription? _eventSub;
  HrSourceState _state = HrSourceState.disconnected;

  GarminCiqSource() {
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent,
        onError: (Object e) => _setState(HrSourceState.error));
  }

  @override
  String get displayName => 'Garmin (Connect IQ)';

  @override
  HrSourceState get state => _state;

  @override
  Stream<HrSourceState> get stateStream => _stateController.stream;

  @override
  Stream<HeartRateEvent> get heartRateStream => _hrController.stream;

  @override
  Stream<RemoteSessionSummary> get remoteSessionStream =>
      _summaryController.stream;

  void _setState(HrSourceState s) {
    _state = s;
    _stateController.add(s);
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    switch (type) {
      case 'HR_SAMPLE':
        // Timestamp di arrivo lato phone, NON `raw['t']` dal watch:
        // l'Instinct Solar 2X può avere clock skew di minuti rispetto al
        // telefono (sync solo via GPS/BT). Qualsiasi finestra rolling lato
        // phone basata sul timestamp watch finiva per scartare tutti i
        // sample, lasciando state.samples vuoto e metriche a 0.
        // `elapsedMs` invece è un delta relativo (Sys.getTimer() - mStartMs)
        // immune dal clock skew: lo usiamo solo per allineare l'avvio del
        // countdown phone↔watch sul primo battito.
        //
        // `phoneTxMs` è l'epoch ms in coordinate phone iniettato dal bridge
        // Kotlin SUBITO PRIMA di sendMessage: il watch lo restituisce tale
        // quale. Permette di stimare la latenza BT one-way (δ) e correggere
        // il residuo: roundTrip = now - phoneTxMs include 2*δ + processing
        // sul watch (= elapsedMs), quindi δ ≈ (roundTrip - elapsedMs) / 2.
        // Aggiungendo δ a watchElapsedMs, t0 = now - watchElapsedMs allinea
        // il phone esattamente a mStartMs del watch (in coordinate phone).
        final elapsedRaw = (raw['elapsedMs'] as num?)?.toInt();
        // pacerMs: tempo di SESSIONE del watch (elapsed meno la prep). Presente
        // solo sui firmware con prep coordinata; se assente il phone ricade sul
        // comportamento senza preparazione.
        final pacerRaw = (raw['pacerMs'] as num?)?.toInt();
        final phoneTxMs = (raw['phoneTxMs'] as num?)?.toInt();
        int? oneWayMs;
        if (elapsedRaw != null && phoneTxMs != null) {
          final roundTripMs = DateTime.now().millisecondsSinceEpoch - phoneTxMs;
          // Clamp >= 0 perché clock skew o jitter possono produrre stime
          // negative su round-trip molto piccoli. /2 perché il roundTrip
          // include sia send sia recv: assumiamo simmetria.
          oneWayMs = ((roundTripMs - elapsedRaw) / 2).round().clamp(
                0,
                roundTripMs,
              );
        }
        final watchElapsedMs = (elapsedRaw != null && oneWayMs != null)
            ? elapsedRaw + oneWayMs
            : elapsedRaw;
        // Stessa correzione one-way su pacerMs (è il tempo di sessione "ad
        // adesso" in coordinate phone).
        final watchPacerMs = (pacerRaw != null && oneWayMs != null)
            ? pacerRaw + oneWayMs
            : pacerRaw;
        _hrController.add(HeartRateEvent(
          timestamp: DateTime.now(),
          bpm: (raw['bpm'] as num).toInt(),
          rrMs: (raw['rr'] as num?)?.toInt(),
          watchElapsedMs: watchElapsedMs,
          watchPacerMs: watchPacerMs,
        ));
      case 'HRV_RESULT':
        final reqId = raw['reqId'] as int?;
        final result = HrvOnDemandResult.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (reqId != null && _pendingHrv.containsKey(reqId)) {
          _pendingHrv.remove(reqId)!.complete(result);
        }
      case 'STATE':
        final v = raw['v'] as String?;
        // ACK di stop dal watch (READY con stopped:true): chiude l'handshake
        // così non scatta il fallback forceStop.
        if (raw['stopped'] == true) {
          final c = _pendingStopAck;
          if (c != null && !c.isCompleted) c.complete(true);
        }
        // Mapping stato. CRITICO: il default NON deve forzare `disconnected`.
        // Prima i nomi enum device grezzi (CONNECTED/NOT_CONNECTED/UNKNOWN)
        // cadevano tutti nel default → "Disconnesso" anche su un device appena
        // CONNESSO. Ora il bridge Kotlin traduce in DEVICE_CONNECTED /
        // DEVICE_DISCONNECTED e qui ogni token sconosciuto/transitorio mantiene
        // lo stato corrente.
        switch (v) {
          case 'READY':
          case 'ACTIVE':
          case 'DEVICE_CONNECTED':
            _setState(HrSourceState.connected);
          case 'ERROR':
            _setState(HrSourceState.error);
          case 'NO_DEVICE':
            _setState(HrSourceState.noDevice);
          case 'DISCONNECTED':
          case 'DEVICE_DISCONNECTED':
            _setState(HrSourceState.disconnected);
          case null:
            break; // payload malformato: ignora
          default:
            // Token transitorio (es. UNKNOWN): keep-current, non disconnettere.
            break;
        }
      case 'SESSION_SUMMARY':
        _summaryController.add(
          RemoteSessionSummary.fromJson(Map<String, dynamic>.from(raw)),
        );
    }
  }

  @override
  Future<void> start({
    BreathingPattern? pattern,
    int? targetDurationSec,
    int? prepMs,
  }) async {
    _setState(HrSourceState.connecting);
    final args = <String, Object?>{'hz': 4};
    if (pattern != null) {
      args['inhaleMs'] = (pattern.inhaleSec * 1000).round();
      args['exhaleMs'] = (pattern.exhaleSec * 1000).round();
      args['hold1Ms'] = (pattern.hold1Sec * 1000).round();
      args['hold2Ms'] = (pattern.hold2Sec * 1000).round();
    }
    if (targetDurationSec != null) {
      args['durationSec'] = targetDurationSec;
    }
    // prepMs: fase silenziosa iniziale lato watch (vedi HrvTrainerView).
    // Watch più vecchi senza supporto prep ignorano il campo: in quel caso il
    // telefono ricade sul comportamento corrente (nessun pacerMs → orb agganciato
    // a watchElapsedMs, vista d'attesa fino al primo battito).
    if (prepMs != null && prepMs > 0) {
      args['prepMs'] = prepMs;
    }
    try {
      await _channel.invokeMethod<void>('start', args);
    } on PlatformException {
      _setState(HrSourceState.error);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    // 1) Stop "leggero": sendMessage diretto (niente openApplication → niente
    //    dialog "Avviare?"). Va a segno quando l'app sul watch è in foreground.
    //    Armiamo l'ack PRIMA di inviare per non perdere una risposta velocissima.
    final ack1 = _armStopAck(const Duration(seconds: 3));
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // anche se il MethodChannel fallisce, proviamo comunque il fallback sotto.
    }

    // 2) Handshake: se non arriva STATE:READY(stopped) entro la finestra, l'app
    //    sul watch era probabilmente tornata al watchface e lo STOP diretto si
    //    è perso → "l'orologio continua ad andare". Ricadiamo su forceStop
    //    (openApplication-backed): riporta l'app in foreground e consegna lo STOP.
    final acked = await ack1;
    if (!acked) {
      final ack2 = _armStopAck(const Duration(seconds: 5));
      try {
        await _channel.invokeMethod<void>('forceStop');
      } on PlatformException {
        // best-effort: niente altro da tentare.
      }
      await ack2;
    }

    // Fermare la sessione != perdere il link BT. Se eravamo connessi restiamo
    // connessi (gli eventi device reali — ora mappati correttamente — ci
    // correggeranno se il link è davvero caduto). Non fabbrichiamo però una
    // connessione dal nulla se eravamo disconnected/noDevice/error.
    if (_state == HrSourceState.connected ||
        _state == HrSourceState.connecting) {
      _setState(HrSourceState.connected);
    }
  }

  /// Arma un completer per l'ACK di stop e ne ritorna il future con timeout.
  /// Sostituisce un eventuale ack precedente; al termine si auto-ripulisce.
  Future<bool> _armStopAck(Duration timeout) {
    final c = Completer<bool>();
    _pendingStopAck = c;
    return c.future.timeout(timeout, onTimeout: () => false).whenComplete(() {
      if (identical(_pendingStopAck, c)) _pendingStopAck = null;
    });
  }

  @override
  Future<void> reconnect() async {
    // Non sbiancare lo stato se siamo già connessi: il refresh ri-emetterà
    // comunque lo STATE reale del device. Mostriamo "connecting" solo se
    // eravamo giù, così "Connetti"/"Riconnetti" dà feedback immediato.
    if (_state != HrSourceState.connected) {
      _setState(HrSourceState.connecting);
    }
    try {
      await _channel.invokeMethod<void>('reconnect');
    } on PlatformException {
      _setState(HrSourceState.error);
    }
  }

  @override
  Future<HrvOnDemandResult?> requestHrvOnDemand() async {
    final reqId = _nextHrvReq++;
    final completer = Completer<HrvOnDemandResult?>();
    _pendingHrv[reqId] = completer;

    try {
      await _channel
          .invokeMethod<void>('requestHrv', {'reqId': reqId});
    } on PlatformException {
      _pendingHrv.remove(reqId);
      return null;
    }

    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _pendingHrv.remove(reqId);
        return null;
      },
    );
  }

  @override
  Future<void> sendSummaryAck(int startMs) async {
    try {
      await _channel
          .invokeMethod<void>('summaryAck', {'startMs': startMs});
    } on PlatformException {
      // Best-effort: se l'ACK non parte (es. BT giù) il watch ritrasmetterà
      // il summary al prossimo avvio e ritenteremo l'ACK allora.
    }
  }

  @override
  Future<void> requestSync({bool force = false}) async {
    try {
      await _channel.invokeMethod<void>('requestSync', {'force': force});
    } on PlatformException {
      // Best-effort: il sync è sempre opzionale. Fallisce silenziosamente
      // se il bridge non è pronto o il device non è disponibile — alla
      // prossima richiesta riproveremo.
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _hrController.close();
    _stateController.close();
    _summaryController.close();
  }
}
