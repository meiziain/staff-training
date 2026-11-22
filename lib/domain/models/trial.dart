// 规格: 02 §8.4 / 04 trial_log（只增不改）/ 05 §3 context_snapshot。
library;

import 'dart:convert';

import 'enums.dart';

/// 呈现上下文快照（换上下文复现判定用，05 §3）。
class ContextSnapshot {
  final Clef clef;
  final int jitterSeed;
  final int? phraseSlot; // 短句内音位序号；孤立呈现为 null
  final List<int> neighbors; // 相邻音呈现
  final String presentation; // 'isolated' / 'in_phrase' / 'prelude_anchor'
  final bool preludeAnchor; // 前置锚点闪现与否

  const ContextSnapshot({
    required this.clef,
    required this.jitterSeed,
    this.phraseSlot,
    this.neighbors = const [],
    this.presentation = 'isolated',
    this.preludeAnchor = false,
  });

  Map<String, dynamic> toJson() => {
        'clef': clef.wire,
        'jitterSeed': jitterSeed,
        if (phraseSlot != null) 'phraseSlot': phraseSlot,
        'neighbors': neighbors,
        'presentation': presentation,
        'preludeAnchor': preludeAnchor,
      };

  factory ContextSnapshot.fromJson(Map<String, dynamic> j) => ContextSnapshot(
        clef: Clef.fromWire(j['clef'] as String),
        jitterSeed: j['jitterSeed'] as int,
        phraseSlot: j['phraseSlot'] as int?,
        neighbors:
            (j['neighbors'] as List? ?? []).map((e) => e as int).toList(),
        presentation: j['presentation'] as String? ?? 'isolated',
        preludeAnchor: j['preludeAnchor'] as bool? ?? false,
      );

  /// 与另一快照至少一维不同（05 §3 复现约束）。
  bool differsFrom(ContextSnapshot o) =>
      clef != o.clef ||
      jitterSeed != o.jitterSeed ||
      phraseSlot != o.phraseSlot ||
      presentation != o.presentation ||
      preludeAnchor != o.preludeAnchor ||
      !_listEq(neighbors, o.neighbors);

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 试次（落库模型；trial_log 只增不改）。
class Trial {
  final int? id;
  final int sessionId;
  final int itemId;
  final int presentedAt; // 刺激 onset（post-frame）UTC ms
  final int? answeredAt;
  final int? rtMs;
  final bool correct;
  final bool timeout;
  final int hintLevelUsed;
  final bool hintRequested;
  final ErrorType? errorType;
  final String? answerPitchClass;
  final int? answerOctave;
  final InputSource inputSource;
  final ContextSnapshot contextSnapshot;

  const Trial({
    this.id,
    required this.sessionId,
    required this.itemId,
    required this.presentedAt,
    this.answeredAt,
    this.rtMs,
    required this.correct,
    this.timeout = false,
    this.hintLevelUsed = 0,
    this.hintRequested = false,
    this.errorType,
    this.answerPitchClass,
    this.answerOctave,
    required this.inputSource,
    required this.contextSnapshot,
  });

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'item_id': itemId,
        'presented_at': presentedAt,
        'answered_at': answeredAt,
        'rt_ms': rtMs,
        'correct': correct ? 1 : 0,
        'timeout': timeout ? 1 : 0,
        'hint_level_used': hintLevelUsed,
        'hint_requested': hintRequested ? 1 : 0,
        'error_type': errorType?.wire,
        'answer_pitch_class': answerPitchClass,
        'answer_octave': answerOctave,
        'input_source': inputSource.wire,
        'context_snapshot': jsonEncode(contextSnapshot.toJson()),
      };

  factory Trial.fromRow(Map<String, Object?> row) => Trial(
        id: row['id'] as int?,
        sessionId: row['session_id'] as int,
        itemId: row['item_id'] as int,
        presentedAt: row['presented_at'] as int,
        answeredAt: row['answered_at'] as int?,
        rtMs: row['rt_ms'] as int?,
        correct: (row['correct'] as int) == 1,
        timeout: (row['timeout'] as int) == 1,
        hintLevelUsed: row['hint_level_used'] as int,
        hintRequested: (row['hint_requested'] as int) == 1,
        errorType: row['error_type'] == null
            ? null
            : ErrorType.fromWire(row['error_type'] as String),
        answerPitchClass: row['answer_pitch_class'] as String?,
        answerOctave: row['answer_octave'] as int?,
        inputSource: InputSource.fromWire(row['input_source'] as String),
        contextSnapshot: ContextSnapshot.fromJson(
            jsonDecode(row['context_snapshot'] as String)
                as Map<String, dynamic>),
      );
}