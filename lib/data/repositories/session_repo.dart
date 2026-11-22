// 规格: 02 §7 §8.5 / 04 session 表。
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/phrase_session.dart';

class SessionRepo {
  final Database _db;
  SessionRepo(this._db);

  /// 插入会话，返回自增 id（忽略 session.id 占位值）。
  Future<int> insert(Session session) {
    final row = session.toRow()..remove('id');
    return _db.insert('session', row);
  }

  Future<void> updateDoneCount(int id, int doneCount) => _db.update(
        'session',
        {'done_count': doneCount},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setStageSummary(int id, Map<String, dynamic> summary) =>
      _db.update(
        'session',
        {'stage_summary': jsonEncode(summary)},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<Session?> byId(int id) async {
    final rows =
        await _db.query('session', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  Future<Session?> latest() async {
    final rows =
        await _db.query('session', orderBy: 'id DESC', limit: 1);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }
}