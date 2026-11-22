// 阶段进度卡统计（02 §2.2 三条件 / 05 §4 §10）：口径须与 checkAutomation /
// advanceRatio 一致。固定试次历史，无时钟/随机依赖。
import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/course.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/stage_progress.dart';

const config = Config.defaults;
const nowMs = 1700000000000;

TrialResult r({bool correct = true, int rtMs = 1000, int hintLevel = 0}) =>
    TrialResult(correct: correct, rtMs: rtMs, hintLevel: hintLevel, ts: nowMs);

AnchorAutomationProgress progressOf(List<TrialResult> history,
        {ItemState state = ItemState.learning}) =>
    AnchorAutomationProgress.of(
      diatonicIndex: 0,
      mastery: Mastery(itemId: 1, state: state),
      history: history,
      config: config,
    );

void main() {
  group('AnchorAutomationProgress（02 §2.2 三条件）', () {
    test('空历史：窗口 0、正确率/RT 为 null、三条件均不满足', () {
      final p = progressOf(const []);
      expect(p.windowCount, 0);
      expect(p.window, config.anchorAutoWindow);
      expect(p.accuracy, isNull);
      expect(p.rtMedianMs, isNull);
      expect(p.hintCount, 0);
      expect(p.accOk, isFalse);
      expect(p.rtOk, isFalse);
      expect(p.hintOk, isFalse);
      expect(p.automated, isFalse);
    });

    test('窗口未满：统计正确但三条件不判满足（与 checkAutomation 一致）', () {
      final p = progressOf([for (var k = 0; k < 10; k++) r()]);
      expect(p.windowCount, 10);
      expect(p.accuracy, 1.0);
      expect(p.rtMedianMs, 1000);
      expect(p.windowFull, isFalse);
      expect(p.accOk, isFalse);
      expect(p.rtOk, isFalse);
      expect(p.hintOk, isFalse);
    });

    test('满窗全对够快零提示：三条件全满足', () {
      final p = progressOf(
          [for (var k = 0; k < config.anchorAutoWindow; k++) r()]);
      expect(p.windowFull, isTrue);
      expect(p.accOk, isTrue);
      expect(p.rtOk, isTrue);
      expect(p.hintOk, isTrue);
    });

    test('只取最近 window 条：早期错误不拖累当前窗口', () {
      final p = progressOf([
        for (var k = 0; k < 10; k++) r(correct: false, rtMs: 5000),
        for (var k = 0; k < config.anchorAutoWindow; k++) r(),
      ]);
      expect(p.windowCount, config.anchorAutoWindow);
      expect(p.accuracy, 1.0);
      expect(p.accOk, isTrue);
    });

    test('正确率不足：19/20=95% 达标，18/20=90% 不达标', () {
      final ok = progressOf([
        r(correct: false),
        for (var k = 0; k < config.anchorAutoWindow - 1; k++) r(),
      ]);
      expect(ok.accOk, isTrue);
      final bad = progressOf([
        r(correct: false),
        r(correct: false),
        for (var k = 0; k < config.anchorAutoWindow - 2; k++) r(),
      ]);
      expect(bad.accOk, isFalse);
    });

    test('RT 超限不满足；提示题不计入 RT 中位数但 hintOk 失败', () {
      final slow = progressOf([
        for (var k = 0; k < config.anchorAutoWindow; k++) r(rtMs: 1500),
      ]);
      expect(slow.rtOk, isFalse);
      expect(slow.accOk, isTrue);

      final hinted = progressOf([
        r(hintLevel: 3, rtMs: 5000),
        for (var k = 0; k < config.anchorAutoWindow - 1; k++) r(),
      ]);
      expect(hinted.hintCount, 1);
      expect(hinted.hintOk, isFalse);
      expect(hinted.rtMedianMs, 1000); // 提示题被排除
      expect(hinted.rtOk, isTrue);
    });

    test('automated 状态直接透出', () {
      final p = progressOf(const [], state: ItemState.automated);
      expect(p.automated, isTrue);
    });
  });

  group('StageCoreProgress（05 §10 口径同 advanceRatio）', () {
    Item anchorItem(int id, int index) => Item(
        id: id,
        type: ItemType.anchor,
        payload: AnchorPayload(diatonicIndex: index),
        createdAt: nowMs);

    test('阶段0：automated 计数，与 advanceRatio 一致', () {
      final items = [anchorItem(1, 0), anchorItem(2, 4)];
      final masteries = {
        1: Mastery(itemId: 1, state: ItemState.automated),
        2: Mastery(itemId: 2, state: ItemState.learning),
      };
      final p = StageCoreProgress.of(
        stage: 0,
        items: items,
        masteries: masteries,
        activeAnchors: const {0, 4},
        config: config,
      );
      expect(p.okCount, 1);
      expect(p.coreCount, 2);
      expect(p.ratio, 0.5);
      expect(p.met, isFalse);
      expect(
          p.ratio,
          advanceRatio(0, items, masteries, const {0, 4}, config));
    });

    test('阶段1：stable 计数；全稳定则 met', () {
      final rel = RelationPayload.single(anchorIndex: 0, direction: 1, steps: 2);
      final items = [
        Item(id: 1, type: ItemType.relation, payload: rel, createdAt: nowMs),
      ];
      final stableM = Mastery(
        itemId: 1,
        state: ItemState.reviewing,
        intervalDays: 7,
        hintDependency: 0,
        lastResults: [
          for (var k = 0; k < 5; k++) r(),
        ],
      );
      final p = StageCoreProgress.of(
        stage: 1,
        items: items,
        masteries: {1: stableM},
        activeAnchors: const {0},
        config: config,
      );
      expect(p.okCount, 1);
      expect(p.coreCount, 1);
      expect(p.met, isTrue);
    });

    test('核心集合为空：ratio=0、不 met', () {
      final p = StageCoreProgress.of(
        stage: 1,
        items: const [],
        masteries: const {},
        activeAnchors: const {0},
        config: config,
      );
      expect(p.ratio, 0);
      expect(p.met, isFalse);
    });
  });

  group('CoreItemStableProgress（逐条目稳定四条件，口径同 scheduler.stable）', () {
    final rel = RelationPayload.single(anchorIndex: 0, direction: 1, steps: 2);
    final item =
        Item(id: 1, type: ItemType.relation, payload: rel, createdAt: nowMs);

    CoreItemStableProgress of(Mastery m) =>
        CoreItemStableProgress.of(item: item, mastery: m, config: config);

    test('全满足：stable=true，四条件均 ok', () {
      final p = of(Mastery(
        itemId: 1,
        state: ItemState.reviewing,
        intervalDays: 7,
        hintDependency: 0.2,
        lastResults: [for (var k = 0; k < 5; k++) r()],
      ));
      expect(p.stable, isTrue);
      expect(p.stateOk, isTrue);
      expect(p.intervalOk, isTrue);
      expect(p.hintDepOk, isTrue);
      expect(p.streakOk, isTrue);
      expect(p.streakCorrect, 5);
    });

    test('各条件独立判定：learning / 间隔不足 / 依赖超限 / 连对含错', () {
      final base = Mastery(
        itemId: 1,
        state: ItemState.reviewing,
        intervalDays: 7,
        hintDependency: 0,
        lastResults: [for (var k = 0; k < 5; k++) r()],
      );
      expect(of(base.copyWith(state: ItemState.learning)).stateOk, isFalse);
      expect(of(base.copyWith(intervalDays: 3)).intervalOk, isFalse);
      expect(of(base.copyWith(hintDependency: 0.31)).hintDepOk, isFalse);
      final wrongLast = of(base.copyWith(lastResults: [
        for (var k = 0; k < 4; k++) r(),
        r(correct: false),
      ]));
      expect(wrongLast.streakOk, isFalse);
      expect(wrongLast.streakCorrect, 4);
      expect(of(base.copyWith(state: ItemState.learning)).stable, isFalse);
    });

    test('窗口不足 5 条：streakOk=false，圆环按已有条数计', () {
      final p = of(Mastery(
        itemId: 1,
        state: ItemState.reviewing,
        intervalDays: 7,
        lastResults: [for (var k = 0; k < 3; k++) r()],
      ));
      expect(p.streakOk, isFalse);
      expect(p.streakCorrect, 3);
      expect(p.resultCount, 3);
      expect(p.stable, isFalse);
    });

    test('只取最近 5 条：早期错误不拖累连对', () {
      final p = of(Mastery(
        itemId: 1,
        state: ItemState.reviewing,
        intervalDays: 7,
        lastResults: [
          for (var k = 0; k < 5; k++) r(correct: false),
          for (var k = 0; k < 5; k++) r(),
        ],
      ));
      expect(p.streakOk, isTrue);
      expect(p.streakCorrect, 5);
    });

    test('标签：单步 C4→D4；链 C4⇢G4 展开为逐步路径；短句为音名序列', () {
      expect(of(Mastery(itemId: 1)).label, 'C4→D4');
      final chain = RelationPayload.chain([
        RelationStep(anchorIndex: 0, direction: 1, steps: 3),
        RelationStep(anchorIndex: 2, direction: 1, steps: 3),
      ]);
      final chainItem = Item(
          id: 2, type: ItemType.relation, payload: chain, createdAt: nowMs);
      final cp = CoreItemStableProgress.of(
          item: chainItem, mastery: Mastery(itemId: 2), config: config);
      expect(cp.label, 'C4⇢G4');
      expect(cp.fullLabel, 'C4→E4→G4');
      final phraseItem = Item(
          id: 3,
          type: ItemType.phrase,
          payload: const PhrasePayload(
              noteSequence: [0, 1, 2], clefSequence: [
            Clef.treble,
            Clef.treble,
            Clef.treble
          ]),
          createdAt: nowMs);
      final pp = CoreItemStableProgress.of(
          item: phraseItem, mastery: Mastery(itemId: 3), config: config);
      expect(pp.label, 'C4 D4 E4');
    });
  });
}