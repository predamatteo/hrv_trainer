import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/history/history_screen.dart' show sessionsListProvider;
import '../../features/home/state/readiness_provider.dart';
import '../hrv/breathing_pacer.dart';
import '../hrv/hrv_metrics.dart';
import '../hrv/session_models.dart';
import '../storage/session_repository.dart';
import 'hr_source_provider.dart';
import 'remote_session_summary.dart';

/// Provider "always-on" che ascolta i SESSION_SUMMARY emessi dal watch
/// (sessioni avviate in stand-alone col tasto GPS) e li persiste come
/// `Session` complete in DB, ricalcolando le metriche con la pipeline
/// completa del telefono e invalidando lo storico per refresh UI.
///
/// Va "warm-up" all'avvio dell'app (es. con `ref.watch` in un Consumer
/// in cima al widget tree) altrimenti il listener non parte.
final remoteSessionPersisterProvider = Provider<RemoteSessionPersister>((ref) {
  final persister = RemoteSessionPersister(ref);
  ref.onDispose(persister.dispose);
  return persister;
});

class RemoteSessionPersister {
  static const _logTag = 'RemoteSessionPersister';

  final Ref _ref;
  StreamSubscription<RemoteSessionSummary>? _sub;

  RemoteSessionPersister(this._ref) {
    final src = _ref.read(heartRateSourceProvider);
    _sub = src.remoteSessionStream.listen(
      _onSummary,
      onError: (Object e, StackTrace st) {
        developer.log('summary stream error: $e',
            name: _logTag, error: e, stackTrace: st);
      },
    );

    // Migrazione one-shot al boot: ripara le sessioni con startedAt
    // garbled (pre-2020) salvate dal bug Time.now() overflow su Monkey C.
    // Idempotente — dopo che ha sistemato le righe, gira a vuoto.
    // L'invalidazione dei provider è necessaria perché può sbloccare
    // sessioni che prima non rientravano nella finestra di filtro.
    () async {
      try {
        final repo = _ref.read(sessionRepositoryProvider);
        final n = await repo.repairOverflowedSessionTimestamps();
        if (n > 0) {
          developer.log('repaired $n sessions with overflowed startedAt',
              name: _logTag);
          _ref.invalidate(sessionsListProvider);
          _ref.invalidate(readinessProvider);
        }
      } catch (e, st) {
        developer.log('timestamp repair failed: $e',
            name: _logTag, error: e, stackTrace: st);
      }
    }();

    // Sync iniziale ritardato: dà al bridge nativo il tempo di completare
    // l'init dell'SDK Connect IQ (onSdkReady può arrivare 1-2 s dopo) e di
    // popolare `device`. Silenzioso (force=false): se l'app sul watch non
    // è running il messaggio si perde, recuperabile col bottone manuale
    // in cronologia.
    Future<void>.delayed(const Duration(seconds: 2), () {
      developer.log('initial silent sync request', name: _logTag);
      src.requestSync();
    });
  }

  Future<void> _onSummary(RemoteSessionSummary s) async {
    // ACK al watch: usa il valore RAW di startMs (quello che il watch ha
    // come chiave nel PendingStore), non il timestamp recuperato. Se il
    // watch ha il PendingStore "sporcato" da firmware vecchio con overflow,
    // mandare un ack col timestamp recuperato non svuoterebbe la coda.
    final ackKey = s.startMsRaw;
    developer.log(
      'received SESSION_SUMMARY startMsRaw=$ackKey startedAt=${s.startedAt} '
      'samples=${s.samples} rrCount=${s.rrMs.length} meanHr=${s.meanHrBpm}',
      name: _logTag,
    );

    // Sanity check post-recovery: se anche dopo pickStartedAt() il timestamp
    // resta fuori range plausibile, significa che il watch ha mandato dati
    // troppo corrotti per essere recuperati (es. clock del watch resettato
    // a 1970 dopo cambio batteria). Salviamo comunque la sessione — i RR
    // hanno valore clinico anche se la data è approssimata — ma marchiamo
    // l'evento nei log così possiamo individuarla in caso di supporto.
    final now = DateTime.now();
    final ageDays = now.difference(s.startedAt).inDays;
    if (ageDays > 365 || ageDays < -1) {
      developer.log(
        'WARN startedAt fuori range plausibile (ageDays=$ageDays). '
        'Il watch ha trasmesso un timestamp non recuperabile; salvo comunque '
        'con startedAt=${s.startedAt} per evitare perdita dati.',
        name: _logTag,
      );
    }

    final repo = _ref.read(sessionRepositoryProvider);
    final src = _ref.read(heartRateSourceProvider);

    try {
      // Dedup: il watch ritrasmette lo stesso SESSION_SUMMARY ad ogni avvio
      // finché non riceve SUMMARY_ACK. Se la sessione è già a DB, saltiamo
      // l'insert ma confermiamo comunque al watch così smette di rispedirla.
      if (await repo.existsSessionStartedAt(s.startedAt)) {
        developer.log('dedup hit, sending ack only', name: _logTag);
        await src.sendSummaryAck(ackKey);
        return;
      }

      final rr = s.toRrIntervals();
      final metrics = rr.length >= 10
          ? HrvCalculator.compute(rr)
          : HrvMetrics.empty;
      final session = Session(
        kind: SessionKind.training,
        // Sessione partita dal polso senza scelta esplicita di tag dall'utente.
        tag: SessionTag.general,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        pattern: s.pattern ?? BreathingPattern.resonance6bpm,
        metrics: metrics,
        notes: 'Avviata dal watch',
      );
      final id = await repo.saveSession(session, rr);
      developer.log('saved session id=$id rrCount=${rr.length}', name: _logTag);

      _ref.invalidate(sessionsListProvider);
      _ref.invalidate(readinessProvider);

      // ACK al watch: solo dopo persist riuscito, così se qualcosa fallisce
      // qui il watch ritrasmetterà al prossimo flush.
      await src.sendSummaryAck(ackKey);
      developer.log('ack sent for ackKey=$ackKey', name: _logTag);
    } catch (e, st) {
      // Senza catch, un'eccezione qui propagherebbe sullo stream listener:
      // il summaryAck non partirebbe e il watch ritrasmetterebbe in loop
      // ad ogni flush, sempre fallendo per lo stesso motivo. Logghiamo
      // ma non rilanciamo: meglio accettare un retry pulito al prossimo
      // flush che bloccare la pipeline per sempre.
      developer.log('FAILED to persist summary ackKey=$ackKey',
          name: _logTag, error: e, stackTrace: st);
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
