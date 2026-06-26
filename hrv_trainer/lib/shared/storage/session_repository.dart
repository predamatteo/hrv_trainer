import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../connect_iq/remote_session_summary.dart';
import '../hrv/breathing_pacer.dart';
import '../hrv/hrv_metrics.dart';
import '../hrv/morning_reading.dart';
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
        'morning_meta_json':
            s.morning == null ? null : jsonEncode(s.morning!.toJson()),
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
    final id = row['id'] as int;
    final tagName = row['tag'] as String? ?? 'general';
    // morning_meta_json può mancare (colonna assente in DB pre-v3 letti da un
    // backup, o NULL per sessioni non-morning): in quei casi morning resta null.
    final morningRaw = row['morning_meta_json'] as String?;
    MorningMeta? morning;
    if (morningRaw != null && morningRaw.isNotEmpty) {
      try {
        morning =
            MorningMeta.fromJson(jsonDecode(morningRaw) as Map<String, dynamic>);
      } catch (_) {
        morning = null;
      }
    }
    // pattern_json / metrics_json sono JSON liberi e possono arrivare corrotti
    // da un backup editato a mano (l'export incoraggia esplicitamente
    // l'ispezione manuale). Una singola riga avvelenata NON deve far crashare
    // l'intera listSessions() → Storico e Home rotti in modo permanente: si
    // ripiega su un default e si logga, stesso principio già usato per morning.
    return Session(
      id: id,
      kind: SessionKind.values
          .firstWhere((k) => k.name == row['kind'], orElse: () {
        developer.log('kind sconosciuto "${row['kind']}" per sessione $id',
            name: 'SessionRepository');
        return SessionKind.training;
      }),
      tag: SessionTag.values
          .firstWhere((t) => t.name == tagName, orElse: () => SessionTag.general),
      startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
      endedAt: row['ended_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['ended_at'] as int),
      pattern: _decodePattern(row['pattern_json'], id),
      metrics: _decodeMetrics(row['metrics_json'], id),
      notes: row['notes'] as String?,
      morning: morning,
    );
  }

  BreathingPattern _decodePattern(Object? raw, int sessionId) {
    try {
      return BreathingPattern.fromJson(
        jsonDecode(raw as String) as Map<String, dynamic>,
      );
    } catch (e) {
      developer.log('pattern_json corrotto per sessione $sessionId: $e',
          name: 'SessionRepository');
      return BreathingPattern.resonance6bpm;
    }
  }

  HrvMetrics _decodeMetrics(Object? raw, int sessionId) {
    try {
      return HrvMetrics.fromJson(
        jsonDecode(raw as String) as Map<String, dynamic>,
      );
    } catch (e) {
      developer.log('metrics_json corrotto per sessione $sessionId: $e',
          name: 'SessionRepository');
      return HrvMetrics.empty;
    }
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
  ///
  /// v2: aggiunto `morningMetaJson` per le letture Morning Readiness. Additivo
  /// e retro-compatibile — i backup v1 (senza il campo) si importano
  /// regolarmente con morning=null.
  static const exportSchemaVersion = 2;

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
        'morningMetaJson': s['morning_meta_json'],
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

  /// Esito di un import: quanti record nuovi, quanti scartati per dedup e
  /// quanti scartati perché malformati. `error` non null se il JSON è invalido
  /// o di schema sconosciuto. Niente eccezioni propagate al chiamante: anche un
  /// backup editato a mano con record corrotti viene gestito record-per-record
  /// (validati prima dell'insert) senza mai abortire l'import né inquinare il DB.
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
    var sessInvalid = 0;
    var assImported = 0;
    var assSkipped = 0;
    var assInvalid = 0;

    final db = await _db;
    await db.transaction((txn) async {
      for (final raw in sessions) {
        // Validazione difensiva prima di scrivere: un backup può essere editato
        // a mano (l'export lo incoraggia). Un record con campi mancanti/di tipo
        // errato o con pattern/metrics JSON non decodificabile viene SCARTATO e
        // contato, mai inserito — altrimenti una riga avvelenata romperebbe in
        // lettura tutta listSessions() (Storico e Home) senza recovery in-app.
        if (raw is! Map) {
          sessInvalid++;
          continue;
        }
        final s = raw.cast<String, dynamic>();
        final startedAt = s['startedAt'];
        final kind = s['kind'];
        final patternJson = s['patternJson'];
        final metricsJson = s['metricsJson'];
        if (startedAt is! int ||
            kind is! String ||
            patternJson is! String ||
            metricsJson is! String ||
            !_isDecodableSession(patternJson, metricsJson)) {
          sessInvalid++;
          continue;
        }

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
          'kind': kind,
          'tag': s['tag'] is String ? s['tag'] : 'general',
          'started_at': startedAt,
          'ended_at': s['endedAt'] is int ? s['endedAt'] : null,
          'pattern_json': patternJson,
          'metrics_json': metricsJson,
          'notes': s['notes'] is String ? s['notes'] : null,
          // null per backup v1 (campo assente) → import retro-compatibile.
          'morning_meta_json':
              s['morningMetaJson'] is String ? s['morningMetaJson'] : null,
        });

        final rrRaw = s['rrSamples'];
        if (rrRaw is List && rrRaw.isNotEmpty) {
          final batch = txn.batch();
          for (final r in rrRaw) {
            if (r is! Map) continue;
            final t = r['t'];
            final ms = r['ms'];
            // t/ms vengono ri-letti come int (getSessionRrSamples li casta a
            // int): scartare i campioni non interi evita un crash in lettura.
            if (t is! int || ms is! int) continue;
            batch.insert('rr_samples', {
              'session_id': id,
              't': t,
              'ms': ms,
            });
          }
          await batch.commit(noResult: true);
        }
        sessImported++;
      }

      for (final raw in assessments) {
        if (raw is! Map) {
          assInvalid++;
          continue;
        }
        final a = raw.cast<String, dynamic>();
        final takenAt = a['takenAt'];
        if (takenAt is! int) {
          assInvalid++;
          continue;
        }
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
          'resonance_bpm': a['resonanceBpm'] is num ? a['resonanceBpm'] : null,
          'rationale': a['rationale'] is String ? a['rationale'] : null,
          'steps_json': a['stepsJson'] is String ? a['stepsJson'] : null,
        });
        assImported++;
      }
    });

    return ImportResult(
      sessionsImported: sessImported,
      sessionsSkipped: sessSkipped,
      sessionsInvalid: sessInvalid,
      assessmentsImported: assImported,
      assessmentsSkipped: assSkipped,
      assessmentsInvalid: assInvalid,
    );
  }

  /// Prova a decodificare pattern e metrics di una sessione importata: se uno
  /// dei due JSON non è valido il record va scartato, non scritto nel DB.
  bool _isDecodableSession(String patternJson, String metricsJson) {
    try {
      BreathingPattern.fromJson(
          jsonDecode(patternJson) as Map<String, dynamic>);
      HrvMetrics.fromJson(jsonDecode(metricsJson) as Map<String, dynamic>);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class ImportResult {
  final int sessionsImported;
  final int sessionsSkipped;
  final int sessionsInvalid;
  final int assessmentsImported;
  final int assessmentsSkipped;
  final int assessmentsInvalid;
  final String? error;

  const ImportResult({
    this.sessionsImported = 0,
    this.sessionsSkipped = 0,
    this.sessionsInvalid = 0,
    this.assessmentsImported = 0,
    this.assessmentsSkipped = 0,
    this.assessmentsInvalid = 0,
    this.error,
  });

  bool get isError => error != null;
  int get totalImported => sessionsImported + assessmentsImported;
  int get totalSkipped => sessionsSkipped + assessmentsSkipped;
  int get totalInvalid => sessionsInvalid + assessmentsInvalid;
}

final sessionRepositoryProvider =
    Provider<SessionRepository>((_) => SessionRepository());
