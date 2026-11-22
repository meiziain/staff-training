// 规格: 02 §6.1 §8.2 / 04 item 表 —— payload 用 Item.payloadJson/fromRow。
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/enums.dart';
import '../../domain/models/item.dart';

class ItemRepo {
  final Database _db;
  ItemRepo(this._db);

  /// 插入条目，返回自增 id（忽略 item.id 占位值）。
  Future<int> insert(Item item) => _db.insert('item', {
        'type': item.type.wire,
        'payload': item.payloadJson(),
        'created_at': item.createdAt,
      });

  /// 覆写条目 payload（答错变体复用备胎条目，02 §5.4）。
  Future<void> updatePayload(int id, ItemPayload payload) => _db.update(
        'item',
        {'payload': jsonEncode(payload.toJson())},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<Item?> byId(int id) async {
    final rows = await _db.query('item', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Item.fromRow(rows.first);
  }

  Future<List<Item>> byType(ItemType type) async {
    final rows = await _db.query('item',
        where: 'type = ?', whereArgs: [type.wire], orderBy: 'id ASC');
    return rows.map(Item.fromRow).toList();
  }

  Future<List<Item>> all() async {
    final rows = await _db.query('item', orderBy: 'id ASC');
    return rows.map(Item.fromRow).toList();
  }
}