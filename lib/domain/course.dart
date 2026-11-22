// 规格: 05 §1 条目生成 / §10 阶段推进；02 §3.1 阶段表 §3.2 关系条目 §4.1 DIRECT 初始；
// 04 item.payload JSON 口径。纯 Dart（03 §2）：时钟注入 Clock，阈值来自 Config。
//
// 契约：新建 Item 的 id 与 Mastery.itemId 均为占位 0（ItemRepo.insert 忽略占位 id，
// 返回自增 id）；调用方落库后须以真实 id 重建 Mastery 绑定。
library;

import '../core/clock.dart';
import '../core/config.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/mastery.dart';
import 'models/note_position.dart';
import 'scheduler.dart' show isCoreItem, stable;

typedef NewItem = (Item, Mastery);

/// 05 §1：每个 active_anchors 音位一个 ANCHOR 条目（已存在不重复）。
/// ANCHOR 初始 learning、dueAt=now；闪现题无提示入口，hintLevel 恒 0（05 §7）。
List<NewItem> ensureAnchorItems(
    Set<int> activeAnchors, List<Item> existing, Clock clock,
    {Config config = Config.defaults}) {
  final have = existing
      .where((it) => it.type == ItemType.anchor)
      .map((it) => (it.payload as AnchorPayload).diatonicIndex)
      .toSet();
  final now = clock.nowUtcMs();
  final sorted = activeAnchors.toList()..sort();
  return [
    for (final a in sorted)
      if (!have.contains(a))
        (
          Item(
            id: 0,
            type: ItemType.anchor,
            payload: AnchorPayload(diatonicIndex: a),
            createdAt: now,
          ),
          Mastery(
            itemId: 0,
            state: ItemState.learning,
            ease: config.easeInit,
            dueAt: now,
            hintLevel: 0,
          ),
        ),
  ];
}

/// 05 §1 / 02 §4.1：22 音位各一个 DIRECT；初始 inactive，锚点音位初始 learning。
/// DIRECT 题型无提示，hintLevel 恒 0（05 §7）。
List<NewItem> ensureDirectItems(
    List<Item> existing, Set<int> activeAnchors, Clock clock,
    {Config config = Config.defaults}) {
  final have = existing
      .where((it) => it.type == ItemType.direct)
      .map((it) => (it.payload as DirectPayload).diatonicIndex)
      .toSet();
  final now = clock.nowUtcMs();
  return [
    for (final i in pool)
      if (!have.contains(i))
        (
          Item(
            id: 0,
            type: ItemType.direct,
            payload: DirectPayload(diatonicIndex: i),
            createdAt: now,
          ),
          Mastery(
            itemId: 0,
            state:
                activeAnchors.contains(i) ? ItemState.learning : ItemState.inactive,
            ease: config.easeInit,
            dueAt: activeAnchors.contains(i) ? now : null,
            hintLevel: 0,
          ),
        ),
  ];
}

/// RELATION payload 规范化键：按链逐步 "anchor:dir:steps" 拼接。
/// 单元素链与单步写法视为同一 payload（04 两种 JSON 形态语义等价）。
String _relationKey(RelationPayload p) =>
    p.chain.map((s) => '${s.anchorIndex}:${s.direction}:${s.steps}').join('|');

/// 05 §1：按阶段惰性生成 RELATION 条目，返回需新建的 (Item, Mastery) 列表。
/// 阶段1：高音区锚点 ±二度（steps2，目标∈trebleRange）；
/// 阶段2：高音区锚点 ±三度（steps3，目标∈trebleRange）；
/// 阶段3：两步链（每步 ±1/±2 自然音级，中间音与终点∈池）+ 低音锚点单步；
/// 阶段4/5：不新增 RELATION（PHRASE 由 phrase_generator 产出）。
///
/// 裁决1：05 §1 低音锚点"±2/±3 单步"按 02 §3.2"MVP 只生成二度/三度"与
/// RelationStep 契约（steps 2=二度/3=三度）解释为 steps∈{2,3}（±二度/±三度）。
/// 裁决2：低音锚点按 anchorIndex<0 判定（与 scheduler.isCoreItem 阶段3 口径一致；
/// 候选中负值仅 F3=-4、C3=-7）。
/// 裁决3：两步链不排除净位移为 0（回到锚点）的链——05 §1 未排除。
/// 新 RELATION：state=learning、hintLevel=config.hintInitialLevel、dueAt=now。
List<NewItem> relationItemsForStage(
    int stage, Set<int> activeAnchors, List<Item> existing, Clock clock,
    {Config config = Config.defaults}) {
  if (stage < 0 || stage > 3) return const [];

  final have = existing
      .where((it) => it.type == ItemType.relation)
      .map((it) => _relationKey(it.payload as RelationPayload))
      .toSet();
  final now = clock.nowUtcMs();
  final anchors = activeAnchors.toList()..sort();
  final payloads = <RelationPayload>[];

  void addSingle(int a, int dir, int steps, bool Function(int) inRange) {
    final target = a + dir * (steps - 1);
    if (inRange(target)) {
      payloads.add(
          RelationPayload.single(anchorIndex: a, direction: dir, steps: steps));
    }
  }

  switch (stage) {
    // 阶段 0：锚点建立期也要有"邻近音穿插"（02 §2.2 锚点题之间插入邻近音位题，
    // 防止只记屏幕绝对位置）。内容与阶段 1 相同（±二度、高音谱表内），
    // 但初始提示级取微课满级（相当于带答案练）。
    case 0:
    case 1:
      for (final a in anchors.where(inTrebleRange)) {
        for (final dir in const [1, -1]) {
          addSingle(a, dir, 2, inTrebleRange);
        }
      }
    case 2:
      for (final a in anchors.where(inTrebleRange)) {
        for (final dir in const [1, -1]) {
          addSingle(a, dir, 3, inTrebleRange);
        }
      }
    case 3:
      for (final a in anchors) {
        for (final d1 in const [1, -1]) {
          for (final s1 in const [2, 3]) {
            final mid = a + d1 * (s1 - 1);
            if (!inPool(mid)) continue;
            for (final d2 in const [1, -1]) {
              for (final s2 in const [2, 3]) {
                final target = mid + d2 * (s2 - 1);
                if (!inPool(target)) continue;
                payloads.add(RelationPayload.chain([
                  RelationStep(anchorIndex: a, direction: d1, steps: s1),
                  RelationStep(anchorIndex: mid, direction: d2, steps: s2),
                ]));
              }
            }
          }
        }
      }
      for (final a in anchors.where((a) => a < 0)) {
        for (final dir in const [1, -1]) {
          for (final steps in const [2, 3]) {
            addSingle(a, dir, steps, inPool);
          }
        }
      }
  }

  final result = <NewItem>[];
  for (final p in payloads) {
    final key = _relationKey(p);
    if (have.contains(key)) continue;
    have.add(key);
    result.add((
      Item(id: 0, type: ItemType.relation, payload: p, createdAt: now),
      Mastery(
        itemId: 0,
        state: ItemState.learning,
        ease: config.easeInit,
        dueAt: now,
        // 新条目初始提示级 = 3（02 §3.4）。
        // 注意不能用 microLessonLevel(5)：级 5 是"直接给答案"，按规格该题不计正确，
        // 会造成"答对也判错"。
        hintLevel: config.hintInitialLevel,
      ),
    ));
  }
  return result;
}

/// 05 §10 coreItems(stage)。阶段4/5 的"最近 20 条 PHRASE"窗口由调用方保证，
/// 本函数按传入列表过滤（与 scheduler.isCoreItem 同口径）。
List<Item> coreItemsOf(int stage, List<Item> items, Set<int> activeAnchors) =>
    items.where((it) => isCoreItem(it, stage, activeAnchors)).toList();

/// 05 §10 推进比例：阶段0 用自动化比例（automated/核心数），其余用 stable 比例。
/// 裁决：核心集合为空 → 比例 0（不可推进）；缺失掌握度按不稳定计。
double advanceRatio(int stage, List<Item> items, Map<int, Mastery> masteries,
    Set<int> activeAnchors, Config config) {
  final core = coreItemsOf(stage, items, activeAnchors);
  if (core.isEmpty) return 0;
  final ok = core.where((it) {
    final m = masteries[it.id];
    if (m == null) return false;
    return stage == 0 ? m.state == ItemState.automated : stable(m, config);
  }).length;
  return ok / core.length;
}

/// 05 §10：比例 >= config.stageAdvanceRatio 且未到顶（阶段5 无下一阶段）。
bool canAdvance(int stage, List<Item> items, Map<int, Mastery> masteries,
        Set<int> activeAnchors, Config config) =>
    stage < 5 &&
    advanceRatio(stage, items, masteries, activeAnchors, config) >=
        config.stageAdvanceRatio;

/// 阶段推进判定结果。[microLessonNextSession]：推进时下次会话头部插入微课
/// （05 §10 / 02 §7.1，由会话引擎消费 buildQueue 的 stageAdvanced/microLessonItems）。
class AdvanceDecision {
  final int currentStage;
  final double ratio;
  final bool canAdvance;
  final int nextStage;
  final bool microLessonNextSession;

  const AdvanceDecision({
    required this.currentStage,
    required this.ratio,
    required this.canAdvance,
    required this.nextStage,
    required this.microLessonNextSession,
  });
}

/// 综合判定：可推进则 nextStage=+1 并打微课标记；否则维持当前阶段。
AdvanceDecision evaluateAdvance({
  required int stage,
  required List<Item> items,
  required Map<int, Mastery> masteries,
  required Set<int> activeAnchors,
  required Config config,
}) {
  final ratio = advanceRatio(stage, items, masteries, activeAnchors, config);
  final ok = stage < 5 && ratio >= config.stageAdvanceRatio;
  return AdvanceDecision(
    currentStage: stage,
    ratio: ratio,
    canAdvance: ok,
    nextStage: ok ? advanceStage(stage) : stage,
    microLessonNextSession: ok,
  );
}

/// 推进 +1，上限 5（02 §3.1）。
int advanceStage(int currentStage) =>
    currentStage < 5 ? currentStage + 1 : 5;

/// 手动回退 -1，下限 0（02 §3.1）。
int retreatStage(int currentStage) =>
    currentStage > 0 ? currentStage - 1 : 0;

/// 不可跳级（02 §3.1 / 05 §10）：|to-from|<=1 且两端均在 [0,5]。
bool validateStageTransition(int from, int to) =>
    from >= 0 && from <= 5 && to >= 0 && to <= 5 && (to - from).abs() <= 1;