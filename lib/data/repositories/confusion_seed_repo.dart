// 规格: 02 §8.5 / 04 confusion_seed（MVP 只写不读；all 仅供报告展示）。
// 约定 pair_a < pair_b；错误试次 count+1（08 T9）。
library;

import 'package:sqflite_common/sqlite_api.dart';

/// UPSERT：pair 规范化为 a<b，count+1，last_seen 更新。事务内可复用。
Future<void> bumpConfusionPair(
    DatabaseExecutor e, int pairA, int pairB, int ts) {
  final a = pairA < pairB ? pairA : pairB;
  final b = pairA < pairB ? pairB : pairA;
  return e.rawInsert(
    'INSERT INTO confusion_seed (pair_a, pair_b, count, last_seen) '
    'VALUES (?, ?, 1, ?) '
    'ON CONFLICT(pair_a, pair_b) DO UPDATE SET '
    'count = count + 1, last_seen = excluded.last_seen',
    [a, b, ts],
  );
}

class ConfusionSeedRepo {
  final Database _db;
  ConfusionSeedRepo(this._db);

  Future<void> bumpPair(int pairA, int pairB, int ts) =>
      bumpConfusionPair(_db, pairA, pairB, ts);

  /// 仅供报告展示（易混对列表）；规则层 MVP 不消费。
  Future<List<Map<String, Object?>>> all() => _db.query('confusion_seed',
      orderBy: 'count DESC, pair_a ASC, pair_b ASC');
}