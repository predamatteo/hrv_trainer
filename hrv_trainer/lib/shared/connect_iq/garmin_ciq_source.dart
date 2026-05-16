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
        final phoneTxMs = (raw['phoneTxMs'] as num?)?.toInt();
        int? watchElapsedMs = elapsedRaw;
        if (elapsedRaw != null && phoneTxMs != null) {
          final roundTripMs = DateTime.now().millisecondsSinceEpoch - phoneTxMs;
          // Clamp >= 0 perché clock skew o jitter possono produrre stime
          // negative su round-trip molto piccoli. /2 perché il roundTrip
          // include sia send sia recv: assumiamo simmetria.
          final oneWayMs = ((roundTripMs - elapsedRaw) / 2)
              .round()
              .clamp(0, roundTripMs);
          watchElapsedMs = elapsedRaw + oneWayMs;
        }
        _hrController.add(HeartRateEvent(
          timestamp: DateTime.now(),
          bpm: (raw['bpm'] as num).toInt(),
          rrMs: (raw['rr'] as num?)?.toInt(),
          watchElapsedMs: watchElapsedMs,
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
        _setState(switch (v) {
          'READY' => HrSourceState.connected,
          'ACTIVE' => HrSourceState.connected,
          'ERROR' => HrSourceState.error,
          _ => HrSourceState.disconnected,
        });
      case 'SESSION_SUMMARY':
        _summaryController.add(
          RemoteSessionSummary.fromJson(Map<String, dynamic>.from(raw)),
        );
    }
  }

  @override
  Future<void> start({BreathingPattern? pattern, int? targetDurationSec}) async {
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
    try {
      await _channel.invokeMethod<void>('start', args);
    } on PlatformException {
      _setState(HrSourceState.error);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    // Stop di sessione != disconnessione BT col watch. Forzare
    // `disconnected` qui produceva il bug del badge "Disconnesso" persistente
    // dopo una sessione: se il watch aveva già auto-stoppato (countdown
    // locale), non rispondeva con `STATE: READY` (vedi HrvTrainerApp.requestStop)
    // e lo stato del phone restava bloccato finché l'utente non premeva
    // "Connetti". Manteniamo `connected` come stato post-stop "ottimistico":
    // se la connessione BT è davvero caduta lo aggiorneranno gli eventi
    // STATE/Device dal SDK Connect IQ.
    if (_state != HrSourceState.error) {
      _setState(HrSourceState.connected);
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
