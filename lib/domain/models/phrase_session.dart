// 规格: 02 §8.5 / 04 phrase、session 表。
library;

import 'dart:convert';

/// 短句明细（逐音 RT、复位次数、整体正确率）。
class PhraseRecord {
  final int? id;
  final int itemId;
  final List<int> noteSequence;
  final int resetCount;
  final List<int>? perNoteRt;
  final double? overallCorrect;
  final int createdAt;

  const PhraseRecord({
    this.id,
    required this.itemId,
    required this.noteSequence,
    this.resetCount = 0,
    this.perNoteRt,
    this.overallCorrect,
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'item_id': itemId,
        'note_sequence': jsonEncode(noteSequence),
        'reset_count': resetCount,
        'per_note_rt': perNoteRt == null ? null : jsonEncode(perNoteRt),
        'overall_correct': overallCorrect,
        'created_at': createdAt,
      };

  factory PhraseRecord.fromRow(Map<String, Object?> row) => PhraseRecord(
        id: row['id'] as int?,
        itemId: row['item_id'] as int,
        noteSequence:
            (jsonDecode(row['note_sequence'] as String) as List)
                .map((e) => e as int)
                .toList(),
        resetCount: row['reset_count'] as int,
        perNoteRt: row['per_note_rt'] == null
            ? null
            : (jsonDecode(row['per_note_rt'] as String) as List)
                .map((e) => e as int)
                .toList(),
        overallCorrect: (row['overall_correct'] as num?)?.toDouble(),
        createdAt: row['created_at'] as int,
      );
}

/// 会话（02 §7）。
class Session {
  final int? id;
  final String date; // 本地 YYYY-MM-DD
  final int startedAt;
  final int plannedCount;
  final int doneCount;
  final Map<String, dynamic>? stageSummary;

  const Session({
    this.id,
    required this.date,
    required this.startedAt,
    required this.plannedCount,
    this.doneCount = 0,
    this.stageSummary,
  });

  Session copyWith({int? id, int? doneCount, Map<String, dynamic>? stageSummary}) =>
      Session(
        id: id ?? this.id,
        date: date,
        startedAt: startedAt,
        plannedCount: plannedCount,
        doneCount: doneCount ?? this.doneCount,
        stageSummary: stageSummary ?? this.stageSummary,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'date': date,
        'started_at': startedAt,
        'planned_count': plannedCount,
        'done_count': doneCount,
        'stage_summary':
            stageSummary == null ? null : jsonEncode(stageSummary),
      };

  factory Session.fromRow(Map<String, Object?> row) => Session(
        id: row['id'] as int?,
        date: row['date'] as String,
        startedAt: row['started_at'] as int,
        plannedCount: row['planned_count'] as int,
        doneCount: row['done_count'] as int,
        stageSummary: row['stage_summary'] == null
            ? null
            : jsonDecode(row['stage_summary'] as String)
                as Map<String, dynamic>,
      );
}