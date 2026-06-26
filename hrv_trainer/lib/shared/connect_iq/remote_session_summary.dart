import '../hrv/breathing_pacer.dart';
import '../hrv/rr_interval.dart';

/// Riepilogo di una sessione **avviata dal watch in modalità stand-alone**
/// e ricevuta dal telefono al termine come messaggio `SESSION_SUMMARY`.
///
/// Il watch invia metriche aggregate + l'array completo dei RR interval (in
/// ms). Il telefono ricostruisce i timestamp per beat (cumsum a partire da
/// [startedAt]) e ricalcola le metriche complete con la propria pipeline
/// (artifact correction, frequency-domain, Poincaré).
class RemoteSessionSummary {
  final DateTime startedAt;
  final DateTime endedAt;
  final int meanHrBpm;
  final int sdnnMs;
  final int rmssdMs;
  final int samples;
  final List<int> rrMs;
  final BreathingPattern? pattern;

  /// Valore RAW di `startMs` come ricevuto dal watch, PRIMA di eventuale
  /// recovery dall'overflow Int32. Serve per il `SUMMARY_ACK`: il watch usa
  /// questo valore come chiave nel PendingStore, quindi l'ack deve matchare
  /// l'originale anche se garbled. Mandare l'ack col timestamp recuperato
  /// non svuoterebbe il PendingStore e il watch continuerebbe a
  /// ritrasmettere lo stesso summary ad ogni flush.
  final int startMsRaw;

  const RemoteSessionSummary({
    required this.startedAt,
    required this.endedAt,
    required this.meanHrBpm,
    required this.sdnnMs,
    required this.rmssdMs,
    required this.samples,
    required this.rrMs,
    required this.startMsRaw,
    this.pattern,
  });

  factory RemoteSessionSummary.fromJson(Map<String, dynamic> j) {
    BreathingPattern? pattern;
    final iMs = j['inhaleMs'] as int?;
    final eMs = j['exhaleMs'] as int?;
    if (iMs != null && eMs != null) {
      pattern = BreathingPattern(
        inhaleSec: iMs / 1000.0,
        hold1Sec: ((j['hold1Ms'] as int?) ?? 0) / 1000.0,
        exhaleSec: eMs / 1000.0,
        hold2Sec: ((j['hold2Ms'] as int?) ?? 0) / 1000.0,
      );
    }

    final startMsRaw = (j['startMs'] as num?)?.toInt();
    final endMsRaw = (j['endMs'] as num?)?.toInt();
    final startSec = (j['startSec'] as num?)?.toInt();
    final endSec = (j['endSec'] as num?)?.toInt();
    final durationMs = (j['durationMs'] as num?)?.toInt();

    final startedAt = pickStartedAt(
      startMsRaw: startMsRaw,
      startSec: startSec,
    );
    final endedAt = pickEndedAt(
      startedAt: startedAt,
      endMsRaw: endMsRaw,
      endSec: endSec,
      durationMs: durationMs,
    );

    return RemoteSessionSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      meanHrBpm: (j['meanHr'] as num?)?.toInt() ?? 0,
      sdnnMs: (j['sdnn'] as num?)?.toInt() ?? 0,
      rmssdMs: (j['rmssd'] as num?)?.toInt() ?? 0,
      samples: (j['samples'] as num?)?.toInt() ?? 0,
      rrMs: ((j['rr'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
      pattern: pattern,
      // Se manca startMs ma c'è startSec, sintetizziamo il raw così l'ack
      // ha comunque una chiave da mandare al watch. Il match avverrà
      // sulla coppia che il watch ha effettivamente in PendingStore.
      startMsRaw: startMsRaw ?? (startSec != null ? startSec * 1000 : 0),
    );
  }

  /// Ricostruisce gli RR interval con timestamp per beat (cumsum dei ms a
  /// partire da [startedAt]). Necessario per `SessionRepository.saveSession`.
  List<RrInterval> toRrIntervals() {
    var t = startedAt;
    return [
      for (final ms in rrMs)
        RrInterval(
          timestamp: (t = t.add(Duration(milliseconds: ms))),
          ms: ms,
        ),
    ];
  }

  // === Recovery timestamp ===================================================
  //
  // Bug storico (fixato 2026-05-15): il watch calcolava
  // `mStartEpochMs = Time.now().value() * 1000` in Monkey C. Entrambi gli
  // operandi sono Number (Int32 signed), quindi la moltiplicazione overflowa
  // silenziosamente nel 2026 (~1.76e12 vs Int32 max ~2.15e9). Risultato: i
  // SESSION_SUMMARY arrivavano al phone con startMs garbled (~-2.0e9 oggi)
  // e venivano salvati con startedAt ~ gennaio 1906, invisibili nello storico.
  //
  // Fix definitivo nel firmware del watch: forza il calcolo a Long. Ma i
  // summary già nel PendingStore del watch (creati prima dell'update) e le
  // sessioni già nel DB del phone con timestamp garbled vanno comunque
  // recuperati. La logica qui sotto fa entrambe le cose, ed è esposta come
  // funzione pura (statica) così la migrazione DB può riusarla.

  /// Range plausibile per uno startedAt: dal 2020 al "oggi + 1 giorno" per
  /// tollerare clock skew. Una sessione fuori da questo range è quasi
  /// certamente un artefatto di overflow / clock errato.
  static final DateTime _minPlausible = DateTime(2020, 1, 1);

  static bool _isPlausible(DateTime t) {
    final maxPlausible = DateTime.now().add(const Duration(days: 1));
    return t.isAfter(_minPlausible) && t.isBefore(maxPlausible);
  }

  /// Sceglie il `startedAt` migliore fra `startSec` e `startMs`,
  /// preferendo quello plausibile. Se entrambi sono garbled tenta il
  /// recovery dall'overflow Int32 su `startMs`.
  ///
  /// Esposto come API pubblica perché serve sia al parsing dei
  /// SESSION_SUMMARY sia alla migrazione DB delle sessioni già salvate
  /// con timestamp errato.
  static DateTime pickStartedAt({
    required int? startMsRaw,
    required int? startSec,
  }) {
    if (startSec != null && startSec > 0) {
      final fromSec =
          DateTime.fromMillisecondsSinceEpoch(startSec * 1000, isUtc: false);
      if (_isPlausible(fromSec)) return fromSec;
    }
    if (startMsRaw != null) {
      final fromMs =
          DateTime.fromMillisecondsSinceEpoch(startMsRaw, isUtc: false);
      if (_isPlausible(fromMs)) return fromMs;
      // Tentativo di recovery dall'overflow Int32.
      final recovered = recoverFromInt32Overflow(startMsRaw);
      if (recovered != null) return recovered;
    }
    // Ultimo fallback: ora corrente. Non perdiamo del tutto la sessione
    // ma marchiamo che il timestamp è stato sintetizzato. Il caller può
    // decidere se salvarla o scartarla.
    return DateTime.now();
  }

  static DateTime pickEndedAt({
    required DateTime startedAt,
    required int? endMsRaw,
    required int? endSec,
    required int? durationMs,
  }) {
    if (endSec != null && endSec > 0) {
      final fromSec =
          DateTime.fromMillisecondsSinceEpoch(endSec * 1000, isUtc: false);
      if (_isPlausible(fromSec) && !fromSec.isBefore(startedAt)) {
        return fromSec;
      }
    }
    if (endMsRaw != null) {
      final fromMs =
          DateTime.fromMillisecondsSinceEpoch(endMsRaw, isUtc: false);
      if (_isPlausible(fromMs) && !fromMs.isBefore(startedAt)) {
        return fromMs;
      }
      final recovered = recoverFromInt32Overflow(endMsRaw);
      if (recovered != null && !recovered.isBefore(startedAt)) return recovered;
    }
    // Fallback: startedAt + durationMs se noto, altrimenti uguale a startedAt.
    if (durationMs != null && durationMs > 0) {
      return startedAt.add(Duration(milliseconds: durationMs));
    }
    return startedAt;
  }

  /// Inverso dell'overflow Int32 modulare per un valore epoch-ms.
  ///
  /// Se il watch ha calcolato `seconds * 1000` in Number (Int32 signed) e
  /// il risultato è andato in overflow, il valore ricevuto è
  /// `(real_ms) mod 2^32` reinterpretato signed. Per recuperare il valore
  /// reale aggiungiamo `k * 2^32` per il `k` che porta il risultato dentro
  /// `[_minPlausible, now+1day]`.
  ///
  /// Ritorna null se nessun `k` produce un valore plausibile (es. perché
  /// il garbage non viene dall'overflow Int32 di un epoch reale).
  static DateTime? recoverFromInt32Overflow(int garbledMs) {
    // Reinterpretazione del valore Int32 signed come unsigned-equivalente:
    // se garbledMs è positivo già è in [0, 2^32), se è negativo aggiungo 2^32
    // per ottenere la rappresentazione "raw" che il watch ha scritto.
    const twoToThe32 = 4294967296;
    var raw = garbledMs;
    if (raw < 0) raw += twoToThe32;

    final maxPlausibleMs =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    final minPlausibleMs = _minPlausible.millisecondsSinceEpoch;

    // L'overflow perde l'informazione oltre il modulo 2^32 ms (~49.7 giorni):
    // dentro la finestra plausibile [2020, oggi+1g] (larga ~47 wrap) cadono
    // PIÙ candidati `raw + k*2^32`, tutti indistinguibili dal solo valore
    // garbled. Una sessione reale è però sempre nel passato e tipicamente
    // recente, quindi scegliamo il candidato plausibile più RECENTE (il k
    // massimo che non supera oggi+1g): è esatto per le sessioni recuperate
    // entro ~49 giorni dalla loro creazione. La versione precedente ritornava
    // il candidato più VECCHIO, datando ogni sessione recuperata a inizio 2020.
    // Limite residuo: una sessione più vecchia di ~49 giorni al momento del
    // recovery viene sovrastimata di multipli di ~49.7 giorni (irrisolvibile
    // senza altre info — per questo `pickStartedAt` preferisce `startSec`, che
    // non va in overflow).
    DateTime? best;
    for (var k = 0; k < 2000; k++) {
      final candidate = raw + k * twoToThe32;
      if (candidate > maxPlausibleMs) break;
      if (candidate >= minPlausibleMs) {
        best = DateTime.fromMillisecondsSinceEpoch(candidate, isUtc: false);
      }
    }
    return best;
  }
}
