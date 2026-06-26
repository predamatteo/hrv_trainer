import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/connect_iq/remote_session_summary.dart';

/// Simula l'overflow Int32 signed del watch: `Time.now().value() * 1000`
/// calcolato su due Number a 32 bit. Restituisce il valore garbled che
/// arrivava al telefono prima del fix firmware.
int int32SignedOverflow(int wholeMs) {
  const twoToThe32 = 4294967296;
  var raw = wholeMs % twoToThe32;
  if (raw >= 2147483648) raw -= twoToThe32;
  return raw;
}

/// Tronca al secondo intero (il watch parte da epoch in secondi).
int wholeSecMs(DateTime d) => (d.millisecondsSinceEpoch ~/ 1000) * 1000;

void main() {
  group('recoverFromInt32Overflow', () {
    test('recupera ESATTAMENTE un epoch recente andato in overflow Int32', () {
      // Sessione di 10 giorni fa (entro la finestra di ~49 giorni in cui il
      // recovery è univoco). 10 giorni < 2^32 ms quindi il candidato plausibile
      // più recente coincide col valore reale.
      final real = DateTime.now().subtract(const Duration(days: 10));
      final wholeMs = wholeSecMs(real);
      final garbled = int32SignedOverflow(wholeMs);

      final recovered = RemoteSessionSummary.recoverFromInt32Overflow(garbled);

      expect(recovered, isNotNull);
      expect(recovered!.millisecondsSinceEpoch, wholeMs);
    });

    test('il valore garbled di un epoch 2026 è negativo (firma del bug)', () {
      final wholeMs = wholeSecMs(DateTime(2026, 3, 15, 10, 30));
      expect(int32SignedOverflow(wholeMs), lessThan(0));
    });

    test('NON data più la sessione a inizio 2020 (regressione del fix)', () {
      // Prima del fix questo input tornava ~2020-01-29: ora deve tornare la
      // data reale recente, non il fondo della finestra plausibile.
      final real = DateTime.now().subtract(const Duration(days: 3));
      final recovered = RemoteSessionSummary.recoverFromInt32Overflow(
          int32SignedOverflow(wholeSecMs(real)));
      expect(recovered, isNotNull);
      expect(recovered!.year, real.year);
    });

    test('un valore già plausibile resta invariato (k=0)', () {
      final ms = DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch;
      final recovered = RemoteSessionSummary.recoverFromInt32Overflow(ms);
      expect(recovered!.millisecondsSinceEpoch, ms);
    });
  });

  group('pickStartedAt', () {
    test('preferisce startSec plausibile a startMs garbled', () {
      final real = DateTime.now().subtract(const Duration(days: 5));
      final startSec = real.millisecondsSinceEpoch ~/ 1000;

      final picked = RemoteSessionSummary.pickStartedAt(
        startMsRaw: -2117827840, // garbage
        startSec: startSec,
      );

      expect(picked.millisecondsSinceEpoch, startSec * 1000);
    });

    test('recupera da startMs in overflow quando startSec manca', () {
      final real = DateTime.now().subtract(const Duration(days: 7));
      final wholeMs = wholeSecMs(real);

      final picked = RemoteSessionSummary.pickStartedAt(
        startMsRaw: int32SignedOverflow(wholeMs),
        startSec: null,
      );

      expect(picked.millisecondsSinceEpoch, wholeMs);
    });

    test('senza startSec né startMs ripiega su ~adesso', () {
      final picked =
          RemoteSessionSummary.pickStartedAt(startMsRaw: null, startSec: null);
      expect(
        DateTime.now().difference(picked).inSeconds.abs(),
        lessThan(5),
      );
    });
  });

  group('pickEndedAt', () {
    test('non ritorna mai un istante precedente a startedAt', () {
      final startedAt = DateTime.now().subtract(const Duration(days: 5));
      // endSec plausibile ma PRIMA dello start → va ignorato, si usa durationMs.
      final endSec =
          startedAt.subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/
              1000;

      final ended = RemoteSessionSummary.pickEndedAt(
        startedAt: startedAt,
        endMsRaw: null,
        endSec: endSec,
        durationMs: 1200000, // 20 min
      );

      expect(ended.isBefore(startedAt), isFalse);
      expect(ended, startedAt.add(const Duration(milliseconds: 1200000)));
    });

    test('usa durationMs quando end mancante', () {
      final startedAt = DateTime.now().subtract(const Duration(days: 2));
      final ended = RemoteSessionSummary.pickEndedAt(
        startedAt: startedAt,
        endMsRaw: null,
        endSec: null,
        durationMs: 600000,
      );
      expect(ended, startedAt.add(const Duration(minutes: 10)));
    });

    test('preferisce endSec plausibile e successivo allo start', () {
      final startedAt = DateTime.now().subtract(const Duration(days: 2));
      final end = startedAt.add(const Duration(minutes: 20));
      final ended = RemoteSessionSummary.pickEndedAt(
        startedAt: startedAt,
        endMsRaw: null,
        endSec: end.millisecondsSinceEpoch ~/ 1000,
        durationMs: null,
      );
      expect(ended.millisecondsSinceEpoch,
          (end.millisecondsSinceEpoch ~/ 1000) * 1000);
    });
  });

  group('fromJson', () {
    test('sintetizza startMsRaw da startSec quando startMs manca', () {
      final startSec =
          DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/
              1000;
      final s = RemoteSessionSummary.fromJson({
        'startSec': startSec,
        'durationMs': 600000,
        'meanHr': 60,
        'rr': [800, 820],
      });
      // startMsRaw è la chiave del SUMMARY_ACK: deve restare ancorata al raw.
      expect(s.startMsRaw, startSec * 1000);
    });

    test('toRrIntervals fa il cumsum dei ms a partire da startedAt', () {
      final startSec =
          DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/
              1000;
      final s = RemoteSessionSummary.fromJson({
        'startSec': startSec,
        'rr': [800, 820, 790],
      });

      final rr = s.toRrIntervals();
      expect(rr.map((e) => e.ms).toList(), [800, 820, 790]);
      final base = s.startedAt;
      expect(rr[0].timestamp, base.add(const Duration(milliseconds: 800)));
      expect(rr[1].timestamp, base.add(const Duration(milliseconds: 1620)));
      expect(rr[2].timestamp, base.add(const Duration(milliseconds: 2410)));
    });
  });
}
