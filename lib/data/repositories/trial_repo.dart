// 规格: 02 §8.4 / 04 trial_log（只增不改，不提供 update/delete）/
// 03 §4.3：mastery 更新与 trial 插入同事务；08 P3。
library;

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/utils/utils.dart' show firstIntValue;

import '../../domain/models/mastery.dart';
import '../../domain/models/trial.dart';
import 'confusion_seed_repo.dart';
import 'mastery_repo.dart';

/// 事务内可复用的 trial 插入（强制自增 id，只增不改）。
Future<int> insertTrial(DatabaseExecutor e, Trial trial) {
  final row = trial.toRow()..remove('id');
  return e.insert('trial_log', row);
}

class TrialRepo {
  final Database _db;
  TrialRepo(this._db);

  Future<int> insert(Trial trial) => insertTrial(_db, trial);

  /// 关键事务（03 §4.3）：trial 插入 + mastery upsert + confusion_seed bump
  /// 同一事务，任一步失败整体回滚（08 P3 崩溃一致性）。
  /// seedPair 由调用方在错误试次时传入（08 T9）；ts 取作答时间。
  Future<int> recordTrial({
    required Trial trial,
    required Mastery mastery,
    (int, int)? seedPair,
  }) =>
      _db.transaction((txn) async {
        final id = await insertTrial(txn, trial);
        await upsertMastery(txn, mastery);
        if (seedPair != null) {
          await bumpConfusionPair(
              txn, seedPair.$1, seedPair.$2, trial.answeredAt ?? trial.presentedAt);
        }
        return id;
      });

  Future<List<Trial>> bySession(int sessionId) async {
    final rows = await _db.query('trial_log',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'id ASC');
    return rows.map(Trial.fromRow).toList();
  }

  Future<List<Trial>> byItem(int itemId) async {
    final rows = await _db.query('trial_log',
        where: 'item_id = ?', whereArgs: [itemId], orderBy: 'id ASC');
    return rows.map(Trial.fromRow).toList();
  }

  /// 最近 limit 条（按落库顺序倒序取，返回仍按时间正序）。
  Future<List<Trial>> recentByItem(int itemId, int limit) async {
    final rows = await _db.query('trial_log',
        where: 'item_id = ?',
        whereArgs: [itemId],
        orderBy: 'id DESC',
        limit: limit);
    return rows.reversed.map(Trial.fromRow).toList();
  }

  Future<int> count() async =>
      firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM trial_log')) ?? 0;
}