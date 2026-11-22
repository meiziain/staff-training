// 规格: 05 §7 提示状态机 / 02 §3.4 分层提示与淡出 / 04 settings 种子。
// 不可变状态，所有变更返回新实例（03 §6）。阈值全部来自 Config。
library;

import '../core/config.dart';
import 'models/enums.dart';
import 'models/mastery.dart';

/// 提示状态机（仅 RELATION 条目使用；DIRECT/ANCHOR 闪现恒 0，无提示入口）。
class HintMachine {
  final int level; // 0..5
  final int cleanStreak; // 连续"零提示且 RT 达标"的正确题数
  final int consecutiveFail; // 连续错误题数

  const HintMachine({
    required this.level,
    this.cleanStreak = 0,
    this.consecutiveFail = 0,
  });

  /// 新 RELATION 初始级 = config.hintInitialLevel（默认 3）。
  factory HintMachine.initial(Config config) =>
      HintMachine(level: config.hintInitialLevel);

  /// 微课练习期 = config.microLessonLevel（默认 5，02 §3.3）。
  factory HintMachine.microLesson(Config config) =>
      HintMachine(level: config.microLessonLevel);

  /// DIRECT/ANCHOR 闪现题恒 0（05 §7：无提示入口）。
  factory HintMachine.flash() => const HintMachine(level: 0);

  /// 05 §7 onCorrect：连续 3 题零提示且 RT<=2000 → 降 1 级。
  HintMachine onCorrect({
    required int rtMs,
    required int hintLevelUsed,
    required Config config,
  }) {
    var streak = (hintLevelUsed == 0 && rtMs <= config.hintDowngradeRtMs)
        ? cleanStreak + 1
        : 0;
    var newLevel = level;
    if (streak >= config.hintDowngradeStreak && newLevel > 0) {
      newLevel -= 1;
      streak = 0;
    }
    return HintMachine(
      level: newLevel,
      cleanStreak: streak,
      consecutiveFail: 0,
    );
  }

  /// 05 §7 onWrong：只升到能纠正该错误类型的最低必要层级；连续 2 次失败给答案。
  HintMachine onWrong({
    required ErrorType errorType,
    required Config config,
  }) {
    final fail = consecutiveFail + 1;
    // 裁决：SLOW_CORRECT 不算错（05 §5 规则8），不会进入 onWrong；
    // 若误传入则按 OTHER 兜底（need=2）。
    final need = switch (errorType) {
      ErrorType.direction => 1,
      ErrorType.distance => 2,
      ErrorType.lineSpace => 2,
      ErrorType.anchorError => 4,
      ErrorType.octave => 4,
      ErrorType.crossClef => 4,
      ErrorType.timeout => 2,
      ErrorType.other => 2,
      ErrorType.slowCorrect => 2,
    };
    var newLevel = level > need ? level : need;
    if (fail >= 2) newLevel = config.microLessonLevel; // 级5=直接给答案
    return HintMachine(
      level: newLevel,
      cleanStreak: 0,
      consecutiveFail: fail,
    );
  }

  /// 05 §7 hintDependency：最近 10 题加权提示使用率。
  /// weights 级0..5 = [0, ...config.hintDepWeights]；不足 10 条按实际条数除；空集为 0。
  /// 级5完成该题 correct=0 由调用方（会话引擎）保证。
  static double hintDependency(List<TrialResult> last10, Config config) {
    if (last10.isEmpty) return 0;
    final weights = <double>[0, ...config.hintDepWeights];
    var sum = 0.0;
    for (final t in last10) {
      sum += weights[t.hintLevel.clamp(0, weights.length - 1)];
    }
    return sum / last10.length;
  }
}