// 规格: 04 app_state 表 —— 用户进度（course_stage / active_anchors /
// diagnosis_done / diagnosis_result / onboarded），区别于 settings 配置。
library;

import 'package:sqflite_common/sqlite_api.dart';

class AppStateRepo {
  final Database _db;
  AppStateRepo(this._db);

  Future<String?> get(String key) async {
    final rows =
        await _db.query('app_state', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> set(String key, String value) => _db.insert(
        'app_state',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Map<String, String>> getAll() async {
    final rows = await _db.query('app_state');
    return {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
  }
}