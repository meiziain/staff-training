// 规格: 02 §4.2 —— 直认题呈现上下文随机（孤立 / 前置锚点闪现 0.5s 后消失），
// 防位置记忆但不提供推导参照；ANCHOR/RELATION/PHRASE 无前置参照。
// 概率裁决见 lib/domain/scheduler.dart 的 `_directPreludeProbability` 注释。
import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/scheduler.dart';

const cfg = Config.defaults;
const day = 86400000;
const now = 1768003200000; // DateTime.utc(2026,1,10).millisecondsSinceEpoch

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

PhrasePayload mkPhrase(Rng r) {
  final len = r.randInt(4, 5);
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

/// 单次会话队列（stage 5：四桶全开，覆盖 ANCHOR/DIRECT/RELATION/PHRASE）。
/// 候选用独立种子生成，队列随机性只来自 [seed]，便于复现性断言。
QueuePlan buildSample(int seed) {
  final pool = rng(seed ^ 0x5f5f);
  final r = rng(seed);
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
        mkItem(1000 + k, ItemType.relation, mkRelation(pool)),
        Mastery(
          itemId: 1000 + k,
          state: ItemState.reviewing,
          intervalDays: pool.pick([1, 3, 7, 14, 30]).toDouble(),
          dueAt: now - pool.nextInt(10) * day,
        )
      ),
  ];
  final newItems = <Candidate>[
    for (var k = 0; k < 15; k++)
      (
        mkItem(2000 + k, ItemType.relation, mkRelation(pool)),
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
        mkItem(4000 + k, ItemType.phrase, mkPhrase(pool)),
        Mastery(itemId: 4000 + k, state: ItemState.learning)
      ),
  ];

  return buildQueue(
    stage: 5,
    dueItems: due,
    newItems: newItems,
    directItems: directItems,
    phraseItems: phraseItems,
    warmupPool: warmup,
    config: cfg,
    clock: FakeClock(utcMs: now, localDate: DateTime(2026, 1, 10)),
    rng: r,
  );
}

void main() {
  test('02 §4.2 DIRECT 随机前置锚点；ANCHOR/RELATION/PHRASE 恒无前置', () {
    var directTrue = 0;
    var directFalse = 0;
    var phraseN = 0;
    var relationN = 0;
    var anchorN = 0;

    // 多队列采样：单队列约 10 个 DIRECT，12 个种子足以覆盖两种取值。
    for (var s = 0; s < 12; s++) {
      final plan = buildSample(20260200 + s);
      for (final e in plan.entries) {
        final isPrelude = e.context.preludeAnchor;
        switch (e.item.type) {
          case ItemType.direct:
            isPrelude ? directTrue++ : directFalse++;
          case ItemType.anchor:
            anchorN++;
            expect(isPrelude, isFalse,
                reason: 'ANCHOR 无前置参照 item=${e.item.id} seed=$s');
          case ItemType.relation:
            relationN++;
            expect(isPrelude, isFalse,
                reason: 'RELATION 无前置参照 item=${e.item.id} seed=$s');
          case ItemType.phrase:
            phraseN++;
            expect(isPrelude, isFalse,
                reason: 'PHRASE 明确无锚点参照 item=${e.item.id} seed=$s');
        }
      }
    }

    expect(directTrue, greaterThan(0), reason: 'DIRECT 应出现前置锚点呈现');
    expect(directFalse, greaterThan(0), reason: 'DIRECT 应出现孤立呈现');
    // 0.5 概率的宽松区间（采样约 120 条，避免固定种子的偶然偏差）。
    final ratio = directTrue / (directTrue + directFalse);
    expect(ratio, inInclusiveRange(0.25, 0.75), reason: 'DIRECT 前置占比=$ratio');
    // 非 DIRECT 类型确实被采样到，上面的 isFalse 断言才有意义。
    expect(anchorN, greaterThan(0));
    expect(relationN, greaterThan(0));
    expect(phraseN, greaterThan(0));
  });

  test('02 §4.2 同一 rng 种子两次 buildQueue 输出一致（可复现）', () {
    List<String> snapshot(QueuePlan plan) => [
          for (final e in plan.entries)
            '${e.item.id}|${e.segment.name}|${e.item.type.name}|'
                '${e.context.clef.wire}|${e.context.jitterSeed}|'
                '${e.context.preludeAnchor}'
        ];

    final a = snapshot(buildSample(777));
    final b = snapshot(buildSample(777));
    expect(a, b);
    expect(a.length, cfg.dailyCount);
  });
}
