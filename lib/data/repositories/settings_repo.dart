// 规格: 02 §8.6 / 03 §2 规则3 / 04 settings 表 —— 阈值键值，启动加载为 Config。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../core/config.dart';

class SettingsRepo {
  final Database _db;
  SettingsRepo(this._db);

  Future<Map<String, String>> getAll() async {
    final rows = await _db.query('settings');
    return {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
  }

  Future<String?> get(String key) async {
    final rows =
        await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> set(String key, String value) => _db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Config> loadConfig() async => Config.fromSettings(await getAll());
}