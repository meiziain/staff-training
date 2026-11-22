// 规格: 视奏训练改进 P0 T03 —— 旧「提交即推进」语义的独立引擎。
//
// 用于分手练习 / 自由练习入口（Q1 裁决）：答对才推进、答错不动，可「单谱走」
// （先走完一个声部再走另一个）。与拍网格引擎 SightSessionEngine 并列，互不复用
// 判定逻辑，避免任何一方的语义被悄悄改写。
library;

import 'models/sight_score.dart';
import 'sight_engine.dart';

/// 自由练习（无拍网格判定）双光标引擎：保留 T03 之前的原始语义。
class SightFreeEngine {
  final SightScore score;
  final SightVoiceTrack? upper;
  final SightVoiceTrack? lower;

  /// 连错多少次触发一次音名提示。
  final int hintThreshold;

  int _correct = 0;
  int _errors = 0;
  int _streak = 0;
  final Map<int, int> _errorPositions = {};

  SightFreeEngine(this.score, {this.hintThreshold = 3})
      : upper = buildSightVoiceTrack(score, SightVoice.upper),
        lower = buildSightVoiceTrack(score, SightVoice.lower) {
    if (upper == null && lower == null) {
      throw ArgumentError('谱例没有任何音（mode=${score.mode.wire}）');
    }
  }

  /// 全谱总音数。
  int get totalNotes => (upper?.notes.length ?? 0) + (lower?.notes.length ?? 0);

  /// 已答对音数（答对才推进，故等于已完成音数）。
  int get correctNotes => _correct;

  /// 累计错误次数。
  int get errorCount => _errors;

  /// 逐音错误计数（diatonicIndex → 次数）。
  Map<int, int> get errorPositions => Map.unmodifiable(_errorPositions);

  /// 自上次答对以来的连续错误数。
  int get errorStreak => _streak;

  bool get finished => (upper?.done ?? true) && (lower?.done ?? true);

  double get progress => totalNotes == 0
      ? 1
      : ((upper?.cursor ?? 0) + (lower?.cursor ?? 0)) / totalNotes;

  /// 当前待答的音（0–2 个）。
  List<SightNote> get pending => [
        if (upper?.current != null) upper!.current!,
        if (lower?.current != null) lower!.current!,
      ];

  /// 某声部当前光标所在列；该声部已完成时为 null。
  int? cursorColumnOf(SightVoice voice) =>
      voice == SightVoice.upper ? upper?.current?.column : lower?.current?.column;

  /// 提交一次音高作答：匹配则推进该声部光标，错则任何光标都不动。
  SightSubmitResult submit(int diatonicIndex) {
    if (finished) {
      throw StateError('视奏已结束，不可再提交');
    }
    // 先上后下：两侧同音时本次只满足上声部。
    final u = upper?.current;
    if (u != null && u.diatonicIndex == diatonicIndex) {
      upper!.cursor++;
      return _accepted(SightVoice.upper, u);
    }
    final l = lower?.current;
    if (l != null && l.diatonicIndex == diatonicIndex) {
      lower!.cursor++;
      return _accepted(SightVoice.lower, l);
    }
    _errors++;
    _streak++;
    final target = pending.first;
    _errorPositions[target.diatonicIndex] =
        (_errorPositions[target.diatonicIndex] ?? 0) + 1;
    return SightSubmitResult(
      accepted: false,
      hintDue: _streak % hintThreshold == 0,
      finished: finished,
    );
  }

  SightSubmitResult _accepted(SightVoice voice, SightNote note) {
    _correct++;
    _streak = 0;
    return SightSubmitResult(
      accepted: true,
      voice: voice,
      note: note,
      finished: finished,
    );
  }
}
