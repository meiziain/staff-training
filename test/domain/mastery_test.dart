// 规格: 08 T4/T5/T6 / 05 §4 掌握度状态机。固定 Config 默认值（04 settings 种子）。
import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/mastery.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/mastery.dart';

void main() {
  const config = Config.defaults;
  const now = 123456789;

  TrialResult tr({
    bool correct = true,
    int rt = 1000,
    int hint = 0,
    int ts = 0,
  }) =>
      TrialResult(correct: correct, rtMs: rt, hintLevel: hint, ts: ts);

  /// 20 条窗口：前 10 条 rt=lo，后 10 条 rt=hi（中位数=(lo+hi)/2），wrongCount 条错。
  List<TrialResult> window20({
    required int lo,
    required int hi,
    int wrongCount = 1,
    int hintAt = -1,
  }) =>
      List.generate(20, (i) {
        return tr(
          correct: i < 20 - wrongCount,
          rt: i < 10 ? lo : hi,
          hint: i == hintAt ? 1 : 0,
          ts: i,
        );
      });

  group('T4 自动化判定（ANCHOR 窗口20/95%/1200ms）', () {
    final base = const Mastery(itemId: 1, state: ItemState.learning);

    test('20题19对, RT中位1200, 零提示 → automated', () {
      final u = checkAutomation(
          base, window20(lo: 1100, hi: 1300), ItemType.anchor, config);
      expect(u.mastery.state, ItemState.automated);
    });

    test('20题18对 → 非', () {
      final u = checkAutomation(base,
          window20(lo: 1100, hi: 1300, wrongCount: 2), ItemType.anchor, config);
      expect(u.mastery.state, ItemState.learning);
    });

    test('RT中位1201 → 非', () {
      final u = checkAutomation(
          base, window20(lo: 1100, hi: 1302), ItemType.anchor, config);
      expect(u.mastery.state, ItemState.learning);
    });

    test('含1次提示级1 → 非', () {
      final u = checkAutomation(
          base,
          window20(lo: 1100, hi: 1300, wrongCount: 0, hintAt: 5),
          ItemType.anchor,
          config);
      expect(u.mastery.state, ItemState.learning);
    });

    test('仅19题记录 → 不判（窗口不足）', () {
      final u = checkAutomation(
          base,
          window20(lo: 1100, hi: 1300, wrongCount: 0).sublist(0, 19),
          ItemType.anchor,
          config);
      expect(u.mastery.state, ItemState.learning);
    });
  });

  group('T4 自动化判定（DIRECT 同构，阈值1500ms）', () {
    final base = const Mastery(itemId: 2, state: ItemState.learning);

    test('20题19对, RT中位1500, 零提示 → automated', () {
      final u = checkAutomation(
          base, window20(lo: 1400, hi: 1600), ItemType.direct, config);
      expect(u.mastery.state, ItemState.automated);
    });

    test('RT中位1501 → 非', () {
      final u = checkAutomation(
          base, window20(lo: 1400, hi: 1602), ItemType.direct, config);
      expect(u.mastery.state, ItemState.learning);
    });

    test('20题18对 → 非；含提示 → 非；19条 → 不判', () {
      expect(
          checkAutomation(base, window20(lo: 1400, hi: 1600, wrongCount: 2),
                  ItemType.direct, config)
              .mastery
              .state,
          ItemState.learning);
      expect(
          checkAutomation(
                  base,
                  window20(lo: 1400, hi: 1600, wrongCount: 0, hintAt: 0),
                  ItemType.direct,
                  config)
              .mastery
              .state,
          ItemState.learning);
      expect(
          checkAutomation(
                  base,
                  window20(lo: 1400, hi: 1600, wrongCount: 0).sublist(0, 19),
                  ItemType.direct,
                  config)
              .mastery
              .state,
          ItemState.learning);
    });
  });

  group('T5 直认晋升', () {
    final inactive = const Mastery(itemId: 10);
    List<TrialResult> hist(List<int> rts, {int hintAt = -1}) =>
        List.generate(rts.length,
            (i) => tr(rt: rts[i], hint: i == hintAt ? 1 : 0, ts: i));

    test('目标A4 最近5条全对零提示 RT中位2000 → learning', () {
      final u = checkPromotion(
        direct: inactive,
        diatonicIndex: 5,
        relationHistory: hist([1800, 1900, 2000, 2100, 2200]),
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.learning);
      expect(u.mastery.dueAt, now);
      expect(u.mastery.hintLevel, 0);
      expect(u.events.single, isA<PromotionEvent>());
      expect((u.events.single as PromotionEvent).diatonicIndex, 5);
    });

    test('RT中位2001 → 不晋升', () {
      final u = checkPromotion(
        direct: inactive,
        diatonicIndex: 5,
        relationHistory: hist([1800, 1900, 2001, 2100, 2200]),
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.inactive);
      expect(u.events, isEmpty);
    });

    test('目标C6(加线) RT中位2400 → 晋升（<=2500）', () {
      final u = checkPromotion(
        direct: inactive,
        diatonicIndex: 14,
        relationHistory: hist([2200, 2300, 2400, 2500, 2600]),
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.learning);
      expect(u.events.single, isA<PromotionEvent>());
    });

    test('5条中1条用了提示 → 不晋升', () {
      final u = checkPromotion(
        direct: inactive,
        diatonicIndex: 5,
        relationHistory: hist([1800, 1900, 2000, 2100, 2200], hintAt: 2),
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.inactive);
      expect(u.events, isEmpty);
    });

    test('不足5条 → 不晋升；已 learning 不重复晋升', () {
      final u = checkPromotion(
        direct: inactive,
        diatonicIndex: 5,
        relationHistory: hist([1800, 1900, 2000]),
        config: config,
        nowMs: now,
      );
      expect(u.events, isEmpty);
      final learning = const Mastery(itemId: 10, state: ItemState.learning);
      final u2 = checkPromotion(
        direct: learning,
        diatonicIndex: 5,
        relationHistory: hist([1800, 1900, 2000, 2100, 2200]),
        config: config,
        nowMs: now,
      );
      expect(u2.events, isEmpty);
    });
  });

  group('T6 直认回退与再迁移', () {
    test('DIRECT 连续3错 → relapsed + RelapseEvent', () {
      final direct = Mastery(
        itemId: 10,
        state: ItemState.learning,
        lastResults: [
          tr(),
          tr(correct: false),
          tr(correct: false),
          tr(correct: false),
        ],
      );
      final u = checkRelapse(
        direct: direct,
        diatonicIndex: 5,
        relationItemIds: const [101, 102],
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.relapsed);
      final e = u.events.single as RelapseEvent;
      expect(e.relationItemIds, [101, 102]);
      expect(e.resetHintLevel, 3);
      expect(e.dueAt, now);
    });

    test('仅连续2错 → 不回退', () {
      final direct = Mastery(
        itemId: 10,
        state: ItemState.learning,
        lastResults: [tr(correct: false), tr(correct: false)],
      );
      final u = checkRelapse(
        direct: direct,
        diatonicIndex: 5,
        relationItemIds: const [101],
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.learning);
      expect(u.events, isEmpty);
    });

    test('RELATION 重置 hint=3 / due=now / state=learning', () {
      final relation = const Mastery(
          itemId: 101, state: ItemState.reviewing, hintLevel: 0);
      final m = resetRelationForRelapse(relation, nowMs: now, config: config);
      expect(m.state, ItemState.learning);
      expect(m.hintLevel, 3);
      expect(m.dueAt, now);
    });

    test('relapsed 再满足 T5 条件 → 重新 learning', () {
      final relapsed = const Mastery(itemId: 10, state: ItemState.relapsed);
      final u = checkPromotion(
        direct: relapsed,
        diatonicIndex: 5,
        relationHistory: List.generate(
            5, (i) => tr(rt: const [1800, 1900, 2000, 2100, 2200][i], ts: i)),
        config: config,
        nowMs: now,
      );
      expect(u.mastery.state, ItemState.learning);
      expect(u.mastery.dueAt, now);
      expect(u.mastery.hintLevel, 0);
      expect(u.events.single, isA<PromotionEvent>());
    });
  });

  group('锚点重建立触发（05 §4 / 02 §2.2）', () {
    test('ANCHOR 连续3错 → RebuildTriggerEvent', () {
      final anchor = Mastery(
        itemId: 1,
        state: ItemState.learning,
        lastResults: [tr(correct: false), tr(correct: false), tr(correct: false)],
      );
      final u = checkAnchorRebuild(anchor, config);
      expect(u.events.single, isA<RebuildTriggerEvent>());
      expect((u.events.single as RebuildTriggerEvent).anchorItemId, 1);
    });

    test('2错1对 → 不触发', () {
      final anchor = Mastery(
        itemId: 1,
        lastResults: [tr(correct: false), tr(correct: false), tr()],
      );
      expect(checkAnchorRebuild(anchor, config).events, isEmpty);
    });
  });

  group('applyTrial 辅助（05 §4 / 04 last_results）', () {
    test('追加截断10、rtMedian 无提示子集、hintDependency 最近10', () {
      var m = const Mastery(itemId: 1);
      for (final h in [0, 0, 1, 2, 3, 4, 5, 0, 0, 0]) {
        m = applyTrial(m, tr(rt: 1000, hint: h, correct: h < 5), config);
      }
      expect(m.lastResults.length, 10);
      expect(m.rtMedian, 1000);
      expect(m.hintDependency, closeTo(0.30, 1e-9));
      m = applyTrial(m, tr(rt: 500), config);
      m = applyTrial(m, tr(rt: 500), config);
      expect(m.lastResults.length, 10);
      // 无提示子集 [500,500,1000,1000,1000] → 中位 1000。
      expect(m.rtMedian, 1000);
      expect(m.hintDependency, closeTo(0.30, 1e-9));
    });

    test('全无提示子集为空 → rtMedian=null', () {
      var m = const Mastery(itemId: 1);
      m = applyTrial(m, tr(hint: 2), config);
      expect(m.rtMedian, isNull);
      expect(m.hintDependency, closeTo(0.4, 1e-9));
    });
  });
}