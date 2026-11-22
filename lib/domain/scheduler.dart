// 规格: 05 §2 质量分与间隔阶梯 / §3 会话队列与答错复现 / §10 核心条目；02 §6。
// 纯 Dart（03 §2）：时钟注入 Clock、随机注入 Rng，阈值全部来自 Config（03 §6）。
library;

import 'dart:math' as math;

import '../core/clock.dart';
import '../core/config.dart';
import '../core/rng.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/mastery.dart';
import 'models/note_position.dart';
import 'models/trial.dart';

// 共享契约缺口（最终报告列出）：05 §2 规定 RELATION/PHRASE 的 rtTarget=2000ms，
// 但 Config（04 settings 种子）没有对应键。此处以局部常量兜底，待 Config 增补后替换。
const int _relationRtTargetMs = 2000;
const int _phraseRtTargetMs = 2000;

// 02 §4.2 要求直认题呈现上下文随机（孤立 / 前置锚点闪现），但未给概率。
// 裁决：取 0.5；与文件内既有 `_relationRtTargetMs` 局部兜底风格一致，待 Config 增补后替换。
const double _directPreludeProbability = 0.5;

const int _msPerDay = 86400000;

/// 05 §2：各题型的自动化 RT 目标。
int rtTargetOf(ItemType type, Config config) => switch (type) {
      ItemType.anchor => config.anchorAutoRtMs,
      ItemType.direct => config.directAutoRtMs,
      ItemType.relation => _relationRtTargetMs,
      ItemType.phrase => _phraseRtTargetMs,
    };

/// 05 §2 quality(trial)。
/// [phrasePerNoteRt]：PHRASE 传入逐音 RT 列表，用中位数对 2000ms 判定（05 §2 注释）；
/// 不传则退化为 trial.rtMs（最小裁决：调用方未提供逐音数据时按整句 RT）。
int quality(Trial trial, ItemType itemType, Config config,
    {List<int>? phrasePerNoteRt}) {
  if (!trial.correct || trial.timeout) return 1;
  if (trial.hintLevelUsed > 0) return 3;
  final int rt;
  if (itemType == ItemType.phrase && phrasePerNoteRt != null) {
    rt = rtMedianOf(phrasePerNoteRt) ?? trial.rtMs ?? 0;
  } else {
    rt = trial.rtMs ?? 0;
  }
  return rt <= rtTargetOf(itemType, config) ? 5 : 4;
}

/// 05 §2 easeUpdate：标准 SM-2，clamp [easeMin, easeMax]。
double easeUpdate(double ease, int q, Config config) {
  final next = ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02));
  return next.clamp(config.easeMin, config.easeMax);
}

/// 05 §2 currentRung：由 intervalDays 反查最近 ladder 档位。
/// easeFactor = ease / 2.5（2.5 即 SM-2 基准 ease，取 config.easeInit）。
/// 平局取低档（最小裁决：05 §2 未定义平局，T2 rung1 q3→2 天要求 rung 不动）。
int currentRung(Mastery mastery, Config config) {
  final ef = mastery.ease / config.easeInit;
  final ladder = config.intervalLadderDays;
  var best = 0;
  var bestDist = double.infinity;
  for (var r = 0; r < ladder.length; r++) {
    final d = (mastery.intervalDays - ladder[r] * ef).abs();
    if (d < bestDist - 1e-9) {
      bestDist = d;
      best = r;
    }
  }
  return best;
}

/// 05 §2 advance(mastery, q, sessionEndTs)。
/// [sessionEndTs] 为 null 表示会话已结束：q1 的 dueAt 取本地今日 23:59:59.999。
/// 间隔一律用更新前的 ease 计算；reps+1、ease=easeUpdate 在间隔之后。
/// 小数天数的到期日裁决（05 §2 未定义）：intervalDays.round() 天后取本地 00:00。
Mastery advance(
    Mastery mastery, int q, int? sessionEndTs, Clock clock, Config config) {
  final ladder = config.intervalLadderDays;
  final maxRung = ladder.length - 1;
  final ef = mastery.ease / config.easeInit;
  var r = currentRung(mastery, config);
  double intervalDays;
  int dueAt;
  var lapses = mastery.lapses;
  if (q == 1) {
    r = 0;
    lapses += 1;
    intervalDays = 0;
    dueAt = sessionEndTs ?? clock.localEndOfDayUtcMs(clock.localDate());
  } else {
    if (q >= 4) {
      r = math.min(r + 1, maxRung);
      intervalDays = ladder[r] * ef;
    } else {
      // q == 3：半级，当前档与下一档中点向上取整，rung 不动（05 §2 裁决）。
      intervalDays =
          ((ladder[r] + ladder[math.min(r + 1, maxRung)]) / 2).ceil() * ef;
    }
    final today = clock.localDate();
    final dueDate =
        DateTime(today.year, today.month, today.day + intervalDays.round());
    dueAt = clock.localMidnightUtcMs(dueDate);
  }
  return mastery.copyWith(
    state: r == 0 ? ItemState.learning : ItemState.reviewing,
    ease: easeUpdate(mastery.ease, q, config),
    intervalDays: intervalDays,
    dueAt: () => dueAt,
    reps: mastery.reps + 1,
    lapses: lapses,
  );
}

/// 05 §2 稳定判定。
/// 最小裁决：lastResults 不足 stableStreak(5) 条不判稳定（08 T3 口径）。
bool stable(Mastery m, Config config) {
  if (m.state != ItemState.reviewing && m.state != ItemState.automated) {
    return false;
  }
  if (m.intervalDays < config.stableMinIntervalDays) return false;
  if (m.hintDependency > config.hintDepStableMax) return false;
  final n = config.stableStreak;
  if (m.lastResults.length < n) return false;
  return m.lastResults.sublist(m.lastResults.length - n).every((r) => r.correct);
}

/// 05 §10 coreItems(stage)：当前阶段核心条目判定（review 截断加权 ×1.5）。
/// 阶段4/5 的"最近 20 条 PHRASE"窗口由调用方在候选列表中保证（最小裁决）。
/// 阶段3 低音锚点按 anchorIndex < 0 判定（F3=-4、C3=-7；C4=0 属高音区锚点）。
bool isCoreItem(Item item, int stage, Set<int> activeAnchors) {
  final p = item.payload;
  switch (stage) {
    case 0:
      return item.type == ItemType.anchor &&
          p is AnchorPayload &&
          activeAnchors.contains(p.diatonicIndex);
    case 1:
      return p is RelationPayload && !p.isChain && p.first.steps == 2;
    case 2:
      return p is RelationPayload && !p.isChain && p.first.steps == 3;
    case 3:
      return p is RelationPayload && (p.isChain || p.anchorIndex < 0);
    case 4:
    case 5:
      return item.type == ItemType.phrase;
    default:
      return false;
  }
}

/// 队列分段（份额统计与测试用）。
enum QueueSegment { warmup, microLesson, review, newLearn, direct, phrase, reexposure }

/// 队列条目：条目 + 掌握度 + 呈现上下文 + 标记。
class QueueEntry {
  final Item item;
  final Mastery mastery;
  final ContextSnapshot context;
  final QueueSegment segment;
  final bool microLesson;
  final bool reexposure;

  /// 复现题溯源（仅 reexposure=true 时有值）：错误试次所在题序与上下文。
  final int? sourcePosition;
  final ContextSnapshot? sourceContext;

  const QueueEntry({
    required this.item,
    required this.mastery,
    required this.context,
    required this.segment,
    this.microLesson = false,
    this.reexposure = false,
    this.sourcePosition,
    this.sourceContext,
  });
}

/// buildQueue 输出。
/// noDueReview：C4 豁免提示（"今天没有到期复习，学点新的"，02 §6.4）。
/// carryoverIds：本次被容量截断的到期条目，次日排序 +1000 优先（05 §3）。
/// c2Relaxed：回溯超过 50 次后是否放宽了 C2（05 §3）。
class QueuePlan {
  final List<QueueEntry> entries;
  final bool noDueReview;
  final Set<int> carryoverIds;
  final bool c2Relaxed;

  const QueuePlan({
    required this.entries,
    required this.noDueReview,
    required this.carryoverIds,
    required this.c2Relaxed,
  });
}

typedef Candidate = (Item, Mastery);

void _shuffle<T>(List<T> list, Rng rng) {
  for (var i = list.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final t = list[i];
    list[i] = list[j];
    list[j] = t;
  }
}

/// 基线上下文（最小裁决：buildQueue 生成孤立呈现基线，jitterSeed 随机；
/// 会话引擎可在呈现时细化 neighbors/prelude 等维度）。
/// 02 §4.2：仅 DIRECT 随机前置锚点闪现（防位置记忆，不提供推导参照）；
/// ANCHOR / RELATION / PHRASE 恒为孤立呈现。
ContextSnapshot _contextFor(Item item, Rng rng) {
  final clef = item.payload is PhrasePayload
      ? (item.payload as PhrasePayload).clefSequence.first
      : rng.pick(NotePosition.of(item.targetIndices.first).clefs);
  final jitterSeed = rng.nextInt(1 << 30);
  final preludeAnchor =
      item.type == ItemType.direct && rng.chance(_directPreludeProbability);
  return ContextSnapshot(
    clef: clef,
    jitterSeed: jitterSeed,
    preludeAnchor: preludeAnchor,
  );
}

/// 05 §3 buildQueue：热身 → 微课 → 交错混合（贪心 + C1/C2 约束）。
///
/// [warmupPool]：已自动化 ANCHOR/DIRECT + 学习中 ANCHOR（补位），内部按状态分拣。
/// [microLessonItems]：stageAdvanced=true 时新阶段核心条目候选（取 2–4 题）。
/// [count]：队列长度，默认 config.dailyCount。
/// 份额不足裁决（05 §3 未定义候选短缺）：某桶候选耗尽时其剩余份额由其他桶 overflow 补齐。
/// C1 永不放宽；C2 在整轮无可行候选累计 50 次后放宽（回溯计数口径：整轮失败次数）。
QueuePlan buildQueue({
  required int stage,
  required List<Candidate> dueItems,
  required List<Candidate> newItems,
  required List<Candidate> directItems,
  required List<Candidate> phraseItems,
  required List<Candidate> warmupPool,
  List<Candidate> microLessonItems = const [],
  Set<int> activeAnchors = const {0, 4},
  Set<int> carryoverIds = const {},
  bool stageAdvanced = false,
  required Config config,
  required Clock clock,
  required Rng rng,
  int? count,
  bool phrasesOnly = false,
}) {
  final n = count ?? config.dailyCount;
  // 试玩模式（交付报告偏差 #19）：只出短句，跳过热身/微课。
  final warmupLimit = phrasesOnly ? 0 : config.warmupCount;
  final placed = <QueueEntry>[];
  final lastPos = <int, int>{};
  var backtracks = 0;
  var c2Relaxed = false;

  bool okC1(Item item, int pos) => item.targetIndices.every(
      (i) => pos - (lastPos[i] ?? -config.dedupGap) >= config.dedupGap);

  bool okC2(ItemType type) {
    if (c2Relaxed) return true;
    final run = config.maxSameTypeRun;
    if (placed.length < run) return true;
    for (var k = 1; k <= run; k++) {
      if (placed[placed.length - k].item.type != type) return true;
    }
    return false;
  }

  void put(Item item, Mastery m, QueueSegment seg, {bool micro = false}) {
    final pos = placed.length;
    placed.add(QueueEntry(
      item: item,
      mastery: m,
      context: _contextFor(item, rng),
      segment: seg,
      microLesson: micro,
    ));
    for (final i in item.targetIndices) {
      lastPos[i] = pos;
    }
  }

  // ---- 热身：已自动化 ANCHOR + DIRECT 轮流，不足用学习中锚点补（05 §3）。
  final autoA = warmupPool
      .where((c) => c.$1.type == ItemType.anchor && c.$2.state == ItemState.automated)
      .toList();
  final autoD = warmupPool
      .where((c) => c.$1.type == ItemType.direct && c.$2.state == ItemState.automated)
      .toList();
  // 补位池：未自动化的锚点（learning/reviewing 都算——阶段 0 只有锚点条目，
  // 若只收 learning，锚点一旦进入间隔复习，当天就无题可出）。
  final learnA = warmupPool
      .where((c) =>
          c.$1.type == ItemType.anchor && c.$2.state != ItemState.automated)
      .toList();

  Candidate? takeValid(List<Candidate> pool) {
    for (var i = 0; i < pool.length; i++) {
      final c = pool[i];
      if (okC1(c.$1, placed.length) && okC2(c.$1.type)) {
        pool.removeAt(i);
        return c;
      }
    }
    return null;
  }

  for (var k = 0; k < math.min(warmupLimit, n); k++) {
    final first = k.isEven ? autoA : autoD;
    final second = k.isEven ? autoD : autoA;
    final c = takeValid(first) ?? takeValid(second) ?? takeValid(learnA);
    if (c == null) break; // 约束下无法填满则缩短热身（最小裁决）。
    put(c.$1, c.$2, QueueSegment.warmup);
  }

  // ---- 微课：阶段推进时新阶段核心条目 2–4 题（05 §3 / 02 §7.1）。
  if (stageAdvanced && !phrasesOnly) {
    final usedIds = placed.map((e) => e.item.id).toSet();
    final micro = microLessonItems.where((c) => !usedIds.contains(c.$1.id)).toList();
    var microPlaced = 0;
    for (final c in micro) {
      if (microPlaced >= 4 || placed.length >= n) break;
      if (okC1(c.$1, placed.length) && okC2(c.$1.type)) {
        put(c.$1, c.$2, QueueSegment.microLesson, micro: true);
        microPlaced++;
      }
    }
  }

  final usedIds = placed.map((e) => e.item.id).toSet();
  List<Candidate> unused(List<Candidate> src) =>
      src.where((c) => !usedIds.contains(c.$1.id)).toList();

  // ---- 份额（05 §3）：stage<4 时 phrase 份额平分给 review 与 direct。
  final rest = math.max(0, n - placed.length);
  final shares = phrasesOnly
      ? const [0.0, 0.0, 0.0, 1.0]
      : stage >= 4
      ? [config.mixReview, config.mixNew, config.mixDirect, config.mixPhrase]
      : [
          config.mixReview + config.mixPhrase / 2,
          config.mixNew,
          config.mixDirect + config.mixPhrase / 2,
          0.0,
        ];
  const segs = [
    QueueSegment.review,
    QueueSegment.newLearn,
    QueueSegment.direct,
    QueueSegment.phrase,
  ];
  // 最大余数法取整，保证份额总和 == rest（最小裁决：05 §3 未定义取整口径）。
  final quota = <QueueSegment, int>{};
  final fracs = <(double, int)>[];
  var assigned = 0;
  for (var i = 0; i < segs.length; i++) {
    final raw = rest * shares[i];
    quota[segs[i]] = raw.floor();
    assigned += raw.floor();
    fracs.add((raw - raw.floor(), i));
  }
  fracs.sort((a, b) {
    final c = b.$1.compareTo(a.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  for (var k = 0; k < rest - assigned; k++) {
    final i = fracs[k % fracs.length].$2;
    quota[segs[i]] = quota[segs[i]]! + 1;
  }

  // ---- review 候选排序截断：score = 逾期天数 × (核心 1.5 : 1.0)，carryover +1000。
  final now = clock.nowUtcMs();
  final review = unused(dueItems);
  double score(Candidate c) {
    final overdue =
        math.max(0, now - (c.$2.dueAt ?? now)) / _msPerDay;
    final core = isCoreItem(c.$1, stage, activeAnchors) ? 1.5 : 1.0;
    return overdue * core + (carryoverIds.contains(c.$1.id) ? 1000 : 0);
  }

  review.sort((a, b) {
    final c = score(b).compareTo(score(a));
    return c != 0 ? c : a.$1.id.compareTo(b.$1.id);
  });
  final truncated = <int>{};
  if (review.length > quota[QueueSegment.review]!) {
    for (final c in review.sublist(quota[QueueSegment.review]!)) {
      truncated.add(c.$1.id);
    }
    review.removeRange(quota[QueueSegment.review]!, review.length);
  }

  final newB = unused(newItems);
  final directB = unused(directItems);
  final phraseB = unused(phraseItems);
  _shuffle(newB, rng);
  _shuffle(directB, rng);
  _shuffle(phraseB, rng);
  final buckets = <QueueSegment, List<Candidate>>{
    QueueSegment.review: review,
    QueueSegment.newLearn: newB,
    QueueSegment.direct: directB,
    QueueSegment.phrase: phraseB,
  };

  // ---- 贪心放置：优先剩余份额最大的桶；桶内在全部可行候选中随机取一
  // （固定取首个会在小候选池下形成答案固定循环）；整轮失败累计 50 次放宽 C2。
  // 短句流集中后段（02 §7.1 第 4 段）：份额内前 60% 不放短句；
  // 裁决：02 未给分段比例，取后 40% 为短句流段；其它桶耗尽时允许提前（避免卡队列）。
  final phraseStart = (n * 0.6).floor();
  QueueEntry? tryPlace({required bool respectQuota}) {
    final order = [...segs];
    order.sort((a, b) {
      final c = quota[b]!.compareTo(quota[a]!);
      return c != 0 ? c : segs.indexOf(a).compareTo(segs.indexOf(b));
    });
    for (final seg in order) {
      if (respectQuota && quota[seg]! <= 0) continue;
      if (respectQuota &&
          seg == QueueSegment.phrase &&
          placed.length < phraseStart) {
        continue;
      }
      final list = buckets[seg]!;
      final valid = <int>[
        for (var i = 0; i < list.length; i++)
          if (okC1(list[i].$1, placed.length) && okC2(list[i].$1.type)) i,
      ];
      if (valid.isEmpty) continue;
      // carryover（上次被截断）条目保持最优先；其余可行候选中随机取。
      var pickFrom = valid;
      if (seg == QueueSegment.review) {
        final carry = valid
            .where((i) => carryoverIds.contains(list[i].$1.id))
            .toList();
        if (carry.isNotEmpty) pickFrom = carry;
      }
      final c = list.removeAt(pickFrom[rng.nextInt(pickFrom.length)]);
      quota[seg] = quota[seg]! - 1;
      final pos = placed.length;
      final e = QueueEntry(
        item: c.$1,
        mastery: c.$2,
        context: _contextFor(c.$1, rng),
        segment: seg,
      );
      placed.add(e);
      for (final idx in c.$1.targetIndices) {
        lastPos[idx] = pos;
      }
      return e;
    }
    return null;
  }

  while (placed.length < n) {
    var e = tryPlace(respectQuota: true);
    e ??= tryPlace(respectQuota: false); // 份额桶受阻时 overflow 补齐（最小裁决）。
    if (e == null) {
      backtracks++;
      if (backtracks > 50) c2Relaxed = true;
      e = tryPlace(respectQuota: false);
      if (e == null) break; // C1 硬约束永不放宽：无可行候选则提前结束。
    }
  }

  // ---- 兜底轮转：阶段 0/1 库里可能只有 1–2 个锚点条目，候选彻底耗尽后
  // 队列会短到 2 题（用户看到"20 题"却只做 2 题）。此处复用已放置条目填满题量：
  // 优先仍满足 C1 间隔的条目，实在没有才放宽到「不与上一题同音位」
  // （02 §2.2 锚点训练本来就是同一锚点反复闪现，靠呈现位置抖动防记忆，
  // 且每题重新生成 context）。在可行条目中随机取，避免固定答案循环。
  // 常规候选充足时不会走到这里。
  if (placed.length < n && placed.isNotEmpty) {
    final reusable = [...placed];
    var attempts = 0;
    final maxAttempts = n * 4;
    while (placed.length < n && attempts < maxAttempts) {
      attempts++;
      final pos = placed.length;
      final prevTargets = placed.last.item.targetIndices;
      bool clashFree(QueueEntry e) =>
          !e.item.targetIndices.any(prevTargets.contains);
      // 优先仍满足 C1 间隔 + C2 同类连续的条目；候选不足时逐级放宽
      // （只有 1–2 个音位或全同类时退化为「不与上一题同音位」）。
      var options = reusable
          .where((e) =>
              clashFree(e) && okC1(e.item, pos) && okC2(e.item.type))
          .toList();
      if (options.isEmpty) {
        options =
            reusable.where((e) => clashFree(e) && okC2(e.item.type)).toList();
      }
      if (options.isEmpty) options = reusable.where(clashFree).toList();
      if (options.isEmpty) break;
      final src = options[rng.nextInt(options.length)];
      placed.add(QueueEntry(
        item: src.item,
        mastery: src.mastery,
        context: _contextFor(src.item, rng),
        segment: src.segment,
      ));
      for (final idx in src.item.targetIndices) {
        lastPos[idx] = pos;
      }
    }
  }

  return QueuePlan(
    entries: placed,
    noDueReview: dueItems.isEmpty,
    carryoverIds: truncated,
    c2Relaxed: c2Relaxed,
  );
}

/// 05 §3 答错换上下文复现（C3）。
/// 会话内机制：onWrong 预约复现题到绝对题序；引擎在到达该题序时 takeAt 取出插入。
/// 同一会话同一条目最多 3 次复现，之后交给间隔阶梯（advance q1）。
/// PHRASE 整句错误率 > wrongPhraseThreshold：不復现原句，经 [phraseVariantBuilder]
/// 回调向 phrase_generator 索取变体（05 §6，本模块不实现变体生成）；
/// 未提供回调时返回 null（预留接口，调用方负责后续变体流程）。
///
/// 回调必须同时返回变体条目与其掌握度：变体是独立条目（有自己的 item id），
/// 不能沿用原句的 mastery（否则 trial_log 与 mastery 的 item_id 会错配）。
class ReexposureScheduler {
  final Config config;
  final Rng rng;
  final (Item, Mastery)? Function(Item original)? phraseVariantBuilder;

  final Map<int, int> _counts = {};
  final Map<int, List<QueueEntry>> _pending = {};

  ReexposureScheduler({
    required this.config,
    required this.rng,
    this.phraseVariantBuilder,
  });

  /// 已预约未呈现的复现题数。
  int get pendingCount =>
      _pending.values.fold(0, (s, l) => s + l.length);

  /// 错误试次发生后调用。[currentIndex] 为当前题序（含已插入复现题的 live 序号），
  /// [sessionLength] 为当前队列长度；窗口超出队列末尾则放弃复现（交给间隔阶梯，
  /// 最小裁决：05 §3 未定义会话末尾的复现）。
  QueueEntry? onWrong({
    required Item item,
    required Mastery mastery,
    required Trial trial,
    required int currentIndex,
    required int sessionLength,
    double? phraseWrongRate,
  }) {
    var target = item;
    var targetMastery = mastery;
    if (item.type == ItemType.phrase &&
        phraseWrongRate != null &&
        phraseWrongRate > config.wrongPhraseThreshold) {
      final variant = phraseVariantBuilder?.call(item);
      if (variant == null) return null;
      target = variant.$1;
      targetMastery = variant.$2;
    }
    final count = _counts[item.id] ?? 0;
    if (count >= 3) return null; // 同一会话最多 3 次（05 §3）。

    final lo = currentIndex + config.lapseReexposeMin;
    final hi = math.min(currentIndex + config.lapseReexposeMax, sessionLength);
    if (lo > hi) return null;
    var pos = math.min(currentIndex + rng.randInt(config.lapseReexposeMin, config.lapseReexposeMax), hi);
    if (_pending.containsKey(pos)) {
      // 窗口内找空位（保持 2–4 题间隔）；理论上窗口内至多 2 个先前预约，必有空位。
      var found = false;
      for (var p = lo; p <= hi; p++) {
        if (!_pending.containsKey(p)) {
          pos = p;
          found = true;
          break;
        }
      }
      if (!found) return null; // 防御：极端拥挤时交给间隔阶梯。
    }

    final next = _reexposureContext(target, trial.contextSnapshot);
    _counts[item.id] = count + 1;
    final entry = QueueEntry(
      item: target,
      mastery: targetMastery,
      context: next,
      segment: QueueSegment.reexposure,
      reexposure: true,
      sourcePosition: currentIndex,
      sourceContext: trial.contextSnapshot,
    );
    _pending.putIfAbsent(pos, () => []).add(entry);
    return entry;
  }

  /// 到达题序 [position] 时取出预约的复现题（引擎 insertAll 到该位置）。
  List<QueueEntry> takeAt(int position) => _pending.remove(position) ?? const [];

  /// 复现上下文：至少一维不同（05 §3）。
  /// jitterSeed 必换（保证 differsFrom）；clef 在 canClef 允许时随机换；
  /// DIRECT 随机切换前置锚点闪现；RELATION 随机加相邻音。
  ContextSnapshot _reexposureContext(Item item, ContextSnapshot old) {
    final idx = item.targetIndices.first;
    var clef = old.clef;
    final clefs = NotePosition.of(idx).clefs;
    if (clefs.length > 1 && rng.chance(0.5)) {
      clef = clefs.firstWhere((c) => c != old.clef, orElse: () => old.clef);
    }
    var prelude = old.preludeAnchor;
    if (item.type == ItemType.direct && rng.chance(0.5)) prelude = !prelude;
    var neighbors = old.neighbors;
    if (item.type == ItemType.relation && rng.chance(0.5)) {
      neighbors = [
        if (inPool(idx - 1)) idx - 1,
        if (inPool(idx + 1)) idx + 1,
      ];
    }
    return ContextSnapshot(
      clef: clef,
      jitterSeed: old.jitterSeed + 1 + rng.nextInt(1 << 20),
      phraseSlot: old.phraseSlot,
      neighbors: neighbors,
      presentation: old.presentation,
      preludeAnchor: prelude,
    );
  }
}