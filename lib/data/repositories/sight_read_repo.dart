// 规格: 11 §7 —— sight_read_log 读写。
//
// 只增不改：视奏记录是一次性练习回显，不参与排程（不写 mastery / trial_log）。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/sight_read_log.dart';

class SightReadRepo {
  final Database _db;
  SightReadRepo(this._db);

  /// 插入一条记录，返回自增 id（忽略 record.id 占位值）。
  Future<int> insert(SightReadRecord record) {
    final row = record.toRow()..remove('id');
    return _db.insert('sight_read_log', row);
  }

  /// 最近若干条，按完成时间倒序（同一时刻按 id 倒序保证稳定）。
  Future<List<SightReadRecord>> recent({int limit = 20}) async {
    final rows = await _db.query(
      'sight_read_log',
      orderBy: 'finished_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(SightReadRecord.fromRow).toList();
  }

  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM sight_read_log');
    return (rows.first['c'] as int?) ?? 0;
  }
}
