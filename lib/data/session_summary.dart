// 规格: 06 §2 S4 会话总结 / 02 §7.1 结束总结（稳定条目、激活/回退、错误分布、明日到期）。
// 数据只读：trial_log（本会话）+ mastery + item；事件来自引擎内存（本次会话累积）。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../core/clock.dart';
import '../core/config.dart';
import '../domain/item_label.dart';
import '../domain/mastery.dart' show MasteryEvent, PromotionEvent, RelapseEvent;
import '../domain/models/enums.dart';
import '../domain/scheduler.dart' show stable;
import 'repositories/item_repo.dart';
import 'repositories/mastery_repo.dart';
import 'repositories/trial_repo.dart';

/// 今天稳定的条目（S4 列表项）。
class SummaryStableItem {
  final String label;
  final ItemType type;
  final int intervalDays;
  const SummaryStableItem(this.label, this.type, this.intervalDays);
}

/// 错误类型分布（S4 小条形）。
class SummaryErrorStat {
  final ErrorType type;
  final int count;
  const SummaryErrorStat(this.type, this.count);
}

/// 会话总结数据（S4）。
class SessionSummaryData {
  final int doneCount; // 条目级完成数（PHRASE 计 1）
  final int trialCount; // 音级试次数
  final int correctCount;
  final int timeoutCount;
  final List<SummaryStableItem> stable;
  final List<int> promoted; // 新激活直认音位（diatonicIndex）
  final List<int> relapsed; // 回退音位
  final List<SummaryErrorStat> errors; // count 降序，不含 SLOW_CORRECT
  final int dueTomorrow;

  const SessionSummaryData({
    required this.doneCount,
    required this.trialCount,
    required this.correctCount,
    required this.timeoutCount,
    required this.stable,
    required this.promoted,
    required this.relapsed,
    required this.errors,
    required this.dueTomorrow,
  });

  double get accuracy => trialCount == 0 ? 0 : correctCount / trialCount;
}

/// 错误类型中文名（S4 展示）。
String errorTypeLabel(ErrorType t) => switch (t) {
      ErrorType.timeout => '超时',
      ErrorType.octave => '八度混淆',
      ErrorType.crossClef => '跨谱表混淆',
      ErrorType.anchorError => '锚点定位错',
      ErrorType.direction => '方向错',
      ErrorType.lineSpace => '线间混淆',
      ErrorType.distance => '距离错',
      ErrorType.slowCorrect => '慢而正确',
      ErrorType.other => '其他',
    };

/// 汇总本次会话（S4）。[events] 为引擎本次会话累积的掌握度事件。
Future<SessionSummaryData> loadSessionSummary({
  required Database db,
  required int sessionId,
  required Config config,
  required Clock clock,
  required int doneCount,
  List<MasteryEvent> events = const [],
}) async {
  final trials = await TrialRepo(db).bySession(sessionId);
  final itemIds = {for (final t in trials) t.itemId};
  final items = {
    for (final it in await ItemRepo(db).all())
      if (itemIds.contains(it.id)) it.id: it,
  };
  final masteries = {
    for (final m in await MasteryRepo(db).all()) m.itemId: m,
  };

  // 今天稳定：本会话作答过，且满足稳定判定或已自动化（05 §2）。
  final stableItems = <SummaryStableItem>[];
  for (final id in itemIds) {
    final m = masteries[id];
    final it = items[id];
    if (m == null || it == null) continue;
    if (m.state == ItemState.automated || stable(m, config)) {
      stableItems.add(
          SummaryStableItem(itemLabel(it), it.type, m.intervalDays.round()));
    }
  }
  stableItems.sort((a, b) => b.intervalDays.compareTo(a.intervalDays));

  // 错误类型分布（SLOW_CORRECT 是"慢而正确"，不算错误；超时计入 TIMEOUT）。
  final byType = <ErrorType, int>{};
  var correct = 0;
  var timeout = 0;
  for (final t in trials) {
    if (t.correct) correct++;
    if (t.timeout) timeout++;
    final e = t.errorType;
    if (e != null && e != ErrorType.slowCorrect) {
      byType[e] = (byType[e] ?? 0) + 1;
    }
  }
  final errors = [
    for (final e in byType.entries) SummaryErrorStat(e.key, e.value),
  ]..sort((a, b) => b.count.compareTo(a.count));

  // 明日到期（S4 预告）：due_at ∈ [明天 00:00, 后天 00:00) 且激活态。
  final tomorrow = clock.localDate().add(const Duration(days: 1));
  final from = clock.localMidnightUtcMs(tomorrow);
  final to = clock.localMidnightUtcMs(tomorrow.add(const Duration(days: 1)));
  final dueTomorrow = masteries.values.where((m) {
    final due = m.dueAt;
    if (due == null || due < from || due >= to) return false;
    return m.state == ItemState.learning ||
        m.state == ItemState.reviewing ||
        m.state == ItemState.automated;
  }).length;

  final promoted = <int>[];
  final relapsed = <int>[];
  for (final ev in events) {
    switch (ev) {
      case PromotionEvent():
        if (!promoted.contains(ev.diatonicIndex)) promoted.add(ev.diatonicIndex);
      case RelapseEvent():
        if (!relapsed.contains(ev.diatonicIndex)) relapsed.add(ev.diatonicIndex);
      default:
        break;
    }
  }

  return SessionSummaryData(
    doneCount: doneCount,
    trialCount: trials.length,
    correctCount: correct,
    timeoutCount: timeout,
    stable: stableItems,
    promoted: promoted,
    relapsed: relapsed,
    errors: errors,
    dueTomorrow: dueTomorrow,
  );
}
