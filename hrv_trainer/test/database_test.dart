@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/storage/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema v1 (originale): sessions SENZA tag/morning_meta_json.
Future<Database> _createV1(String path, {bool withTag = false}) {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            ${withTag ? "tag TEXT NOT NULL DEFAULT 'general'," : ''}
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            pattern_json TEXT NOT NULL,
            metrics_json TEXT NOT NULL,
            notes TEXT
          )''');
        await db.execute('''
          CREATE TABLE assessments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            taken_at INTEGER NOT NULL,
            resonance_bpm REAL, rationale TEXT, steps_json TEXT NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE rr_samples (
            session_id INTEGER NOT NULL, t INTEGER NOT NULL, ms INTEGER NOT NULL
          )''');
      },
    ),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hrv_db_test');
    AppDatabase.testFactory = databaseFactoryFfi;
    AppDatabase.testPath = '${tmp.path}/test.db';
  });
  tearDown(() async {
    await AppDatabase.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('apertura fresca: tabelle a v3 + foreign_keys ON', () async {
    final db = await AppDatabase.instance();
    final fk = await db.rawQuery('PRAGMA foreign_keys');
    expect(fk.first.values.first, 1); // enforcement attivo

    final tables = (await db
            .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(tables, containsAll(['sessions', 'assessments', 'rr_samples']));

    final cols = (await db.rawQuery('PRAGMA table_info(sessions)'))
        .map((c) => c['name'])
        .toSet();
    expect(cols, containsAll(['tag', 'morning_meta_json']));
  });

  test('ON DELETE CASCADE rimuove i rr_samples cancellando la sessione',
      () async {
    final db = await AppDatabase.instance();
    final sid = await db.insert('sessions', {
      'kind': 'training',
      'tag': 'general',
      'started_at': 1000,
      'pattern_json': '{}',
      'metrics_json': '{}',
    });
    await db.insert('rr_samples', {'session_id': sid, 't': 1, 'ms': 800});
    await db.insert('rr_samples', {'session_id': sid, 't': 2, 'ms': 820});

    // Cancellazione DIRETTA della sessione (non via deleteSession): la cascata
    // deve agire grazie al PRAGMA foreign_keys = ON.
    await db.delete('sessions', where: 'id = ?', whereArgs: [sid]);

    final left =
        await db.query('rr_samples', where: 'session_id = ?', whereArgs: [sid]);
    expect(left, isEmpty);
  });

  test('migrazione v1 -> v3 aggiunge tag e morning_meta_json, dati intatti',
      () async {
    final v1 = await _createV1(AppDatabase.testPath!);
    await v1.insert('sessions', {
      'kind': 'training',
      'started_at': 5000,
      'pattern_json': '{}',
      'metrics_json': '{}',
    });
    await v1.close();

    final db = await AppDatabase.instance(); // onUpgrade(1, 3)
    final cols = (await db.rawQuery('PRAGMA table_info(sessions)'))
        .map((c) => c['name'])
        .toSet();
    expect(cols, containsAll(['tag', 'morning_meta_json']));

    final rows = await db.query('sessions');
    expect(rows.length, 1);
    expect(rows.first['tag'], 'general'); // default applicato dalla migrazione
    expect(rows.first['started_at'], 5000);
  });

  test('re-upgrade idempotente: ADD COLUMN non fallisce se la colonna esiste',
      () async {
    // v1 ma con `tag` GIA' presente (simula un downgrade da v2+ poi re-upgrade).
    final v1 = await _createV1(AppDatabase.testPath!, withTag: true);
    await v1.close();

    // Non deve lanciare "duplicate column name".
    final db = await AppDatabase.instance();
    final cols = (await db.rawQuery('PRAGMA table_info(sessions)'))
        .map((c) => c['name'])
        .toSet();
    expect(cols, containsAll(['tag', 'morning_meta_json']));
  });

  test('onDowngrade: un DB creato a v4 si apre su v3 senza crash', () async {
    final v4 = await databaseFactoryFfi.openDatabase(
      AppDatabase.testPath!,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, v) async {
          await db.execute('''
            CREATE TABLE sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
              tag TEXT NOT NULL DEFAULT 'general', started_at INTEGER NOT NULL,
              ended_at INTEGER, pattern_json TEXT NOT NULL,
              metrics_json TEXT NOT NULL, notes TEXT, morning_meta_json TEXT,
              future_col TEXT
            )''');
          await db.execute('''
            CREATE TABLE assessments (id INTEGER PRIMARY KEY AUTOINCREMENT,
              taken_at INTEGER NOT NULL, resonance_bpm REAL, rationale TEXT,
              steps_json TEXT NOT NULL)''');
          await db.execute('''
            CREATE TABLE rr_samples (session_id INTEGER NOT NULL,
              t INTEGER NOT NULL, ms INTEGER NOT NULL)''');
        },
      ),
    );
    await v4.insert('sessions', {
      'kind': 'training',
      'started_at': 7000,
      'pattern_json': '{}',
      'metrics_json': '{}',
    });
    await v4.close();

    // Apertura a v3: onDowngrade no-op, niente crash-loop, dati conservati.
    final db = await AppDatabase.instance();
    final rows = await db.query('sessions');
    expect(rows.length, 1);
    expect(rows.first['started_at'], 7000);
  });
}
