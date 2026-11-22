// 规格: 05 §1 条目生成 / §10 阶段推进；02 §3.1 §3.2 §4.1；04 item.payload。
// 固定假时钟；条目生成为确定性枚举，无随机源。
import 'package:test/test.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/course.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';

const config = Config.defaults;
const nowMs = 1700000000000;

FakeClock clock() => FakeClock(utcMs: nowMs);

Item withId(Item it, int id) => Item(
    id: id, type: it.type, payload: it.payload, createdAt: it.createdAt);

Mastery stableMastery(int itemId) => Mastery(
      itemId: itemId,
      state: ItemState.reviewing,
      intervalDays: 7,
      hintDependency: 0,
      lastResults: [
        for (var k = 0; k < 5; k++)
          TrialResult(correct: true, rtMs: 1000, hintLevel: 0, ts: nowMs - k),
      ],
    );

void main() {
  group('ANCHOR 条目（05 §1）', () {
    test('每个 active_anchors 一个，初始 learning、hintLevel=0、dueAt=now', () {
      final c = clock();
      final created = ensureAnchorItems({0, 4}, const [], c);
      expect(created.length, 2);
      expect(
          created.map((e) => (e.$1.payload as AnchorPayload).diatonicIndex),
          [0, 4]);
      for (final (item, m) in created) {
        expect(item.type, ItemType.anchor);
        expect(item.createdAt, nowMs);
        expect(m.state, ItemState.learning);
        expect(m.hintLevel, 0);
        expect(m.dueAt, nowMs);
      }
    });

    test('已存在不重复', () {
      final c = clock();
      final first = ensureAnchorItems({0, 4}, const [], c);
      final existing = [first[0].$1];
      final second = ensureAnchorItems({0, 4}, existing, c);
      expect(second.length, 1);
      expect((second[0].$1.payload as AnchorPayload).diatonicIndex, 4);
    });
  });

  group('DIRECT 条目（05 §1 / 02 §4.1）', () {
    test('22 个音位各一个；锚点 learning 其余 inactive；hintLevel 恒 0', () {
      final c = clock();
      final created = ensureDirectItems(const [], {0, 4}, c);
      expect(created.length, 22);
      expect(created.map((e) => (e.$1.payload as DirectPayload).diatonicIndex),
          pool.toList());
      for (final (item, m) in created) {
        expect(item.type, ItemType.direct);
        final i = (item.payload as DirectPayload).diatonicIndex;
        expect(m.hintLevel, 0);
        if (i == 0 || i == 4) {
          expect(m.state, ItemState.learning);
          expect(m.dueAt, nowMs);
        } else {
          expect(m.state, ItemState.inactive);
          expect(m.dueAt, isNull);
        }
      }
    });

    test('已存在不重复', () {
      final c = clock();
      final existing = [
        const Item(
            id: 99,
            type: ItemType.direct,
            payload: DirectPayload(diatonicIndex: 0),
            createdAt: 1),
      ];
      final created = ensureDirectItems(existing, {0, 4}, c);
      expect(created.length, 21);
      expect(
          created
              .map((e) => (e.$1.payload as DirectPayload).diatonicIndex)
              .contains(0),
          false);
    });
  });

  group('RELATION 阶段1（05 §1：±二度，目标∈trebleRange）', () {
    test('anchors={C4,G4} → 3 条（C4 下二度越界排除）', () {
      final created = relationItemsForStage(1, {0, 4}, const [], clock());
      expect(created.length, 3);
      final keys = created.map((e) {
        final p = e.$1.payload as RelationPayload;
        expect(p.isChain, false);
        expect(p.first.steps, 2);
        expect(p.first.direction.abs(), 1);
        expect(inTrebleRange(p.targetIndex), true);
        return (p.anchorIndex, p.first.direction);
      }).toSet();
      expect(keys, {(0, 1), (4, 1), (4, -1)});
    });

    test('新条目 learning、hintLevel=3、dueAt=now', () {
      final created = relationItemsForStage(1, {0, 4}, const [], clock());
      for (final (item, m) in created) {
        expect(item.type, ItemType.relation);
        expect(item.createdAt, nowMs);
        expect(m.state, ItemState.learning);
        expect(m.hintLevel, config.hintInitialLevel);
        expect(m.dueAt, nowMs);
      }
    });

    test('重复调用不新增（payload 去重）', () {
      final c = clock();
      final first = relationItemsForStage(1, {0, 4}, const [], c);
      final existing = first.map((e) => e.$1).toList();
      expect(relationItemsForStage(1, {0, 4}, existing, c), isEmpty);
    });

    test('单元素链与单步写法视为同一 payload（规范化去重）', () {
      final existing = [
        Item(
            id: 50,
            type: ItemType.relation,
            payload: RelationPayload.chain([
              const RelationStep(anchorIndex: 0, direction: 1, steps: 2)
            ]),
            createdAt: 1),
      ];
      final created = relationItemsForStage(1, {0, 4}, existing, clock());
      expect(created.length, 2);
      expect(
          created
              .map((e) => (e.$1.payload as RelationPayload).anchorIndex)
              .contains(0),
          false);
    });
  });

  group('RELATION 阶段2（05 §1：±三度，目标∈trebleRange）', () {
    test('anchors={C4,G4} → 3 条，steps=3，目标=a±2∈trebleRange', () {
      final created = relationItemsForStage(2, {0, 4}, const [], clock());
      expect(created.length, 3);
      for (final (item, _) in created) {
        final p = item.payload as RelationPayload;
        expect(p.isChain, false);
        expect(p.first.steps, 3);
        expect(p.targetIndex, p.anchorIndex + p.first.direction * 2);
        expect(inTrebleRange(p.targetIndex), true);
      }
    });

    test('重复调用不新增', () {
      final c = clock();
      final first = relationItemsForStage(2, {0, 4}, const [], c);
      expect(
          relationItemsForStage(
              2, {0, 4}, first.map((e) => e.$1).toList(), c),
          isEmpty);
    });
  });

  group('RELATION 阶段3（05 §1：两步链 + 低音锚点单步）', () {
    test('anchors={C4,G4,F3} → 47 条两步链 + 4 条低音单步 = 51', () {
      final created = relationItemsForStage(3, {0, 4, -4}, const [], clock());
      expect(created.length, 51);
      final chains = created
          .map((e) => e.$1.payload as RelationPayload)
          .where((p) => p.isChain)
          .toList();
      final singles = created
          .map((e) => e.$1.payload as RelationPayload)
          .where((p) => !p.isChain)
          .toList();
      expect(chains.length, 47);
      expect(singles.length, 4);
      for (final p in chains) {
        expect(p.chain.length, 2);
        final mid = p.first.targetIndex;
        expect(p.chain[1].anchorIndex, mid);
        expect(inPool(mid), true, reason: '中间音必须在池内');
        expect(inPool(p.targetIndex), true, reason: '终点必须在池内');
        for (final s in p.chain) {
          expect(s.direction.abs(), 1);
          expect(s.steps, anyOf(2, 3));
        }
      }
      for (final p in singles) {
        expect(p.anchorIndex, -4);
        expect(p.first.steps, anyOf(2, 3));
        expect(inPool(p.targetIndex), true);
      }
      expect(
          singles
              .map((p) => (p.first.direction, p.first.steps))
              .toSet(),
          {(1, 2), (-1, 2), (1, 3), (-1, 3)});
    });

    test('仅低音锚点 C3(-7)：越界链与单步被排除', () {
      final created = relationItemsForStage(3, {-7}, const [], clock());
      // 链：mid∈{-6,-5}（-8/-9 越界），终点∈池 → 3+4=7；单步：-6,-5 → 2。
      expect(created.length, 9);
      for (final (item, _) in created) {
        final p = item.payload as RelationPayload;
        expect(inPool(p.targetIndex), true);
        if (p.isChain) expect(inPool(p.first.targetIndex), true);
      }
    });

    test('重复调用不新增', () {
      final c = clock();
      final first = relationItemsForStage(3, {0, 4, -4}, const [], c);
      expect(
          relationItemsForStage(
              3, {0, 4, -4}, first.map((e) => e.$1).toList(), c),
          isEmpty);
    });

    test('新条目 learning、hintLevel=3、dueAt=now', () {
      final created = relationItemsForStage(3, {-4}, const [], clock());
      expect(created, isNotEmpty);
      for (final (_, m) in created) {
        expect(m.state, ItemState.learning);
        expect(m.hintLevel, config.hintInitialLevel);
        expect(m.dueAt, nowMs);
      }
    });
  });

  group('RELATION 阶段生成范围', () {
    test('阶段4/5 返回空（05 §1：短句由 phrase_generator 产出）', () {
      for (final stage in [4, 5]) {
        expect(relationItemsForStage(stage, {0, 4, -4}, const [], clock()),
            isEmpty);
      }
    });

    test('阶段0 生成锚点 ±二度邻近音，初始为微课满提示（02 §2.2 穿插）', () {
      final items = relationItemsForStage(0, {0, 4}, const [], clock(),
          config: Config.defaults);
      expect(items, isNotEmpty);
      final targets = {
        for (final (it, _) in items)
          (it.payload as RelationPayload).targetIndex,
      };
      // C4±2 = D4(1) / B3(-1 出高音谱表范围)；G4±2 = A4(5) / F4(3)。
      expect(targets.contains(5), isTrue);
      expect(targets.contains(3), isTrue);
      for (final (_, m) in items) {
        expect(m.hintLevel, Config.defaults.hintInitialLevel,
            reason: '新条目初始提示级 3（级5 会判"提示完成不计正确"）');
      }
    });
  });

  group('阶段推进（05 §10 / 02 §3.1）', () {
    List<Item> anchorItems(Set<int> anchors) {
      final c = clock();
      return [
        for (final (i, e) in ensureAnchorItems(anchors, const [], c).indexed)
          withId(e.$1, i + 1),
      ];
    }

    test('阶段0：全部锚点自动化 → 比例 1.0 可推进', () {
      final items = anchorItems({0, 4});
      final masteries = {
        for (final it in items)
          it.id: Mastery(itemId: it.id, state: ItemState.automated),
      };
      expect(advanceRatio(0, items, masteries, {0, 4}, config), 1.0);
      expect(canAdvance(0, items, masteries, {0, 4}, config), true);
    });

    test('阶段0：部分自动化 → 0.5 不可推进；stable 非 automated 不计', () {
      final items = anchorItems({0, 4});
      final masteries = {
        1: Mastery(itemId: 1, state: ItemState.automated),
        2: stableMastery(2), // reviewing+stable，但阶段0 只认 automated
      };
      expect(advanceRatio(0, items, masteries, {0, 4}, config), 0.5);
      expect(canAdvance(0, items, masteries, {0, 4}, config), false);
    });

    test('阶段1：stable 比例 0.8 边界（5 条核心，4 stable 可推进）', () {
      final c = clock();
      final created = relationItemsForStage(1, {0, 4, 7}, const [], c);
      expect(created.length, 5);
      final items = [
        for (final (i, e) in created.indexed) withId(e.$1, i + 1),
      ];
      final four = {
        for (final it in items)
          it.id: it.id <= 4
              ? stableMastery(it.id)
              : Mastery(itemId: it.id, state: ItemState.learning),
      };
      expect(advanceRatio(1, items, four, {0, 4, 7}, config),
          closeTo(0.8, 1e-9));
      expect(canAdvance(1, items, four, {0, 4, 7}, config), true);

      final three = Map.of(four)
        ..[4] = Mastery(itemId: 4, state: ItemState.learning);
      expect(advanceRatio(1, items, three, {0, 4, 7}, config),
          closeTo(0.6, 1e-9));
      expect(canAdvance(1, items, three, {0, 4, 7}, config), false);
    });

    test('核心集合为空 → 比例 0 不可推进；缺失掌握度按不稳定计', () {
      expect(advanceRatio(1, const [], const {}, {0, 4}, config), 0);
      expect(canAdvance(1, const [], const {}, {0, 4}, config), false);
      final c = clock();
      final items = [
        withId(relationItemsForStage(1, {0}, const [], c)[0].$1, 1)
      ];
      expect(advanceRatio(1, items, const {}, {0}, config), 0);
    });

    test('evaluateAdvance：推进返回 nextStage+1 与微课标记', () {
      final items = anchorItems({0, 4});
      final masteries = {
        for (final it in items)
          it.id: Mastery(itemId: it.id, state: ItemState.automated),
      };
      final d = evaluateAdvance(
          stage: 0,
          items: items,
          masteries: masteries,
          activeAnchors: {0, 4},
          config: config);
      expect(d.canAdvance, true);
      expect(d.nextStage, 1);
      expect(d.microLessonNextSession, true);

      final hold = evaluateAdvance(
          stage: 0,
          items: items,
          masteries: {1: Mastery(itemId: 1, state: ItemState.learning)},
          activeAnchors: {0, 4},
          config: config);
      expect(hold.canAdvance, false);
      expect(hold.nextStage, 0);
      expect(hold.microLessonNextSession, false);
    });

    test('阶段5 封顶：即使全 stable 也不推进', () {
      final phrases = [
        for (var i = 1; i <= 5; i++)
          Item(
              id: i,
              type: ItemType.phrase,
              payload: PhrasePayload(
                  noteSequence: [0, 1, 2],
                  clefSequence: [Clef.treble, Clef.treble, Clef.treble]),
              createdAt: nowMs),
      ];
      final masteries = {for (final it in phrases) it.id: stableMastery(it.id)};
      expect(advanceRatio(5, phrases, masteries, {0, 4}, config), 1.0);
      expect(canAdvance(5, phrases, masteries, {0, 4}, config), false);
      final d = evaluateAdvance(
          stage: 5,
          items: phrases,
          masteries: masteries,
          activeAnchors: {0, 4},
          config: config);
      expect(d.nextStage, 5);
      expect(d.microLessonNextSession, false);
    });

    test('advanceStage 上限 5；retreatStage 下限 0', () {
      expect(advanceStage(0), 1);
      expect(advanceStage(4), 5);
      expect(advanceStage(5), 5);
      expect(retreatStage(3), 2);
      expect(retreatStage(1), 0);
      expect(retreatStage(0), 0);
    });

    test('不可跳级：0→2 拒绝；相邻与原地合法；越界拒绝', () {
      expect(validateStageTransition(0, 2), false);
      expect(validateStageTransition(2, 0), false);
      expect(validateStageTransition(0, 1), true);
      expect(validateStageTransition(1, 0), true);
      expect(validateStageTransition(2, 2), true);
      expect(validateStageTransition(5, 6), false);
      expect(validateStageTransition(-1, 0), false);
    });

    test('coreItemsOf：阶段3 = 两步链 + 低音锚点单步', () {
      final c = clock();
      final created = relationItemsForStage(3, {0, 4, -4}, const [], c);
      final items = [
        for (final (i, e) in created.indexed) withId(e.$1, i + 1),
      ];
      final core = coreItemsOf(3, items, {0, 4, -4});
      expect(core.length, 51);
      final s1 = relationItemsForStage(1, {0, 4}, const [], c);
      expect(coreItemsOf(3, s1.map((e) => e.$1).toList(), {0, 4}), isEmpty);
    });
  });
}