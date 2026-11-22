// 规格: 05 §4 掌握度状态机（自动化/晋升/回退/锚点重建立）/ 02 §2.2 §4 / 04 mastery。
// 纯函数：输入 Mastery + 试次历史，输出更新后 Mastery + 事件；编排由会话引擎执行。
//
// 契约缺口（局部裁决）：
// 1) 04 last_results 截断 10 条，但自动化窗口=20（05 §4）——checkAutomation 接收
//    调用方（数据层/会话引擎）提供的更长试次历史 recentResults，不依赖 Mastery.lastResults。
// 2) settings 无"锚点重建立连错阈值"键——局部常量 _anchorRebuildStreak=3（05 §4 / 02 §2.2）。
library;

import '../core/config.dart';
import 'hint_machine.dart';
import 'models/enums.dart';
import 'models/mastery.dart';
import 'models/note_position.dart';

/// 锚点重建立触发连错数（05 §4：ANCHOR 连续 3 题错）。契约缺口见文件头。
const int _anchorRebuildStreak = 3;

/// 掌握度事件（由会话引擎消费编排）。
sealed class MasteryEvent {
  const MasteryEvent();
}

/// DIRECT 晋升（含 relapsed 再迁移）：inactive/relapsed → learning。
class PromotionEvent extends MasteryEvent {
  final int diatonicIndex;
  final int directItemId;
  const PromotionEvent({
    required this.diatonicIndex,
    required this.directItemId,
  });
}

/// DIRECT 回退：需重新激活的 RELATION 列表（state=learning、hintLevel=3、dueAt=now，
/// 由会话引擎对每个 relationItemId 调用 resetRelationForRelapse 执行）。
class RelapseEvent extends MasteryEvent {
  final int diatonicIndex;
  final int directItemId;
  final List<int> relationItemIds;
  final int resetHintLevel;
  final int dueAt;
  const RelapseEvent({
    required this.diatonicIndex,
    required this.directItemId,
    required this.relationItemIds,
    required this.resetHintLevel,
    required this.dueAt,
  });
}

/// 锚点重建立微循环触发（展示卡 + 5 题不限时慢练由会话引擎编排，02 §2.2）。
class RebuildTriggerEvent extends MasteryEvent {
  final int anchorItemId;
  const RebuildTriggerEvent({required this.anchorItemId});
}

/// 更新结果：新 Mastery + 本次触发的事件。
class MasteryUpdate {
  final Mastery mastery;
  final List<MasteryEvent> events;
  const MasteryUpdate(this.mastery, [this.events = const []]);
}

/// 末尾连续错误数。
int trailingWrongStreak(List<TrialResult> results) {
  var n = 0;
  for (final r in results.reversed) {
    if (r.correct) break;
    n++;
  }
  return n;
}

/// 自动化判定（ANCHOR/DIRECT，每次作答后调用，05 §4）。
/// recentResults 为按时间升序的试次历史；取最近 window 条，不足不判。
/// 条件：acc>=阈值 且 无提示子集 rtMedian<=阈值 且 窗口内全部 hintLevel==0。
MasteryUpdate checkAutomation(
  Mastery m,
  List<TrialResult> recentResults,
  ItemType type,
  Config config,
) {
  final int window;
  final double accMin;
  final int rtMax;
  switch (type) {
    case ItemType.anchor:
      window = config.anchorAutoWindow;
      accMin = config.anchorAutoAcc;
      rtMax = config.anchorAutoRtMs;
    case ItemType.direct:
      window = config.directAutoWindow;
      accMin = config.directAutoAcc;
      rtMax = config.directAutoRtMs;
    case ItemType.relation:
    case ItemType.phrase:
      return MasteryUpdate(m); // 仅 ANCHOR/DIRECT 有自动化判定。
  }
  if (recentResults.length < window) return MasteryUpdate(m);
  final w = recentResults.sublist(recentResults.length - window);
  final acc = w.where((r) => r.correct).length / w.length;
  final allNoHint = w.every((r) => r.hintLevel == 0);
  final median = rtMedianOf(
      w.where((r) => r.hintLevel == 0).map((r) => r.rtMs));
  if (acc >= accMin &&
      allNoHint &&
      median != null &&
      median <= rtMax &&
      m.state != ItemState.automated) {
    return MasteryUpdate(m.copyWith(state: ItemState.automated));
  }
  return MasteryUpdate(m);
}

/// DIRECT 晋升检查（每次 RELATION 作答后检查目标音位 p，05 §4 / 02 §4.1 §4.3）。
/// relationHistory = 所有以 p 为目标的 RELATION 试次（时间升序）；取最近 promoteStreak 条。
/// 满足且 state∈{inactive, relapsed} → learning、dueAt=now、hintLevel=0（DIRECT 无提示）。
MasteryUpdate checkPromotion({
  required Mastery direct,
  required int diatonicIndex,
  required List<TrialResult> relationHistory,
  required Config config,
  required int nowMs,
}) {
  final streak = config.promoteStreak;
  if (relationHistory.length < streak) return MasteryUpdate(direct);
  final last = relationHistory.sublist(relationHistory.length - streak);
  final allCorrect = last.every((r) => r.correct);
  final allNoHint = last.every((r) => r.hintLevel == 0);
  final median = rtMedianOf(last.map((r) => r.rtMs));
  final rtMax = isLedger(diatonicIndex)
      ? config.promoteRtLedgerMs
      : config.promoteRtMs;
  final eligible = direct.state == ItemState.inactive ||
      direct.state == ItemState.relapsed; // relapsed 再迁移（05 §4）。
  if (allCorrect &&
      allNoHint &&
      median != null &&
      median <= rtMax &&
      eligible) {
    return MasteryUpdate(
      direct.copyWith(
        state: ItemState.learning,
        dueAt: () => nowMs,
        hintLevel: 0,
      ),
      [
        PromotionEvent(
          diatonicIndex: diatonicIndex,
          directItemId: direct.itemId,
        ),
      ],
    );
  }
  return MasteryUpdate(direct);
}

/// DIRECT 回退检查（05 §4 / 02 §4.3）：连续 relapseDirectStreak 题错 → relapsed。
/// relationItemIds = 涉及音位 p 的 RELATION 条目 id 列表（由调用方提供）。
/// 裁决：仅 learning/reviewing/automated 状态可回退；inactive 未激活、relapsed 已挂起。
MasteryUpdate checkRelapse({
  required Mastery direct,
  required int diatonicIndex,
  required List<int> relationItemIds,
  required Config config,
  required int nowMs,
}) {
  final active = direct.state == ItemState.learning ||
      direct.state == ItemState.reviewing ||
      direct.state == ItemState.automated;
  if (active &&
      trailingWrongStreak(direct.lastResults) >= config.relapseDirectStreak) {
    return MasteryUpdate(
      direct.copyWith(state: ItemState.relapsed),
      [
        RelapseEvent(
          diatonicIndex: diatonicIndex,
          directItemId: direct.itemId,
          relationItemIds: relationItemIds,
          resetHintLevel: config.hintInitialLevel,
          dueAt: nowMs,
        ),
      ],
    );
  }
  return MasteryUpdate(direct);
}

/// 回退时重新激活 RELATION（由会话引擎按 RelapseEvent 执行）：
/// state=learning、hintLevel=hintInitialLevel(3)、dueAt=now。
Mastery resetRelationForRelapse(
  Mastery relation, {
  required int nowMs,
  required Config config,
}) =>
    relation.copyWith(
      state: ItemState.learning,
      hintLevel: config.hintInitialLevel,
      dueAt: () => nowMs,
    );

/// 锚点重建立触发（05 §4 / 02 §2.2）：连续 3 题错 → RebuildTriggerEvent。
/// 展示卡 + 5 题慢练由会话引擎编排；重复触发去重由引擎负责。Mastery 本身不变。
MasteryUpdate checkAnchorRebuild(Mastery anchor, Config config) {
  if (trailingWrongStreak(anchor.lastResults) >= _anchorRebuildStreak) {
    return MasteryUpdate(
      anchor,
      [RebuildTriggerEvent(anchorItemId: anchor.itemId)],
    );
  }
  return MasteryUpdate(anchor);
}

/// 追加试次结果：lastResults 截断 10、rtMedian（无提示子集）、hintDependency（最近10）。
/// 裁决：rtMedian 按最近 10 条无提示子集重算，空子集置 null。
Mastery applyTrial(Mastery m, TrialResult r, Config config) {
  final results = m.appendedResults(r);
  final median = rtMedianOf(
      results.where((t) => t.hintLevel == 0).map((t) => t.rtMs));
  return m.copyWith(
    lastResults: results,
    rtMedian: () => median,
    hintDependency: HintMachine.hintDependency(results, config),
  );
}