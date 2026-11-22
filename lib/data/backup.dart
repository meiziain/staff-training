// 规格: 02 §8.7 数据安全 —— 导出/导入 JSON 全量备份；导入前校验版本与完整性，
// 导入为覆盖式；08 T12 备份往返。schema_version 与 db.dart 的 schemaVersion 一致。
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../core/clock.dart';

/// 备份格式版本（与 `db.dart` 的 schemaVersion 同步；v2 = 含 sight_read_log）。
const int backupSchemaVersion = 2;

/// 备份覆盖的全部表及列（与 04 DDL 一一对应）。
const Map<String, List<String>> backupTableColumns = {
  'note_position': [
    'id', 'diatonic_index', 'display_name', 'pitch_class', 'octave', 'midi',
    'in_treble', 'in_bass', 'ledger_treble', 'ledger_bass',
  ],
  'item': ['id', 'type', 'payload', 'created_at'],
  'mastery': [
    'item_id', 'state', 'ease', 'interval_days', 'due_at', 'reps', 'lapses',
    'hint_level', 'hint_dependency', 'rt_median', 'last_results', 'context_tags',
  ],
  'trial_log': [
    'id', 'session_id', 'item_id', 'presented_at', 'answered_at', 'rt_ms',
    'correct', 'timeout', 'hint_level_used', 'hint_requested', 'error_type',
    'answer_pitch_class', 'answer_octave', 'input_source', 'context_snapshot',
  ],
  'session': [
    'id', 'date', 'started_at', 'planned_count', 'done_count', 'stage_summary',
  ],
  'phrase': [
    'id', 'item_id', 'note_sequence', 'reset_count', 'per_note_rt',
    'overall_correct', 'created_at',
  ],
  'confusion_seed': ['id', 'pair_a', 'pair_b', 'count', 'last_seen'],
  'settings': ['key', 'value'],
  'app_state': ['key', 'value'],
  'sight_read_log': [
    'id', 'mode', 'source', 'score_ref', 'column_count', 'total_notes',
    'correct_notes', 'error_count', 'error_positions', 'duration_ms',
    'finished_at',
  ],
};

/// 各表引入的备份版本。低于该版本的备份可以不含该表（导入时按空表清空）。
const Map<String, int> _tableSinceVersion = {
  'sight_read_log': 2,
};

/// 清空顺序：先子表后父表（FK 安全）。
const List<String> _deleteOrder = [
  'trial_log', 'phrase', 'mastery', 'confusion_seed',
  'session', 'item', 'note_position', 'settings', 'app_state',
  'sight_read_log',
];

/// 插入顺序：先父表后子表（FK 安全）。sight_read_log 无外键依赖，放末尾。
const List<String> _insertOrder = [
  'note_position', 'item', 'session', 'mastery', 'trial_log', 'phrase',
  'confusion_seed', 'settings', 'app_state', 'sight_read_log',
];

/// 备份校验/导入失败（原数据保持不变）。
class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => 'BackupException: $message';
}

/// 导出全量备份：{schema_version, exportedAt, tables:{表名:全表逐行}}。
Future<Map<String, dynamic>> exportBackup(Database db, {Clock? clock}) async {
  final tables = <String, dynamic>{};
  for (final table in backupTableColumns.keys) {
    final orderBy = (table == 'settings' || table == 'app_state')
        ? 'key ASC'
        : (table == 'mastery' ? 'item_id ASC' : 'id ASC');
    tables[table] = await db.query(table, orderBy: orderBy);
  }
  return {
    'schema_version': backupSchemaVersion,
    'exportedAt': (clock ?? SystemClock()).nowUtcMs(),
    'tables': tables,
  };
}

/// 校验备份结构（在任何写操作之前；非法则抛 BackupException，版本不符则抛
/// FormatException，原数据不变）。
///
/// 版本规则：1 ≤ schema_version ≤ backupSchemaVersion 才接受。低于当前版本的
/// 旧备份（如 v1）允许导入，其中「当时还不存在的表」按空表处理——见下方注释。
Map<String, List<Map<String, Object?>>> _validate(Object? backup) {
  if (backup is! Map<String, dynamic>) {
    throw BackupException('备份必须是 JSON 对象');
  }
  final v = backup['schema_version'] as int?;
  if (v == null || v < 1 || v > backupSchemaVersion) {
    throw FormatException('备份版本不符：期望 ≤$backupSchemaVersion，实际 $v');
  }
  final tables = backup['tables'];
  if (tables is! Map<String, dynamic>) {
    throw BackupException('缺少 tables 对象');
  }
  final result = <String, List<Map<String, Object?>>>{};
  for (final entry in backupTableColumns.entries) {
    final table = entry.key;
    final columns = entry.value;
    if (!tables.containsKey(table)) {
      // 覆盖式语义：导入后「目标库 = 备份内容」，未出现在备份中的表按空表处理，
      // 导入时被 DELETE 清空（而不是保留导入前的残留行）。
      // 但只有「备份版本早于该表引入版本」时才允许缺失（如 v1 备份没有
      // sight_read_log）；同版本备份缺表属于文件损坏，仍然拒绝。
      if (v < (_tableSinceVersion[table] ?? 1)) {
        result[table] = const <Map<String, Object?>>[];
        continue;
      }
      throw BackupException('缺表：$table');
    }
    final rows = tables[table];
    if (rows is! List) {
      throw BackupException('表 $table 必须是行数组');
    }
    final typed = <Map<String, Object?>>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) {
        throw BackupException('表 $table 存在非法行结构');
      }
      if (row.keys.length != columns.length ||
          !columns.every(row.containsKey)) {
        throw BackupException('表 $table 行列集与 schema 不符');
      }
      typed.add(row);
    }
    result[table] = typed;
  }
  return result;
}

/// 覆盖式导入（02 §8.7）：先整体校验，再在单事务内清空全表+插入；
/// 任一步失败回滚，原数据不变。结构非法抛 BackupException，
/// 版本不可接受抛 FormatException。
Future<void> importBackup(Database db, Object? backup) async {
  final tables = _validate(backup);
  await db.transaction((txn) async {
    for (final table in _deleteOrder) {
      await txn.delete(table);
    }
    for (final table in _insertOrder) {
      for (final row in tables[table]!) {
        await txn.insert(table, row);
      }
    }
  });
}

/// 从 JSON 字符串导入；非法 JSON 拒绝且原数据不变（08 T12）。
Future<void> importBackupJson(Database db, String source) async {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    throw BackupException('非法 JSON：${e.message}');
  }
  await importBackup(db, decoded);
}