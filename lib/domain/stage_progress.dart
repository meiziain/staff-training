// 首页阶段进度卡数据（02 §2.2 自动化三条件 / §3.1 阶段表 / 05 §4 §10）。
// 纯 Dart：只读统计，判定口径与 mastery.checkAutomation / course.advanceRatio 一致。
library;

import '../core/config.dart';
import 'course.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/mastery.dart';
import 'models/note_position.dart';
import 'scheduler.dart' as sched;

/// 单个锚点的自动化达标进度（窗口口径 = checkAutomation：最近 window 条）。
class AnchorAutomationProgress {
  final int diatonicIndex;
  final bool automated;

  /// 窗口内已积累题数（上限 window）。
  final int windowCount;
  final int window;

  /// 窗口内正确率；无试次为 null。
  final double? accuracy;

  /// 窗口内无提示子集 RT 中位数；子集为空为 null。
  final int? rtMedianMs;

  /// 窗口内使用提示的题数。
  final int hintCount;

  final double accMin;
  final int rtMaxMs;

  const AnchorAutomationProgress({
    required this.diatonicIndex,
    required this.automated,
    required this.windowCount,
    required this.window,
    required this.accuracy,
    required this.rtMedianMs,
    required this.hintCount,
    required this.accMin,
    required this.rtMaxMs,
  });

  bool get windowFull => windowCount >= window;
  bool get accOk =>
      windowFull && accuracy != null && accuracy! >= accMin;
  bool get rtOk =>
      windowFull && rtMedianMs != null && rtMedianMs! <= rtMaxMs;
  bool get hintOk => windowFull && hintCount == 0;

  factory AnchorAutomationProgress.of({
    required int diatonicIndex,
    required Mastery mastery,
    required List<TrialResult> history,
    required Config config,
  }) {
    final window = config.anchorAutoWindow;
    final from = history.length > window ? history.length - window : 0;
    final w = history.sublist(from);
    final acc = w.isEmpty
        ? null
        : w.where((r) => r.correct).length / w.length;
    return AnchorAutomationProgress(
      diatonicIndex: diatonicIndex,
      automated: mastery.state == ItemState.automated,
      windowCount: w.length,
      window: window,
      accuracy: acc,
      rtMedianMs:
          rtMedianOf(w.where((r) => r.hintLevel == 0).map((r) => r.rtMs)),
      hintCount: w.where((r) => r.hintLevel > 0).length,
      accMin: config.anchorAutoAcc,
      rtMaxMs: config.anchorAutoRtMs,
    );
  }
}

/// 阶段核心条目达标进度（阶段0=自动化数，其余=stable 数；口径同 advanceRatio）。
class StageCoreProgress {
  final int okCount;
  final int coreCount;
  final double requiredRatio;

  const StageCoreProgress({
    required this.okCount,
    required this.coreCount,
    required this.requiredRatio,
  });

  double get ratio => coreCount == 0 ? 0 : okCount / coreCount;
  bool get met => coreCount > 0 && ratio >= requiredRatio;

  factory StageCoreProgress.of({
    required int stage,
    required List<Item> items,
    required Map<int, Mastery> masteries,
    required Set<int> activeAnchors,
    required Config config,
  }) {
    final core = coreItemsOf(stage, items, activeAnchors);
    final ok = core.where((it) {
      final m = masteries[it.id];
      if (m == null) return false;
      return stage == 0 ? m.state == ItemState.automated : sched.stable(m, config);
    }).length;
    return StageCoreProgress(
      okCount: ok,
      coreCount: core.length,
      requiredRatio: config.stageAdvanceRatio,
    );
  }
}

/// 单个核心条目的稳定达标进度（阶段1+；口径 = scheduler.stable 四条件）。
/// 首页进度卡逐条展示：间隔天数 / 提示依赖 / 最近连对，点按展开明细。
class CoreItemStableProgress {
  final Item item;
  final Mastery mastery;
  final bool stable;
  final int minIntervalDays;
  final double hintDepMax;
  final int streakWindow;

  const CoreItemStableProgress({
    required this.item,
    required this.mastery,
    required this.stable,
    required this.minIntervalDays,
    required this.hintDepMax,
    required this.streakWindow,
  });

  bool get stateOk =>
      mastery.state == ItemState.reviewing ||
      mastery.state == ItemState.automated;
  bool get intervalOk => mastery.intervalDays >= minIntervalDays;
  bool get hintDepOk => mastery.hintDependency <= hintDepMax;
  bool get streakOk {
    final r = mastery.lastResults;
    return r.length >= streakWindow &&
        r.sublist(r.length - streakWindow).every((e) => e.correct);
  }

  /// 最近 streakWindow 次中答对数（不足窗口按已有条数计）。
  int get streakCorrect {
    final r = mastery.lastResults;
    final from = r.length > streakWindow ? r.length - streakWindow : 0;
    return r.sublist(from).where((e) => e.correct).length;
  }

  int get resultCount => mastery.lastResults.length;

  /// 行内紧凑标签：关系 C4→D4（链 C4⇢G4）；短句为音名序列。
  String get label {
    final p = item.payload;
    if (p is RelationPayload) {
      final a = NotePosition.of(p.anchorIndex).displayName;
      final t = NotePosition.of(p.targetIndex).displayName;
      return p.isChain ? '$a⇢$t' : '$a→$t';
    }
    if (p is PhrasePayload) {
      return p.noteSequence
          .map((i) => NotePosition.of(i).displayName)
          .join(' ');
    }
    return NotePosition.of(item.targetIndices.first).displayName;
  }

  /// 展开明细用完整标签：链展示逐步路径。
  String get fullLabel {
    final p = item.payload;
    if (p is RelationPayload && p.isChain) {
      final path = [p.anchorIndex, ...p.chain.map((s) => s.targetIndex)];
      return path.map((i) => NotePosition.of(i).displayName).join('→');
    }
    return label;
  }

  factory CoreItemStableProgress.of({
    required Item item,
    required Mastery mastery,
    required Config config,
  }) =>
      CoreItemStableProgress(
        item: item,
        mastery: mastery,
        stable: sched.stable(mastery, config),
        minIntervalDays: config.stableMinIntervalDays,
        hintDepMax: config.hintDepStableMax,
        streakWindow: config.stableStreak,
      );
}