import 'dart:async';

import '../hrv/breathing_pacer.dart';
import '../hrv/rr_interval.dart';
import 'remote_session_summary.dart';

/// Evento HR proveniente da una sorgente (watch Garmin, fascia BLE, mock).
class HeartRateEvent {
  final DateTime timestamp;
  final int bpm;

  /// RR interval (ms) associato a questo battito, se esposto dalla sorgente.
  /// Su Instinct Solar 2X via Connect IQ l'RR esatto non è sempre esposto;
  /// in quel caso `rr` viene derivato da `60000/bpm`.
  final int? rrMs;

  /// Millisecondi trascorsi dall'avvio della sessione sul watch al momento
  /// in cui questo battito è stato campionato. Esposto dalle sorgenti CIQ
  /// (cfr. payload HR_SAMPLE.elapsedMs); per fasce BLE/mock resta null.
  /// Serve a TrainingController per allineare il countdown del phone a
  /// quello del watch sul primo battito (il watch parte appena riceve
  /// START_SESSION, il phone riceve il primo HR sample 3-5 s dopo).
  final int? watchElapsedMs;

  const HeartRateEvent({
    required this.timestamp,
    required this.bpm,
    this.rrMs,
    this.watchElapsedMs,
  });

  RrInterval toRr() => RrInterval(
        timestamp: timestamp,
        ms: rrMs ?? (60000 ~/ bpm.clamp(30, 220)),
      );
}

/// Stato di connessione con la sorgente HR.
enum HrSourceState { disconnected, connecting, connected, error }

/// Astrazione per qualunque sorgente di battito cardiaco:
/// - Connect IQ (app Monkey C sull'Instinct Solar 2X)
/// - BLE diretto (fasce Polar, fallback)
/// - Mock (sviluppo senza hardware)
abstract class HeartRateSource {
  /// Descrizione user-friendly della sorgente.
  String get displayName;

  Stream<HrSourceState> get stateStream;
  HrSourceState get state;

  /// Stream di battiti. Su Connect IQ questo è alimentato dai messaggi
  /// `HR_SAMPLE` emessi dall'app sul watch.
  Stream<HeartRateEvent> get heartRateStream;

  /// Riepiloghi di sessioni avviate **dal watch** in modalità stand-alone
  /// (utente preme il tasto GPS sul Garmin senza usare il telefono).
  /// Sorgenti che non parlano con un watch ritornano uno stream vuoto.
  Stream<RemoteSessionSummary> get remoteSessionStream =>
      const Stream<RemoteSessionSummary>.empty();

  /// Avvia la sessione sul dispositivo (sull'Instinct Solar 2X chiede al
  /// watch di accendere il sensore HR e campionare ad alta frequenza).
  ///
  /// Se [pattern] e [targetDurationSec] sono forniti, vengono inoltrati al
  /// watch così che possa visualizzare timer + cerchio respiro localmente
  /// e generare feedback aptico al cambio fase, senza dipendere da
  /// messaggi BT continui dal telefono. Implementazioni che non parlano
  /// con un watch (es. mock) li ignorano.
  Future<void> start({BreathingPattern? pattern, int? targetDurationSec});

  /// Ferma la sessione.
  Future<void> stop();

  /// Richiede una misura HRV puntuale (l'Instinct Solar 2X non espone RR in
  /// stream continuo, ma restituisce una stima HRV se richiesta esplicitamente).
  /// Ritorna `null` se la sorgente non supporta questa operazione.
  Future<HrvOnDemandResult?> requestHrvOnDemand();

  /// Conferma al watch la ricezione di un `RemoteSessionSummary` con dato
  /// [startMs]. Il watch usa questo ack per svuotare il proprio
  /// PendingStore e smettere di ritrasmettere lo stesso summary.
  ///
  /// Default no-op per sorgenti che non hanno watch (mock, BLE diretto).
  Future<void> sendSummaryAck(int startMs) async {}

  /// Chiede al watch di drenare il PendingStore (SESSION_SUMMARY non
  /// confermati) ritrasmettendoli al phone.
  ///
  /// Serve per recuperare sessioni avviate dal polso quando l'app phone
  /// non era in foreground al momento dell'invio originale: Garmin
  /// Connect Mobile non bufferizza i messaggi se nessun listener è
  /// registrato in quel momento, quindi il summary resta orfano in
  /// Storage del watch finché qualcosa non scatena un flush.
  ///
  /// Se [force] è false (default) il sync è silenzioso (sendMessage
  /// diretto). Se l'app sul watch non è running il messaggio si perde,
  /// va bene per auto-sync ricorrenti.
  ///
  /// Se [force] è true, fa openApplication: sveglia l'app sul watch (può
  /// scatenare il dialog "Avviare HRV Trainer?"). Da usare solo quando
  /// l'utente preme esplicitamente un bottone "Sincronizza".
  ///
  /// Default no-op per sorgenti che non hanno watch.
  Future<void> requestSync({bool force = false}) async {}

  void dispose();
}

/// Risposta di una misura HRV "on demand" dal watch.
class HrvOnDemandResult {
  final DateTime takenAt;
  final int rmssdMs;
  final int sdnnMs;
  final List<int> rrWindowMs;

  const HrvOnDemandResult({
    required this.takenAt,
    required this.rmssdMs,
    required this.sdnnMs,
    required this.rrWindowMs,
  });

  factory HrvOnDemandResult.fromJson(Map<String, dynamic> j) =>
      HrvOnDemandResult(
        takenAt: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        rmssdMs: j['rmssd'] as int,
        sdnnMs: j['sdnn'] as int,
        rrWindowMs:
            (j['rr'] as List).map((e) => (e as num).toInt()).toList(),
      );
}
