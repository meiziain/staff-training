// 规格: 02 §8.5 / 04 phrase 表（短句明细）。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/phrase_session.dart';

class PhraseRepo {
  final Database _db;
  PhraseRepo(this._db);

  /// 插入短句明细，返回自增 id（忽略 record.id 占位值）。
  Future<int> insert(PhraseRecord record) {
    final row = record.toRow()..remove('id');
    return _db.insert('phrase', row);
  }

  Future<List<PhraseRecord>> byItem(int itemId) async {
    final rows = await _db.query('phrase',
        where: 'item_id = ?', whereArgs: [itemId], orderBy: 'id ASC');
    return rows.map(PhraseRecord.fromRow).toList();
  }
}