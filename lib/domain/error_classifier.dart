// 规格: 05 §5 错误类型判定（唯一优先级，裁决 02 §3.5 排序歧义）/ 02 §10.1。
// 规则层只按作答模式（音名/键盘，即 answer 是否含 octave）区分，禁止按 InputSource 分支。
library;

import '../core/config.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/note_position.dart';

/// 判定结果：errorType=null 表示正确且非慢；
/// seedPair=(min(targetIndex,answerIndex), max(...))，供数据层写 confusion_seed
/// （count+1 由仓库执行，05 §5）。
typedef Classification = ({ErrorType? errorType, (int, int)? seedPair});

/// answerIndex = 与 target 同八度区域内 pitchClass==answer 的最近音位：
/// 在 target±6 自然音级内找 pitchClass 匹配、|差|最小者（05 §5）。
int? _answerIndexOf(int targetIndex, String? answerPitchClass) {
  if (answerPitchClass == null) return null;
  int? best;
  for (var i = targetIndex - 6; i <= targetIndex + 6; i++) {
    if (pitchClassOf(i) != answerPitchClass) continue;
    if (best == null ||
        (i - targetIndex).abs() < (best - targetIndex).abs()) {
      best = i;
    }
  }
  return best;
}

int _sign(int x) => x > 0 ? 1 : (x < 0 ? -1 : 0);

/// 05 §5 唯一优先级 1..9。
/// 裁决：规则 2–7 仅在 !correct 时评估——正确试次只可能命中规则 8（SLOW_CORRECT）
/// 或 null，避免退化链（净位移 0）把正确答案误判为 ANCHOR_ERROR。
Classification classify({
  required Item item,
  required int targetIndex,
  required String? answerPitchClass,
  int? answerOctave,
  required InputMode mode,
  required int stage,
  required int rtMs,
  bool timeout = false,
  required bool correct,
  required Config config,
}) {
  final answerIndex = _answerIndexOf(targetIndex, answerPitchClass);
  final targetPc = pitchClassOf(targetIndex);

  ErrorType? type;
  // 1. 超时（记错）。
  if (timeout) {
    type = ErrorType.timeout;
  } else if (!correct) {
    // 2. 含八度输入（虚拟键盘/电钢琴）且音名同、八度不同。
    if (mode.includesOctave &&
        answerOctave != null &&
        answerPitchClass == targetPc &&
        answerOctave != octaveOf(targetIndex)) {
      type = ErrorType.octave;
    }
    // 3. 阶段>=3：另一谱表同视觉位置（自然音级差 ±12，且该位置在池内）。
    if (type == null && stage >= 3 && answerPitchClass != null) {
      for (final offset in const [12, -12]) {
        final other = targetIndex + offset;
        if (inPool(other) && pitchClassOf(other) == answerPitchClass) {
          type = ErrorType.crossClef;
          break;
        }
      }
    }
    final relation =
        item.type == ItemType.relation ? item.payload as RelationPayload : null;
    // 4. RELATION 且答案=锚点音名（用户根本没推导，优先于距离/方向）。
    if (type == null &&
        relation != null &&
        answerPitchClass == pitchClassOf(relation.anchorIndex)) {
      type = ErrorType.anchorError;
    }
    // 5. RELATION 且相对锚点方向相反。
    if (type == null && relation != null && answerIndex != null) {
      final anchor = relation.anchorIndex;
      if (_sign(answerIndex - anchor) != _sign(targetIndex - anchor)) {
        type = ErrorType.direction;
      }
    }
    // 6/7. 相邻线间 / 二度三度混淆。
    if (type == null && answerIndex != null) {
      final d = (answerIndex - targetIndex).abs();
      if (d == 1) type = ErrorType.lineSpace;
      if (d == 2) type = ErrorType.distance;
    }
    type ??= ErrorType.other; // 9. 其余错误。
  } else if (rtMs > config.slowCorrectRtMs) {
    // 8. 慢而正确（correct 保持 1，单独标记）。
    type = ErrorType.slowCorrect;
  }

  // 错误试次写 confusion_seed pair（SLOW_CORRECT 不算错；超时通常无作答题）。
  (int, int)? seedPair;
  if (type != null &&
      type != ErrorType.slowCorrect &&
      answerIndex != null) {
    seedPair = answerIndex < targetIndex
        ? (answerIndex, targetIndex)
        : (targetIndex, answerIndex);
  }
  return (errorType: type, seedPair: seedPair);
}