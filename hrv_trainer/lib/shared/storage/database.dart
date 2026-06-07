import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static Database? _db;

  static Future<Database> instance() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'hrv_trainer.db');
    _db = await openDatabase(
      path,
      version: 3,
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
            "ALTER TABLE sessions ADD COLUMN tag TEXT NOT NULL DEFAULT 'general'",
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_sessions_tag ON sessions(tag, started_at DESC)',
          );
        }
        if (oldV < 3) {
          // Colonna additiva per i metadati Morning Readiness
          // (postura/protocollo/contesto), serializzati come JSON. Migrazione
          // sicura: ADD COLUMN nullable non tocca i dati esistenti.
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN morning_meta_json TEXT',
          );
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
            morning_meta_json TEXT
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
      },
    );
    return _db!;
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
