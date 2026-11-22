// 规格: 11 §7 —— 视奏训练记录（sight_read_log 表）。零 Flutter 依赖。
//
// 定位：只做「练过什么、错在哪」的回显，不写 mastery / trial_log / phrase，
// 不参与 SM-2 排程、掌握地图与阶段推进（11 §0 §7）。
//
// 与 04 表注释的差异：规格示例把 error_positions 写成 `[diatonicIndex...]`，
// 本实现存 JSON 对象 `{diatonicIndex: 次数}`——完成页 top3 需要次数，
// 且仍是合法 JSON、可无损聚合；键在读取时还原为 int。
library;

import 'dart:convert';

import 'sight_score.dart';

class SightReadRecord {
  /// 自增主键；未入库时为 null。
  final int? id;

  final SightMode mode;

  /// `generated`（生成练习）或 `score`（内置曲目）。
  final String source;

  /// 曲目 id；生成练习为 null。
  final String? scoreRef;

  final int columnCount;
  final int totalNotes;
  final int correctNotes;
  final int errorCount;

  /// diatonicIndex → 错误次数。
  final Map<int, int> errorPositions;

  /// 用时（单调钟，ms）。
  final int durationMs;

  /// 完成时刻（墙钟 UTC ms）。
  final int finishedAt;

  const SightReadRecord({
    this.id,
    required this.mode,
    required this.source,
    this.scoreRef,
    required this.columnCount,
    required this.totalNotes,
    required this.correctNotes,
    required this.errorCount,
    this.errorPositions = const {},
    required this.durationMs,
    required this.finishedAt,
  });

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'mode': mode.wire,
        'source': source,
        'score_ref': scoreRef,
        'column_count': columnCount,
        'total_notes': totalNotes,
        'correct_notes': correctNotes,
        'error_count': errorCount,
        'error_positions':
            errorPositions.isEmpty ? null : jsonEncode(_stringKeyed()),
        'duration_ms': durationMs,
        'finished_at': finishedAt,
      };

  factory SightReadRecord.fromRow(Map<String, Object?> row) {
    final raw = row['error_positions'] as String?;
    final positions = <int, int>{};
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          final index = int.tryParse('$k');
          if (index != null) positions[index] = (v as num).toInt();
        });
      }
    }
    return SightReadRecord(
      id: row['id'] as int?,
      mode: SightMode.fromWire(row['mode'] as String),
      source: row['source'] as String,
      scoreRef: row['score_ref'] as String?,
      columnCount: row['column_count'] as int,
      totalNotes: row['total_notes'] as int,
      correctNotes: row['correct_notes'] as int,
      errorCount: row['error_count'] as int,
      errorPositions: positions,
      durationMs: row['duration_ms'] as int,
      finishedAt: row['finished_at'] as int,
    );
  }

  /// JSON 对象的键必须是字符串（int 键在 jsonEncode 时会被强转）。
  Map<String, int> _stringKeyed() => {
        for (final e in errorPositions.entries)
          if (e.value > 0) '${e.key}': e.value,
      };
}
