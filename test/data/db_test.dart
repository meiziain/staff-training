// 规格: 04-数据库设计.sql（DDL/种子权威）/ 03 §4.3 / 08 T12 前置数据完整性。
import 'dart:io';

import 'package:sqflite_common/utils/utils.dart' show firstIntValue;
import 'package:test/test.dart';

import 'package:sight_reading/data/db.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/repositories/note_position_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/settings_repo.dart';
import 'package:sight_reading/data/repositories/sight_read_repo.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/sight_read_log.dart';
import 'package:sight_reading/domain/models/sight_score.dart';

import 'test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('db 打开与种子', () {
    late Database db;
    setUp(() async => db = await openTestDb());
    tearDown(() async => db.close());

    test('22 音位齐全，C4/C3/C6 边界正确', () async {
      final repo = NotePositionRepo(db);
      final all = await repo.all();
      expect(all.length, 22);
      expect(all.first.diatonicIndex, -7);
      expect(all.last.diatonicIndex, 14);

      final c4 = await repo.byIndex(0);
      expect(c4, isNotNull);
      expect(c4!.displayName, 'C4');
      expect(c4.midi, 60);
      expect(c4.inTreble, isTrue);
      expect(c4.inBass, isTrue);
      expect(c4.ledgerTreble, isTrue, reason: 'C4 高音谱表加线');
      expect(c4.ledgerBass, isTrue, reason: 'C4 低音谱表加线');

      final c3 = await repo.byIndex(-7);
      expect(c3!.displayName, 'C3');
      expect(c3.midi, 48);
      expect(c3.inTreble, isFalse);
      expect(c3.inBass, isTrue);

      final c6 = await repo.byIndex(14);
      expect(c6!.displayName, 'C6');
      expect(c6.midi, 84);
      expect(c6.inTreble, isTrue);
      expect(c6.inBass, isFalse);
      expect(c6.ledgerTreble, isTrue);
    });

    test('settings 种子齐全且 loadConfig 一致', () async {
      final repo = SettingsRepo(db);
      final s = await repo.getAll();
      expect(s['schema_version'], '2');
      expect(s['anchor_auto_rt_ms'], '1200');
      expect(s['interval_ladder_days'], '0,1,3,7,14,30');
      expect(s['hint_dep_weights'], '0.2,0.4,0.6,0.8,1.0');
      expect(s['anchor_candidates'], '0,4,-4,7,-7');
      expect(s['daily_count'], '40');
      expect(s.length, greaterThanOrEqualTo(60));

      final config = await repo.loadConfig();
      expect(config.anchorAutoRtMs, 1200);
      expect(config.intervalLadderDays, [0, 1, 3, 7, 14, 30]);
      expect(config.anchorCandidates, [0, 4, -4, 7, -7]);
      expect(config.easeMin, 1.3);
      expect(config.easeMax, 2.8);
    });

    test('app_state 初始值', () async {
      final repo = AppStateRepo(db);
      expect(await repo.get('course_stage'), '0');
      expect(await repo.get('active_anchors'), '[]');
      expect(await repo.get('diagnosis_done'), '0');
      expect(await repo.get('diagnosis_result'), '{}');
      expect(await repo.get('onboarded'), '0');
    });

    test('user_version = 2', () async {
      final v = firstIntValue(await db.rawQuery('PRAGMA user_version'));
      expect(v, 2);
    });

    test('同一连接重复 applySchema 幂等，不重复插入', () async {
      await applySchema(db);
      await applySchema(db);
      expect(
          firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM note_position')),
          22);
      expect(
          firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM settings')),
          greaterThanOrEqualTo(60));
      expect(
          firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM app_state')),
          5);
      expect(firstIntValue(await db.rawQuery('PRAGMA user_version')), 2);
    });
  });

  test('文件库关闭重开幂等，种子不重复', () async {
    final dir = Directory.systemTemp.createTempSync('sight_reading_db_test');
    final path = '${dir.path}${Platform.pathSeparator}app.db';
    try {
      final db1 = await openAppDatabase(databaseFactoryFfi, path);
      final settingsCount = firstIntValue(
          await db1.rawQuery('SELECT COUNT(*) FROM settings'));
      await db1.close();

      final db2 = await openAppDatabase(databaseFactoryFfi, path);
      expect(
          firstIntValue(
              await db2.rawQuery('SELECT COUNT(*) FROM note_position')),
          22);
      expect(
          firstIntValue(
              await db2.rawQuery('SELECT COUNT(*) FROM settings')),
          settingsCount);
      expect(firstIntValue(await db2.rawQuery('PRAGMA user_version')), 2);
      await db2.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('v1 老库升级到 v2：老数据无损，sight_read_log 可用', () async {
    final dir = Directory.systemTemp.createTempSync('sight_reading_upgrade');
    final path = '${dir.path}${Platform.pathSeparator}app.db';
    try {
      // ---- 1) 造一个真正的 v1 库：重放全量 DDL 但剔除 sight_read_log，
      // 再把 user_version 写回 1（v1 应用的库就是这个样子）。
      final v1 = await databaseFactoryFfi.openDatabase(path);
      for (final stmt in splitSqlStatements(schemaSql)) {
        if (stmt.toLowerCase().contains('sight_read_log')) continue;
        await v1.execute(stmt);
      }
      await v1.execute('PRAGMA user_version = 1');

      // 老数据：改过的 app_state、一条会话、一个改过的配置项。
      await AppStateRepo(v1).set('course_stage', '3');
      final sessionId = await SessionRepo(v1).insert(const Session(
        date: '2026-11-20',
        startedAt: 1000,
        plannedCount: 40,
        doneCount: 7,
      ));
      await SettingsRepo(v1).set('daily_count', '30');
      final v1NoteCount = firstIntValue(
          await v1.rawQuery('SELECT COUNT(*) FROM note_position'));
      expect(v1NoteCount, 22);
      expect(
        await v1.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sight_read_log'"),
        isEmpty,
        reason: 'v1 库不应该有新表',
      );
      await v1.close();

      // ---- 2) 用新 schema 打开（内部 applySchema 全量重放）。
      final db = await openAppDatabase(databaseFactoryFfi, path);
      expect(firstIntValue(await db.rawQuery('PRAGMA user_version')), 2);

      // 老数据一行不少、值不被种子覆盖。
      expect(
          firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM note_position')),
          22);
      expect(await AppStateRepo(db).get('course_stage'), '3');
      expect(await SettingsRepo(db).get('daily_count'), '30');
      final sessions = await db.query('session', where: 'id = ?', whereArgs: [sessionId]);
      expect(sessions, hasLength(1));
      expect(sessions.first['date'], '2026-11-20');
      expect(sessions.first['done_count'], 7);

      // 新表可用：写入并读回（含 JSON error_positions 往返）。
      final repo = SightReadRepo(db);
      final id = await repo.insert(const SightReadRecord(
        mode: SightMode.grand,
        source: 'score',
        scoreRef: 'sr_grand_01',
        columnCount: 8,
        totalNotes: 13,
        correctNotes: 12,
        errorCount: 1,
        errorPositions: {7: 1},
        durationMs: 42000,
        finishedAt: 1700000000000,
      ));
      expect(id, greaterThan(0));
      expect(await repo.count(), 1);
      final recent = await repo.recent();
      expect(recent, hasLength(1));
      expect(recent.first.mode, SightMode.grand);
      expect(recent.first.scoreRef, 'sr_grand_01');
      expect(recent.first.errorPositions, {7: 1});

      // 老数据仍不受影响（写完新表后再确认一次）。
      expect(await AppStateRepo(db).get('course_stage'), '3');
      await db.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}