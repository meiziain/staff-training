// 规格: 08 §2 P2 —— 队列生成性质测试（05 §3），固定种子 1000 次模拟会话。
// C1/C2 口径裁决：C1 在最终序列上对非复现条目检查（C3 复现是 C1 的显式特例，
// 05 §3 要求同音位 2–4 题后复现）；C2 在基础队列上检查（复现插入为反应式例外）。
import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';

const cfg = Config.defaults;
const day = 86400000;

Item mkItem(int id, ItemType type, ItemPayload p) =>
    Item(id: id, type: type, payload: p, createdAt: 0);

RelationPayload mkRelation(Rng r) {
  final anchor = r.pick([0, 4, -4, 7, -7, 2, 5]);
  var dir = r.chance(0.5) ? 1 : -1;
  final steps = r.pick([2, 3]);
  if (!inPool(anchor + dir * (steps - 1))) dir = -dir;
  return RelationPayload.single(
      anchorIndex: anchor, direction: dir, steps: steps);
}

PhrasePayload mkPhrase(Rng r, int stage) {
  final len = stage == 4 ? 3 : r.randInt(4, 5);
  var cur = r.randInt(poolMin, poolMax);
  final notes = <int>[cur];
  for (var i = 1; i < len; i++) {
    var step = (r.chance(0.6) ? 1 : 2) * (r.chance(0.5) ? 1 : -1);
    if (!inPool(cur + step)) step = -step;
    cur += step;
    notes.add(cur);
  }
  return PhrasePayload(
    noteSequence: notes,
    clefSequence: notes.map((n) => r.pick(NotePosition.of(n).clefs)).toList(),
  );
}

void main() {
  test('P2 队列性质 ×1000（固定种子）', () {
    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    const activeAnchors = {0, 4, -4, 7};

    for (var it = 0; it < 1000; it++) {
      final r = rng(20260101 + it);
      final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
      final stage = 1 + it % 5;
      final reason = 'iter=$it stage=$stage';

      // ---- 候选构造（足量覆盖各类型）。
      final warmup = <Candidate>[
        for (final (k, idx) in [0, 4, -4, 7].indexed)
          (
            mkItem(1 + k, ItemType.anchor, AnchorPayload(diatonicIndex: idx)),
            Mastery(
                itemId: 1 + k,
                state: ItemState.automated,
                intervalDays: 30,
                dueAt: now + 5 * day)
          ),
        for (final (k, idx) in [2, 5, -2, 9, 1, 6, -3, 8].indexed)
          (
            mkItem(100 + k, ItemType.direct, DirectPayload(diatonicIndex: idx)),
            Mastery(
                itemId: 100 + k,
                state: ItemState.automated,
                intervalDays: 30,
                dueAt: now + 5 * day)
          ),
        for (final (k, idx) in [-7, 14].indexed)
          (
            mkItem(200 + k, ItemType.anchor, AnchorPayload(diatonicIndex: idx)),
            Mastery(itemId: 200 + k, state: ItemState.learning)
          ),
      ];

      final due = <Candidate>[
        for (var k = 0; k < 30; k++)
          (
            mkItem(1000 + k, ItemType.relation, mkRelation(r)),
            Mastery(
              itemId: 1000 + k,
              state: ItemState.reviewing,
              intervalDays: r.pick([1, 3, 7, 14, 30]).toDouble(),
              dueAt: now - r.nextInt(10) * day - r.nextInt(day),
            )
          ),
      ];
      final newItems = <Candidate>[
        for (var k = 0; k < 15; k++)
          (
            mkItem(2000 + k, ItemType.relation, mkRelation(r)),
            Mastery(itemId: 2000 + k, state: ItemState.learning)
          ),
      ];
      final directItems = <Candidate>[
        for (final (k, idx)
            in [3, 10, 11, 12, 13, -1, -5, -6, 2, 5, 9, 6].indexed)
          (
            mkItem(3000 + k, ItemType.direct, DirectPayload(diatonicIndex: idx)),
            Mastery(itemId: 3000 + k, state: ItemState.learning, dueAt: now)
          ),
      ];
      final phraseItems = <Candidate>[
        for (var k = 0; k < 12; k++)
          (
            mkItem(4000 + k, ItemType.phrase, mkPhrase(r, stage)),
            Mastery(itemId: 4000 + k, state: ItemState.learning)
          ),
      ];
      final microItems = <Candidate>[
        for (var k = 0; k < 4; k++)
          (
            mkItem(
                5000 + k,
                ItemType.relation,
                RelationPayload.single(
                    anchorIndex: 8 + k, direction: 1, steps: 3)),
            Mastery(itemId: 5000 + k, state: ItemState.learning)
          ),
      ];
      final carryover = {for (var k = 0; k < 5; k++) 1000 + r.nextInt(30)};
      final stageAdvanced = it % 4 == 0;

      final plan = buildQueue(
        stage: stage,
        dueItems: due,
        newItems: newItems,
        directItems: directItems,
        phraseItems: phraseItems,
        warmupPool: warmup,
        microLessonItems: microItems,
        activeAnchors: activeAnchors,
        carryoverIds: carryover,
        stageAdvanced: stageAdvanced,
        config: cfg,
        clock: clock,
        rng: r,
      );

      // ---- 结构：热身 8 题；微课时 2–4 题；总长 40。
      final warmupN =
          plan.entries.where((e) => e.segment == QueueSegment.warmup).length;
      final microN =
          plan.entries.where((e) => e.segment == QueueSegment.microLesson).length;
      expect(warmupN, 8, reason: reason);
      if (stageAdvanced) {
        expect(microN, inInclusiveRange(2, 4), reason: reason);
        expect(
            plan.entries
                .where((e) => e.segment == QueueSegment.microLesson)
                .every((e) => e.microLesson),
            isTrue,
            reason: reason);
      } else {
        expect(microN, 0, reason: reason);
      }
      expect(plan.entries.length, cfg.dailyCount, reason: reason);
      expect(plan.c2Relaxed, isFalse, reason: reason);

      // ---- C2：基础队列同类连续 <= 2。
      var run = 1;
      for (var i = 1; i < plan.entries.length; i++) {
        run = plan.entries[i].item.type == plan.entries[i - 1].item.type
            ? run + 1
            : 1;
        expect(run, lessThanOrEqualTo(cfg.maxSameTypeRun), reason: reason);
      }

      // ---- 份额偏差 <= ±0.10（阶段<4 按重分配口径 0.5/0.2/0.3/0）。
      final restSegs = [
        QueueSegment.review,
        QueueSegment.newLearn,
        QueueSegment.direct,
        QueueSegment.phrase,
      ];
      final restEntries =
          plan.entries.where((e) => restSegs.contains(e.segment)).toList();
      expect(restEntries.length, cfg.dailyCount - warmupN - microN,
          reason: reason);
      final shares = stage >= 4
          ? [cfg.mixReview, cfg.mixNew, cfg.mixDirect, cfg.mixPhrase]
          : [
              cfg.mixReview + cfg.mixPhrase / 2,
              cfg.mixNew,
              cfg.mixDirect + cfg.mixPhrase / 2,
              0.0
            ];
      for (var i = 0; i < restSegs.length; i++) {
        final cnt =
            restEntries.where((e) => e.segment == restSegs[i]).length;
        final ratio = cnt / restEntries.length;
        expect((ratio - shares[i]).abs(), lessThanOrEqualTo(0.10 + 1e-9),
            reason: '$reason seg=${restSegs[i]} ratio=$ratio');
      }

      // ---- C4：阶段>=4 必含短句；有到期必含复习。
      if (stage >= 4) {
        expect(
            plan.entries.any((e) => e.item.type == ItemType.phrase), isTrue,
            reason: reason);
      }
      expect(
          plan.entries.any((e) => e.segment == QueueSegment.review), isTrue,
          reason: reason);
      expect(plan.noDueReview, isFalse, reason: reason);

      // ---- 模拟会话：作答 + 错误复现插入。
      final live = [...plan.entries];
      final rex = ReexposureScheduler(config: cfg, rng: r);
      var pos = 0;
      while (pos < live.length) {
        final ins = rex.takeAt(pos);
        if (ins.isNotEmpty) {
          live.insertAll(pos, ins);
          continue;
        }
        final e = live[pos];
        if (!r.chance(0.8)) {
          final trial = Trial(
            sessionId: 1,
            itemId: e.item.id,
            presentedAt: 0,
            rtMs: 2000,
            correct: false,
            inputSource: InputSource.nameButton,
            contextSnapshot: e.context,
          );
          double? rate;
          if (e.item.type == ItemType.phrase) {
            rate = r.chance(0.3) ? 0.6 : 0.2;
          }
          final ne = rex.onWrong(
            item: e.item,
            mastery: e.mastery,
            trial: trial,
            currentIndex: pos,
            sessionLength: live.length,
            phraseWrongRate: rate,
          );
          if (rate != null && rate > cfg.wrongPhraseThreshold) {
            // 整句错误率超阈值：不復现原句（变体由 phrase_generator 负责）。
            expect(ne, isNull, reason: reason);
          }
        }
        pos++;
      }

      // ---- C1：最终序列上非复现条目同音位间隔 >= 4 题。
      final lastSeen = <int, int>{};
      final rexCount = <int, int>{};
      for (var p = 0; p < live.length; p++) {
        final e = live[p];
        if (e.reexposure) {
          // C3：复现落在 2–4 题后，且上下文至少一维不同。
          final gap = p - e.sourcePosition!;
          expect(gap, inInclusiveRange(cfg.lapseReexposeMin, cfg.lapseReexposeMax),
              reason: reason);
          expect(e.context.differsFrom(e.sourceContext!), isTrue,
              reason: reason);
          rexCount[e.item.id] = (rexCount[e.item.id] ?? 0) + 1;
          expect(rexCount[e.item.id]!, lessThanOrEqualTo(3), reason: reason);
          continue;
        }
        for (final idx in e.item.targetIndices) {
          final prev = lastSeen[idx];
          if (prev != null) {
            expect(p - prev, greaterThanOrEqualTo(cfg.dedupGap),
                reason: '$reason idx=$idx pos=$p prev=$prev');
          }
        }
        for (final idx in e.item.targetIndices) {
          lastSeen[idx] = p;
        }
      }
    }
  });

  test('C4 豁免：无到期条目 → noDueReview 提示标记', () {
    final r = rng(7);
    final clock = FakeClock(utcMs: 0, localDate: DateTime(2026, 1, 10));
    final plan = buildQueue(
      stage: 1,
      dueItems: const [],
      newItems: [
        for (var k = 0; k < 20; k++)
          (
            mkItem(1 + k, ItemType.relation, mkRelation(r)),
            Mastery(itemId: 1 + k, state: ItemState.learning)
          ),
      ],
      directItems: [
        for (final (k, idx) in [1, 2, 3, 5, 6, 8, 9, 10, -1, -2, -3, -5].indexed)
          (
            mkItem(100 + k, ItemType.direct, DirectPayload(diatonicIndex: idx)),
            Mastery(itemId: 100 + k, state: ItemState.learning)
          ),
      ],
      phraseItems: const [],
      warmupPool: const [],
      config: cfg,
      clock: clock,
      rng: r,
    );
    expect(plan.noDueReview, isTrue);
    expect(plan.entries.any((e) => e.segment == QueueSegment.review), isFalse);
  });

  test('review 截断：carryover +1000 优先，被截断者输出标记', () {
    final r = rng(9);
    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
    // 8 个到期条目：id=1 逾期 0 天但 carryover；其余逾期 1..7 天。
    final due = <Candidate>[
      for (var k = 0; k < 8; k++)
        (
          mkItem(
              1 + k,
              ItemType.relation,
              RelationPayload.single(
                  anchorIndex: 0, direction: 1, steps: 2)),
          Mastery(
            itemId: 1 + k,
            state: ItemState.reviewing,
            intervalDays: 1,
            dueAt: now - k * day,
          )
        ),
    ];
    final plan = buildQueue(
      stage: 1,
      dueItems: due,
      newItems: const [],
      directItems: const [],
      phraseItems: const [],
      warmupPool: const [],
      carryoverIds: const {1},
      config: cfg,
      clock: clock,
      rng: r,
      count: 12, // rest=12 → review 份额 0.5×12=6，截断 2 个。
    );
    final reviewIds = plan.entries
        .where((e) => e.segment == QueueSegment.review)
        .map((e) => e.item.id)
        .toSet();
    expect(reviewIds.contains(1), isTrue); // carryover 逾期 0 天仍最优先。
    expect(plan.carryoverIds.length, 2);
    expect(plan.carryoverIds.contains(1), isFalse);
    // 被截断者应是分数最低的两个（逾期 1 天、2 天，即 id=2、3）。
    expect(plan.carryoverIds, {2, 3});
  });

  test('02 §7.1 短句流集中后段：阶段5 首条短句不早于 60% 位置', () {    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    for (var it = 0; it < 20; it++) {
      final r = rng(9000 + it);
      final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
      final warmup = <Candidate>[
        for (var k = 0; k < 4; k++)
          (
            mkItem(k + 1, ItemType.anchor,
                AnchorPayload(diatonicIndex: const [0, 4, -4, 7][k])),
            Mastery(itemId: k + 1, state: ItemState.automated),
          ),
      ];
      final poolList = pool.toList();
      // 到期（RELATION）/direct 各覆盖全音位，减少 C1（同音位间隔 4）与
      // C2（同类连续 ≤2，全用 DIRECT 会互相锁死）造成的假性候选枯竭。
      final due = <Candidate>[
        for (var k = 0; k < poolList.length; k++)
          (
            mkItem(100 + k, ItemType.relation, () {
              final target = poolList[k];
              final anchor = target > poolMin ? target - 1 : target + 1;
              return RelationPayload.single(
                anchorIndex: anchor,
                direction: target > anchor ? 1 : -1,
                steps: 2,
              );
            }()),
            Mastery(
                itemId: 100 + k,
                state: ItemState.reviewing,
                dueAt: now - day),
          ),
      ];
      final direct = <Candidate>[
        for (var k = 0; k < poolList.length; k++)
          (
            mkItem(200 + k, ItemType.direct,
                DirectPayload(diatonicIndex: poolList[k])),
            Mastery(itemId: 200 + k, state: ItemState.learning),
          ),
      ];
      final phrases = <Candidate>[
        for (var k = 0; k < 10; k++)
          (
            mkItem(300 + k, ItemType.phrase, mkPhrase(r, 5)),
            Mastery(itemId: 300 + k, state: ItemState.learning),
          ),
      ];
      final plan = buildQueue(
        stage: 5,
        dueItems: due,
        newItems: const [],
        directItems: direct,
        phraseItems: phrases,
        warmupPool: warmup,
        activeAnchors: const {0, 4, -4, 7},
        config: cfg,
        clock: clock,
        rng: r,
      );
      final idx = [
        for (var i = 0; i < plan.entries.length; i++)
          if (plan.entries[i].segment == QueueSegment.phrase) i,
      ];
      expect(idx, isNotEmpty, reason: 'iter=$it');
      expect(idx.first, greaterThanOrEqualTo((cfg.dailyCount * 0.6).floor()),
          reason: 'iter=$it firstPhrase=${idx.first}');
    }
  });

  test('候选只有 2 个锚点（阶段0）时兜底填满题量，且不与上一题同音位', () {
    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
    final anchors = <Candidate>[
      (
        mkItem(1, ItemType.anchor, const AnchorPayload(diatonicIndex: 0)),
        const Mastery(itemId: 1, state: ItemState.learning),
      ),
      (
        mkItem(2, ItemType.anchor, const AnchorPayload(diatonicIndex: 4)),
        const Mastery(itemId: 2, state: ItemState.learning),
      ),
    ];
    final plan = buildQueue(
      stage: 0,
      dueItems: const [],
      newItems: const [],
      directItems: const [],
      phraseItems: const [],
      warmupPool: anchors,
      activeAnchors: const {0, 4},
      config: cfg,
      clock: clock,
      rng: rng(11),
    );
    expect(plan.entries.length, cfg.dailyCount, reason: '兜底应填满题量');
    for (var i = 1; i < plan.entries.length; i++) {
      final prev = plan.entries[i - 1].item.targetIndices;
      expect(plan.entries[i].item.targetIndices.any(prev.contains), isFalse,
          reason: '第 $i 题不应与上一题同音位');
    }
  });

  test('小候选池（阶段1）：答案顺序随机化，不再是跨种子固定循环', () {
    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
    Item mk(int id, ItemType t, ItemPayload p) =>
        Item(id: id, type: t, payload: p, createdAt: 0);
    // 锚点 C4/G4 已自动化；4 个二度关系到期；DIRECT C4/G4 学习中。
    final warmup = <Candidate>[
      (
        mk(1, ItemType.anchor, const AnchorPayload(diatonicIndex: 0)),
        Mastery(
            itemId: 1,
            state: ItemState.automated,
            intervalDays: 7,
            dueAt: now + day)
      ),
      (
        mk(2, ItemType.anchor, const AnchorPayload(diatonicIndex: 4)),
        Mastery(
            itemId: 2,
            state: ItemState.automated,
            intervalDays: 7,
            dueAt: now + day)
      ),
    ];
    final due = <Candidate>[
      for (final (k, t) in [1, -1, 5, 3].indexed)
        (
          mk(10 + k, ItemType.relation,
              RelationPayload.single(anchorIndex: t - 1, direction: 1, steps: 2)),
          Mastery(
              itemId: 10 + k,
              state: ItemState.reviewing,
              intervalDays: 1,
              dueAt: now - (k + 1) * day,
              reps: 3)
        ),
    ];
    final direct = <Candidate>[
      (
        mk(20, ItemType.direct, const DirectPayload(diatonicIndex: 0)),
        Mastery(itemId: 20, state: ItemState.learning, dueAt: now)
      ),
      (
        mk(21, ItemType.direct, const DirectPayload(diatonicIndex: 4)),
        Mastery(itemId: 21, state: ItemState.learning, dueAt: now)
      ),
    ];
    final sequences = <String>{};
    for (var seed = 1; seed <= 8; seed++) {
      final plan = buildQueue(
        stage: 1,
        dueItems: [...due],
        newItems: const [],
        directItems: [...direct],
        phraseItems: const [],
        warmupPool: [...warmup],
        activeAnchors: const {0, 4},
        config: cfg,
        clock: clock,
        rng: rng(seed),
      );
      expect(plan.entries.length, cfg.dailyCount, reason: 'seed=$seed');
      // C1/C2 约束不因随机化而破坏。
      final lastSeen = <int, int>{};
      var run = 1;
      for (var p = 0; p < plan.entries.length; p++) {
        final e = plan.entries[p];
        if (p > 0) {
          run = e.item.type == plan.entries[p - 1].item.type ? run + 1 : 1;
          expect(run, lessThanOrEqualTo(cfg.maxSameTypeRun),
              reason: 'seed=$seed pos=$p');
        }
        for (final idx in e.item.targetIndices) {
          final prev = lastSeen[idx];
          if (prev != null) {
            expect(p - prev, greaterThanOrEqualTo(cfg.dedupGap),
                reason: 'seed=$seed idx=$idx pos=$p');
          }
          lastSeen[idx] = p;
        }
      }
      sequences.add(plan.entries
          .map((e) => NotePosition.of(e.item.targetIndices.last).displayName)
          .join(' '));
    }
    // 修复前：所有种子输出同一固定循环。修复后：顺序应随种子变化。
    expect(sequences.length, greaterThan(1),
        reason: '不同种子应产生不同答案顺序');
  });

  test('阶段0：锚点进入 reviewing（当天未到期）时仍作为热身补位出题', () {
    final now = DateTime.utc(2026, 1, 10).millisecondsSinceEpoch;
    final clock = FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10));
    final anchors = <Candidate>[
      (
        mkItem(1, ItemType.anchor, const AnchorPayload(diatonicIndex: 0)),
        Mastery(
            itemId: 1,
            state: ItemState.reviewing,
            intervalDays: 0.784,
            dueAt: now + day),
      ),
      (
        mkItem(2, ItemType.anchor, const AnchorPayload(diatonicIndex: 4)),
        Mastery(
            itemId: 2,
            state: ItemState.reviewing,
            intervalDays: 0.784,
            dueAt: now + day),
      ),
    ];
    final plan = buildQueue(
      stage: 0,
      dueItems: const [], // 都未到期
      newItems: const [],
      directItems: const [],
      phraseItems: const [],
      warmupPool: anchors,
      activeAnchors: const {0, 4},
      config: cfg,
      clock: clock,
      rng: rng(3),
      count: 20,
    );
    expect(plan.entries, isNotEmpty, reason: '未到期也要能练（F1 锚点训练）');
    expect(plan.entries.length, 20, reason: '兜底填满当日题量');
  });
}