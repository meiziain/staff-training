// 规格: 02 §6.1 §8.3 / 04 mastery 表。不可变模型，状态变更走 copyWith（03 §6）。
library;

import 'dart:convert';

import 'enums.dart';

/// 最近作答结果（04 last_results 元素：{correct,rtMs,hintLevel,ts}）。
class TrialResult {
  final bool correct;
  final int rtMs;
  final int hintLevel;
  final int ts;

  const TrialResult({
    required this.correct,
    required this.rtMs,
    required this.hintLevel,
    required this.ts,
  });

  Map<String, dynamic> toJson() =>
      {'correct': correct, 'rtMs': rtMs, 'hintLevel': hintLevel, 'ts': ts};

  factory TrialResult.fromJson(Map<String, dynamic> j) => TrialResult(
        correct: j['correct'] as bool,
        rtMs: j['rtMs'] as int,
        hintLevel: j['hintLevel'] as int,
        ts: j['ts'] as int,
      );
}

/// 条目掌握度（与 item 一对一）。
class Mastery {
  final int itemId;
  final ItemState state;
  final double ease;
  final double intervalDays;
  final int? dueAt; // UTC ms；learning 阶段为会话末时间戳
  final int reps;
  final int lapses;
  final int hintLevel;
  final double hintDependency;
  final int? rtMedian; // 无提示作答 RT 中位数 ms
  final List<TrialResult> lastResults; // 最近10次
  final List<String> contextTags;

  const Mastery({
    required this.itemId,
    this.state = ItemState.inactive,
    this.ease = 2.5,
    this.intervalDays = 0,
    this.dueAt,
    this.reps = 0,
    this.lapses = 0,
    this.hintLevel = 3,
    this.hintDependency = 0,
    this.rtMedian,
    this.lastResults = const [],
    this.contextTags = const [],
  });

  Mastery copyWith({
    ItemState? state,
    double? ease,
    double? intervalDays,
    int? Function()? dueAt,
    int? reps,
    int? lapses,
    int? hintLevel,
    double? hintDependency,
    int? Function()? rtMedian,
    List<TrialResult>? lastResults,
    List<String>? contextTags,
  }) =>
      Mastery(
        itemId: itemId,
        state: state ?? this.state,
        ease: ease ?? this.ease,
        intervalDays: intervalDays ?? this.intervalDays,
        dueAt: dueAt != null ? dueAt() : this.dueAt,
        reps: reps ?? this.reps,
        lapses: lapses ?? this.lapses,
        hintLevel: hintLevel ?? this.hintLevel,
        hintDependency: hintDependency ?? this.hintDependency,
        rtMedian: rtMedian != null ? rtMedian() : this.rtMedian,
        lastResults: lastResults ?? this.lastResults,
        contextTags: contextTags ?? this.contextTags,
      );

  /// 追加一条结果并截断到最近 10 条（04 口径）。
  List<TrialResult> appendedResults(TrialResult r) =>
      [...lastResults, r].length > 10
          ? [...lastResults, r].sublist([...lastResults, r].length - 10)
          : [...lastResults, r];

  Map<String, Object?> toRow() => {
        'item_id': itemId,
        'state': state.wire,
        'ease': ease,
        'interval_days': intervalDays,
        'due_at': dueAt,
        'reps': reps,
        'lapses': lapses,
        'hint_level': hintLevel,
        'hint_dependency': hintDependency,
        'rt_median': rtMedian,
        'last_results': jsonEncode(lastResults.map((e) => e.toJson()).toList()),
        'context_tags': jsonEncode(contextTags),
      };

  factory Mastery.fromRow(Map<String, Object?> row) => Mastery(
        itemId: row['item_id'] as int,
        state: ItemState.fromWire(row['state'] as String),
        ease: (row['ease'] as num).toDouble(),
        intervalDays: (row['interval_days'] as num).toDouble(),
        dueAt: row['due_at'] as int?,
        reps: row['reps'] as int,
        lapses: row['lapses'] as int,
        hintLevel: row['hint_level'] as int,
        hintDependency: (row['hint_dependency'] as num).toDouble(),
        rtMedian: row['rt_median'] as int?,
        lastResults: (jsonDecode(row['last_results'] as String) as List)
            .map((e) => TrialResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        contextTags: (jsonDecode(row['context_tags'] as String) as List)
            .map((e) => e as String)
            .toList(),
      );
}

/// RT 中位数（偶数个取中间两数平均后四舍五入；空集返回 null）。
int? rtMedianOf(Iterable<int> values) {
  final v = values.toList()..sort();
  if (v.isEmpty) return null;
  final n = v.length;
  return n.isOdd ? v[n ~/ 2] : ((v[n ~/ 2 - 1] + v[n ~/ 2]) / 2).round();
}