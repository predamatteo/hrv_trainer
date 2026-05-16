import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../connect_iq/remote_session_summary.dart';
import '../hrv/breathing_pacer.dart';
import '../hrv/hrv_metrics.dart';
import '../hrv/rr_interval.dart';
import '../hrv/session_models.dart';
import 'database.dart';

class SessionRepository {
  Future<Database> get _db async => AppDatabase.instance();

  Future<int> saveSession(Session s, List<RrInterval> samples) async {
    final db = await _db;
    return db.transaction((txn) async {
      final id = await txn.insert('sessions', {
        'kind': s.kind.name,
        'tag': s.tag.name,
        'started_at': s.startedAt.millisecondsSinceEpoch,
        'ended_at': s.endedAt?.millisecondsSinceEpoch,
        'pattern_json': jsonEncode(s.pattern.toJson()),
        'metrics_json': jsonEncode(s.metrics.toJson()),
        'notes': s.notes,
      });
      final batch = txn.batch();
      for (final rr in samples) {
        batch.insert('rr_samples', {
          'session_id': id,
          't': rr.timestamp.millisecondsSinceEpoch,
          'ms': rr.ms,
        });
      }
      await batch.commit(noResult: true);
      return id;
    });
  }

  /// Cerca sessioni con `started_at` palesemente errato (pre-2020) e tenta
  /// di ricostruire il timestamp corretto invertendo l'overflow Int32 del
  /// watch (vedi `RemoteSessionSummary.recoverFromInt32Overflow`).
  ///
  /// Storia: dal lancio dell'app fino al 2026-05-15, il watch calcolava
  /// `Time.now().value() * 1000` in Monkey C su due Number Int32. La
  /// moltiplicazione overflowava silenziosamente nel 2026 e il
  /// SESSION_SUMMARY arrivava con `startMs` garbled (≈ -2.0e9), salvato
  /// nel DB e mostrato come sessione del 1906. Lo storico filtra per
  /// ultimi 30 giorni → le sessioni risultavano "perse" all'utente.
  ///
  /// Idempotente: dopo una run, le sessioni recuperabili sono già state
  /// corrette, le righe rimanenti < 2020 sono quelle che il recovery
  /// non è riuscito a sistemare (es. data parziale, mai successo perché
  /// il watch già fixed manda startSec corretto). Ritorna il numero di
  /// righe corrette in questa esecuzione.
  Future<int> repairOverflowedSessionTimestamps() async {
    final db = await _db;
    // Threshold = 2020-01-01 epoch ms. Tutte le sessioni HRV Trainer reali
    // sono successive al 2026 (data di lancio dell'app), quindi qualsiasi
    // riga sotto questa soglia è certamente un artefatto.
    const threshold = 1577836800000;
    final candidates = await db.query(
      'sessions',
      columns: ['id', 'started_at', 'ended_at'],
      where: 'started_at < ?',
      whereArgs: [threshold],
    );
    if (candidates.isEmpty) return 0;

    var fixed = 0;
    for (final row in candidates) {
      final id = row['id'] as int;
      final oldStarted = row['started_at'] as int;
      final oldEnded = row['ended_at'] as int?;

      final recovered =
          RemoteSessionSummary.recoverFromInt32Overflow(oldStarted);
      if (recovered == null) continue;

      // Sposta tutto del delta: started_at, ended_at, e i timestamp dei RR
      // samples (che sono cumsum a partire da started_at). Senza spostare
      // anche i RR la sessione si "spezza" in DB: header al 2026 ma campioni
      // ancorati al 1906 — la UI Tachogram ricalcola elapsedSec = t - startedAt
      // e otterrebbe valori giganti negativi.
      final delta = recovered.millisecondsSinceEpoch - oldStarted;
      final newEnded = oldEnded != null ? oldEnded + delta : null;

      await db.transaction((txn) async {
        await txn.update(
          'sessions',
          {
            'started_at': recovered.millisecondsSinceEpoch,
            'ended_at': ?newEnded,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await txn.rawUpdate(
          'UPDATE rr_samples SET t = t + ? WHERE session_id = ?',
          [delta, id],
        );
      });
      fixed++;
    }
    return fixed;
  }

  /// Verifica se esiste già una sessione iniziata a [startedAt]. Usato per
  /// dedup quando il watch ritrasmette lo stesso `SESSION_SUMMARY` perché
  /// l'app non ha ancora confermato con `SUMMARY_ACK`.
  Future<bool> existsSessionStartedAt(DateTime startedAt) async {
    final db = await _db;
    final rows = await db.query(
      'sessions',
      columns: ['id'],
      where: 'started_at = ?',
      whereArgs: [startedAt.millisecondsSinceEpoch],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<Session?> getSession(int id) async {
    final db = await _db;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _rowToSession(rows.first);
  }

  Future<List<RrInterval>> getSessionRrSamples(int id) async {
    final db = await _db;
    final rows = await db.query(
      'rr_samples',
      where: 'session_id = ?',
      whereArgs: [id],
      orderBy: 't ASC',
    );
    return [
      for (final r in rows)
        RrInterval(
          timestamp: DateTime.fromMillisecondsSinceEpoch(r['t'] as int),
          ms: r['ms'] as int,
        ),
    ];
  }

  /// Cancella sessione e i suoi RR samples in transazione.
  /// Non si affida alla CASCADE perché sqflite non abilita di default i FK.
  Future<void> deleteSession(int id) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('rr_samples', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Session>> listSessions({
    int limit = 50,
    SessionTag? tag,
    DateTime? since,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (tag != null) {
      where.add('tag = ?');
      args.add(tag.name);
    }
    if (since != null) {
      where.add('started_at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    final rows = await db.query(
      'sessions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(_rowToSession).toList();
  }

  Session _rowToSession(Map<String, Object?> row) {
    final tagName = row['tag'] as String? ?? 'general';
    return Session(
      id: row['id'] as int,
      kind: SessionKind.values.firstWhere((k) => k.name == row['kind']),
      tag: SessionTag.values
          .firstWhere((t) => t.name == tagName, orElse: () => SessionTag.general),
      startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
      endedAt: row['ended_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['ended_at'] as int),
      pattern: BreathingPattern.fromJson(
        jsonDecode(row['pattern_json'] as String) as Map<String, dynamic>,
      ),
      metrics: HrvMetrics.fromJson(
        jsonDecode(row['metrics_json'] as String) as Map<String, dynamic>,
      ),
      notes: row['notes'] as String?,
    );
  }

  Future<int> saveAssessment(ResonanceAssessment a) async {
    final db = await _db;
    final stepsJson = a.steps
        .map((s) => {
              'bpm': s.bpm,
              'durMs': s.duration.inMilliseconds,
              'metrics': s.metrics.toJson(),
            })
        .toList();
    return db.insert('assessments', {
      'taken_at': a.takenAt.millisecondsSinceEpoch,
      'resonance_bpm': a.resonanceBpm,
      'rationale': a.rationale,
      'steps_json': jsonEncode(stepsJson),
    });
  }

  Future<double?> latestResonanceBpm() async {
    final db = await _db;
    final rows = await db.query(
      'assessments',
      columns: ['resonance_bpm'],
      orderBy: 'taken_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['resonance_bpm'] as double?;
  }

  /// Schema corrente del file di backup. Bumppare ad ogni breaking change
  /// del formato (rinomina campi DB, rimozione enum value, ecc.).
  static const exportSchemaVersion = 1;

  /// Serializza l'intero storico (sessioni + RR samples + assessments) in
  /// JSON pronto per condivisione tramite share sheet.
  ///
  /// Formato auto-contenuto: ogni sessione include la sua `pattern_json` e
  /// `metrics_json` già serializzati lato persistenza, più la lista degli
  /// `rr_samples`. Gli assessment includono lo `steps_json` originale. Non
  /// dipende dalla versione di Dart/Flutter né dal device — è importabile
  /// in qualunque installazione futura della stessa app.
  Future<Map<String, dynamic>> exportAll() async {
    final db = await _db;
    final sessRows = await db.query('sessions', orderBy: 'started_at ASC');
    // RR caricati in batch per ridurre round-trip su sqflite. Una query per
    // sessione costerebbe N+1; questa è O(1) in numero di query.
    final rrRows = await db.query('rr_samples', orderBy: 'session_id, t ASC');
    final rrBySession = <int, List<Map<String, Object?>>>{};
    for (final r in rrRows) {
      final sid = r['session_id'] as int;
      (rrBySession[sid] ??= []).add({'t': r['t'], 'ms': r['ms']});
    }

    final assRows = await db.query('assessments', orderBy: 'taken_at ASC');

    final sessions = sessRows.map((s) {
      final id = s['id'] as int;
      return {
        'kind': s['kind'],
        'tag': s['tag'],
        'startedAt': s['started_at'],
        'endedAt': s['ended_at'],
        // Salviamo le stringhe JSON così come sono nel DB: il formato è già
        // stabile (BreathingPattern.toJson / HrvMetrics.toJson). Re-parse
        // sarebbe lavoro inutile e fonte di drift se i toJson cambiassero.
        'patternJson': s['pattern_json'],
        'metricsJson': s['metrics_json'],
        'notes': s['notes'],
        'rrSamples': rrBySession[id] ?? const <Map<String, Object?>>[],
      };
    }).toList();

    final assessments = assRows.map((a) => {
          'takenAt': a['taken_at'],
          'resonanceBpm': a['resonance_bpm'],
          'rationale': a['rationale'],
          'stepsJson': a['steps_json'],
        }).toList();

    return {
      'schemaVersion': exportSchemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'sessions': sessions,
      'assessments': assessments,
    };
  }

  /// Esito di un import: quanti record nuovi e quanti scartati per dedup.
  /// `error` non null se il JSON è invalido o di schema sconosciuto.
  /// Niente eccezioni propagate al chiamante per non doverlo wrappare in
  /// try/catch in UI: l'errore è un dato come gli altri.
  Future<ImportResult> importAll(Map<String, dynamic> data) async {
    final v = data['schemaVersion'];
    if (v is! int) {
      return const ImportResult(error: 'Schema mancante o non valido.');
    }
    if (v > exportSchemaVersion) {
      return ImportResult(
          error: 'File creato con versione più nuova ($v). '
              'Aggiorna l\'app prima di importare.');
    }

    final sessions = (data['sessions'] as List?) ?? const [];
    final assessments = (data['assessments'] as List?) ?? const [];

    var sessImported = 0;
    var sessSkipped = 0;
    var assImported = 0;
    var assSkipped = 0;

    final db = await _db;
    await db.transaction((txn) async {
      for (final raw in sessions) {
        final s = raw as Map<String, dynamic>;
        final startedAt = s['startedAt'] as int;
        // Dedup su startedAt: chiave naturale di una sessione (un utente non
        // ne avvia due nello stesso ms). Stesso criterio di
        // existsSessionStartedAt() per coerenza con il flusso watch.
        final dup = await txn.query(
          'sessions',
          columns: ['id'],
          where: 'started_at = ?',
          whereArgs: [startedAt],
          limit: 1,
        );
        if (dup.isNotEmpty) {
          sessSkipped++;
          continue;
        }

        final id = await txn.insert('sessions', {
          'kind': s['kind'],
          'tag': s['tag'] ?? 'general',
          'started_at': startedAt,
          'ended_at': s['endedAt'],
          'pattern_json': s['patternJson'],
          'metrics_json': s['metricsJson'],
          'notes': s['notes'],
        });

        final rr = (s['rrSamples'] as List?) ?? const [];
        if (rr.isNotEmpty) {
          final batch = txn.batch();
          for (final r in rr) {
            final rm = r as Map<String, dynamic>;
            batch.insert('rr_samples', {
              'session_id': id,
              't': rm['t'],
              'ms': rm['ms'],
            });
          }
          await batch.commit(noResult: true);
        }
        sessImported++;
      }

      for (final raw in assessments) {
        final a = raw as Map<String, dynamic>;
        final takenAt = a['takenAt'] as int;
        final dup = await txn.query(
          'assessments',
          columns: ['id'],
          where: 'taken_at = ?',
          whereArgs: [takenAt],
          limit: 1,
        );
        if (dup.isNotEmpty) {
          assSkipped++;
          continue;
        }
        await txn.insert('assessments', {
          'taken_at': takenAt,
          'resonance_bpm': a['resonanceBpm'],
          'rationale': a['rationale'],
          'steps_json': a['stepsJson'],
        });
        assImported++;
      }
    });

    return ImportResult(
      sessionsImported: sessImported,
      sessionsSkipped: sessSkipped,
      assessmentsImported: assImported,
      assessmentsSkipped: assSkipped,
    );
  }
}

class ImportResult {
  final int sessionsImported;
  final int sessionsSkipped;
  final int assessmentsImported;
  final int assessmentsSkipped;
  final String? error;

  const ImportResult({
    this.sessionsImported = 0,
    this.sessionsSkipped = 0,
    this.assessmentsImported = 0,
    this.assessmentsSkipped = 0,
    this.error,
  });

  bool get isError => error != null;
  int get totalImported => sessionsImported + assessmentsImported;
  int get totalSkipped => sessionsSkipped + assessmentsSkipped;
}

final sessionRepositoryProvider =
    Provider<SessionRepository>((_) => SessionRepository());
