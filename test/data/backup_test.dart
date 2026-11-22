// 规格: 08 T12 备份往返 / 02 §8.7 —— 导出→导入全表逐行相等；
// 非法 JSON 拒绝且原数据不变；备份版本须落在 1..当前版本（旧版本向后兼容）。
import 'dart:convert';

import 'package:test/test.dart';

import 'package:sight_reading/data/backup.dart';
import 'package:sight_reading/data/repositories/settings_repo.dart';
import 'package:sight_reading/data/repositories/sight_read_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/sight_read_log.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/models/trial.dart';

import 'test_db.dart';

Future<Map<String, List<Map<String, Object?>>>> snapshot(Database db) async {
  final out = <String, List<Map<String, Object?>>>{};
  for (final table in backupTableColumns.keys) {
    final orderBy = (table == 'settings' || table == 'app_state')
        ? 'key ASC'
        : (table == 'mastery' ? 'item_id ASC' : 'id ASC');
    out[table] = await db.query(table, orderBy: orderBy);
  }
  return out;
}

void expectSnapshotsEqual(
    Map<String, List<Map<String, Object?>>> a,
    Map<String, List<Map<String, Object?>>> b) {
  expect(a.keys.toSet(), b.keys.toSet());
  for (final table in a.keys) {
    expect(jsonEncode(a[table]), jsonEncode(b[table]), reason: '表 $table 逐行相等');
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  setUp(() async {
    db = await openTestDb();
    await seedSampleData(db);
  });
  tearDown(() async => db.close());

  test('T12: 导出→导入另一库后全表逐行相等', () async {
    final backup = await exportBackup(db);
    expect(backup['schema_version'], 2);
    expect(backup['exportedAt'], isA<int>());
    expect((backup['tables'] as Map).keys.toSet(),
        backupTableColumns.keys.toSet());

    final db2 = await openTestDb();
    try {
      await importBackupJson(db2, jsonEncode(backup));
      expectSnapshotsEqual(await snapshot(db), await snapshot(db2));
    } finally {
      await db2.close();
    }
  });

  test('T12: 覆盖式导入——改动后导入恢复原数据', () async {
    final before = await snapshot(db);
    final backup = await exportBackup(db);

    // 导入前制造差异：改配置 + 追加试次。
    await SettingsRepo(db).set('daily_count', '99');
    final trials = TrialRepo(db);
    final sessionId =
        (await db.query('session', limit: 1)).first['id'] as int;
    final itemId = (await db.query('item', limit: 1)).first['id'] as int;
    await trials.insert(Trial(
      sessionId: sessionId,
      itemId: itemId,
      presentedAt: 5000,
      answeredAt: 5600,
      rtMs: 600,
      correct: true,
      inputSource: InputSource.nameButton,
      contextSnapshot: const ContextSnapshot(clef: Clef.bass, jitterSeed: 9),
    ));
    expect(jsonEncode(await snapshot(db)), isNot(jsonEncode(before)));

    await importBackup(db, backup);
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('T12: 非法 JSON 拒绝且原数据不变', () async {
    final before = await snapshot(db);
    await expectLater(
        importBackupJson(db, '{这不是合法 JSON!!'), throwsA(isA<BackupException>()));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('T12: 更高版本的备份拒绝且原数据不变', () async {
    final before = await snapshot(db);
    final backup = await exportBackup(db);
    backup['schema_version'] = 3;
    await expectLater(
        importBackup(db, backup), throwsA(isA<FormatException>()));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('schema_version 缺失（null）拒绝且原数据不变', () async {
    final before = await snapshot(db);
    final backup = await exportBackup(db);
    backup['schema_version'] = null;
    await expectLater(
        importBackup(db, backup), throwsA(isA<FormatException>()));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('缺表拒绝且原数据不变', () async {
    final before = await snapshot(db);
    final backup = await exportBackup(db);
    (backup['tables'] as Map).remove('mastery');
    await expectLater(
        importBackup(db, backup), throwsA(isA<BackupException>()));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('非法行结构拒绝且原数据不变', () async {
    final before = await snapshot(db);
    final backup = await exportBackup(db);
    (backup['tables'] as Map)['item'] = [
      {'id': 1, 'type': 'ANCHOR'} // 缺列
    ];
    await expectLater(
        importBackup(db, backup), throwsA(isA<BackupException>()));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('事务中途约束失败回滚，原数据不变', () async {
    final before = await snapshot(db);
    final backup =
        jsonDecode(jsonEncode(await exportBackup(db))) as Map<String, dynamic>;
    // trial_log 引用不存在的 item → 插入阶段 FK 失败 → 整体回滚。
    final rows = backup['tables']['trial_log'] as List;
    (rows.first as Map)['item_id'] = 99999;
    await expectLater(importBackup(db, backup), throwsA(anything));
    expectSnapshotsEqual(await snapshot(db), before);
  });

  test('v2 往返：视奏记录随备份导出并逐字段还原', () async {
    final record = SightReadRecord(
      mode: SightMode.grand,
      source: 'score',
      scoreRef: 'sr_c_major_01',
      columnCount: 6,
      totalNotes: 12,
      correctNotes: 9,
      errorCount: 3,
      errorPositions: const {0: 2, 4: 1},
      durationMs: 42000,
      finishedAt: 1732000000000,
    );
    final id = await SightReadRepo(db).insert(record);

    final backup = await exportBackup(db);
    expect(backup['schema_version'], 2);
    expect(backup['tables']['sight_read_log'], hasLength(1));

    final db2 = await openTestDb();
    try {
      await importBackupJson(db2, jsonEncode(backup));
      expectSnapshotsEqual(await snapshot(db), await snapshot(db2));

      final rows = await db2.query('sight_read_log');
      expect(rows, hasLength(1));
      final restored = SightReadRecord.fromRow(rows.single);
      expect(restored.id, id);
      expect(restored.mode, SightMode.grand);
      expect(restored.source, 'score');
      expect(restored.scoreRef, 'sr_c_major_01');
      expect(restored.columnCount, 6);
      expect(restored.totalNotes, 12);
      expect(restored.correctNotes, 9);
      expect(restored.errorCount, 3);
      expect(restored.errorPositions, const {0: 2, 4: 1});
      expect(restored.durationMs, 42000);
      expect(restored.finishedAt, 1732000000000);
    } finally {
      await db2.close();
    }
  });

  test('v1 旧备份（无 sight_read_log）导入 v2 应用：原表正确、视奏表清空', () async {
    final before = await snapshot(db);
    final backup =
        jsonDecode(jsonEncode(await exportBackup(db))) as Map<String, dynamic>;
    expect((backup['tables'] as Map).remove('sight_read_log'), isNotNull);
    backup['schema_version'] = 1;

    // 导入前让库偏离备份：插入一条视奏记录、改一个配置项。
    await SightReadRepo(db).insert(SightReadRecord(
      mode: SightMode.trebleOnly,
      source: 'generated',
      columnCount: 4,
      totalNotes: 8,
      correctNotes: 8,
      errorCount: 0,
      durationMs: 12000,
      finishedAt: 1732000000001,
    ));
    await SettingsRepo(db).set('daily_count', '88');
    expect((await snapshot(db))['sight_read_log'], hasLength(1));

    await importBackup(db, backup);

    // 覆盖式语义：缺失的新表按空表处理（清空），其余表 = 备份内容。
    expect(await SightReadRepo(db).count(), 0);
    expect(await SettingsRepo(db).get('daily_count'), '30');
    expectSnapshotsEqual(await snapshot(db), before);
  });
}