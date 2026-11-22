// 规格: 02 §6.1 §8.3 / 04 mastery 表 / 03 §4.3（与 trial 插入同事务）。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/enums.dart';
import '../../domain/models/mastery.dart';

/// 事务内可复用的 upsert（DatabaseExecutor 兼容 Database/Transaction）。
Future<void> upsertMastery(DatabaseExecutor e, Mastery mastery) => e.insert(
      'mastery',
      mastery.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

class MasteryRepo {
  final Database _db;
  MasteryRepo(this._db);

  Future<Mastery?> byItemId(int itemId) async {
    final rows = await _db
        .query('mastery', where: 'item_id = ?', whereArgs: [itemId]);
    return rows.isEmpty ? null : Mastery.fromRow(rows.first);
  }

  Future<void> upsert(Mastery mastery) => upsertMastery(_db, mastery);

  Future<List<Mastery>> all() async {
    final rows = await _db.query('mastery', orderBy: 'item_id ASC');
    return rows.map(Mastery.fromRow).toList();
  }

  /// 到期条目：due_at 非空且 <= ts（UTC ms），按到期时间升序。
  Future<List<Mastery>> dueBefore(int ts) async {
    final rows = await _db.query('mastery',
        where: 'due_at IS NOT NULL AND due_at <= ?',
        whereArgs: [ts],
        orderBy: 'due_at ASC');
    return rows.map(Mastery.fromRow).toList();
  }

  Future<List<Mastery>> byState(ItemState state) async {
    final rows = await _db.query('mastery',
        where: 'state = ?', whereArgs: [state.wire], orderBy: 'item_id ASC');
    return rows.map(Mastery.fromRow).toList();
  }
}