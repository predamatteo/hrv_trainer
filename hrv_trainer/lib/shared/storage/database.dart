import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static Database? _db;

  /// Override per i test: una databaseFactory (es. sqflite_common_ffi) + path
  /// (file temporaneo o :memory:). Quando settati, instance() apre il DB di
  /// test con lo stesso schema/migrazioni dell'app invece del DB reale.
  static DatabaseFactory? testFactory;
  static String? testPath;

  static Future<Database> instance() async {
    if (_db != null) return _db!;
    final factory = testFactory;
    final String path;
    if (factory != null) {
      path = testPath ?? inMemoryDatabasePath;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      path = p.join(dir.path, 'hrv_trainer.db');
    }
    _db = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
      onConfigure: (db) async {
        // SQLite tiene le FOREIGN KEY disabilitate di default: senza questo
        // PRAGMA la `ON DELETE CASCADE` di rr_samples e' decorativa (la cascata
        // regge solo perche' deleteSession cancella a mano in transazione).
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onDowngrade: (db, oldV, newV) async {
        // Apertura di un DB creato da una versione PIU' NUOVA (es. un backup v4
        // ripristinato via device-transfer/cloud su un'app v3): NON cancelliamo
        // nulla (sono dati sanitari) e non andiamo in crash-loop. Le migrazioni
        // sono solo additive, quindi le eventuali colonne extra vengono
        // semplicemente ignorate dal codice piu' vecchio. La versione viene
        // riportata a quella corrente; un futuro re-upgrade e' sicuro grazie
        // agli ADD COLUMN idempotenti in onUpgrade.
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await _addColumnIfMissing(
              db, 'sessions', 'tag', "TEXT NOT NULL DEFAULT 'general'");
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_sessions_tag ON sessions(tag, started_at DESC)',
          );
        }
        if (oldV < 3) {
          // Colonna additiva per i metadati Morning Readiness
          // (postura/protocollo/contesto), serializzati come JSON. Migrazione
          // sicura: ADD COLUMN nullable non tocca i dati esistenti.
          await _addColumnIfMissing(db, 'sessions', 'morning_meta_json', 'TEXT');
        }
        if (oldV < 4) {
          // Piano di allenamento HRV: tabella piani + due colonne additive su
          // sessions per collegare una sessione al piano e per il report
          // soggettivo. Tutto nullable/idempotente: i dati esistenti restano.
          await db.execute('''
            CREATE TABLE IF NOT EXISTS training_plans (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              status TEXT NOT NULL DEFAULT 'active',
              created_at INTEGER NOT NULL,
              plan_json TEXT NOT NULL
            )
          ''');
          // plan_id resta un semplice INTEGER (niente FK a livello DB): la
          // relazione è gestita in codice, coerente con la cascata manuale di
          // rr_samples. Una sessione resta nello storico anche se il piano viene
          // cancellato.
          await _addColumnIfMissing(db, 'sessions', 'plan_id', 'INTEGER');
          await _addColumnIfMissing(
              db, 'sessions', 'post_session_report_json', 'TEXT');
        }
      },
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            tag TEXT NOT NULL DEFAULT 'general',
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            pattern_json TEXT NOT NULL,
            metrics_json TEXT NOT NULL,
            notes TEXT,
            morning_meta_json TEXT,
            plan_id INTEGER,
            post_session_report_json TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_sessions_tag ON sessions(tag, started_at DESC)',
        );
        await db.execute('''
          CREATE TABLE assessments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            taken_at INTEGER NOT NULL,
            resonance_bpm REAL,
            rationale TEXT,
            steps_json TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE rr_samples (
            session_id INTEGER NOT NULL,
            t INTEGER NOT NULL,
            ms INTEGER NOT NULL,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_rr_session ON rr_samples(session_id, t)',
        );
        await db.execute('''
          CREATE TABLE training_plans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            status TEXT NOT NULL DEFAULT 'active',
            created_at INTEGER NOT NULL,
            plan_json TEXT NOT NULL
          )
        ''');
      },
      ),
    );
    return _db!;
  }

  /// Azzera singleton e override (da chiamare in tearDown dei test).
  static Future<void> resetForTest() async {
    await _db?.close();
    _db = null;
    testFactory = null;
    testPath = null;
  }

  /// Aggiunge una colonna solo se non esiste gia'. SQLite non supporta
  /// `ALTER TABLE ADD COLUMN IF NOT EXISTS`, e un ADD COLUMN su colonna gia'
  /// presente lancia "duplicate column name". Serve a rendere onUpgrade
  /// idempotente: dopo un onDowngrade la versione torna indietro ma le colonne
  /// restano, quindi un successivo re-upgrade non deve fallire.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String typeDdl,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final exists = cols.any((c) => c['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $typeDdl');
    }
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
