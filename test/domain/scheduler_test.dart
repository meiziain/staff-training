// 规格: 08 §1 T1/T2/T3 —— 质量分映射、间隔阶梯、稳定判定（05 §2）。
import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';

const cfg = Config.defaults;

Trial mkTrial({
  bool correct = true,
  bool timeout = false,
  int? rtMs = 1000,
  int hint = 0,
}) =>
    Trial(
      sessionId: 1,
      itemId: 1,
      presentedAt: 0,
      rtMs: rtMs,
      correct: correct,
      timeout: timeout,
      hintLevelUsed: hint,
      inputSource: InputSource.nameButton,
      contextSnapshot: const ContextSnapshot(clef: Clef.treble, jitterSeed: 0),
    );

TrialResult okResult(int ts) =>
    TrialResult(correct: true, rtMs: 900, hintLevel: 0, ts: ts);

void main() {
  group('T1 质量分映射（05 §2）', () {
    test('正确 零提示 RT=1200 DIRECT(阈值1500) → q5', () {
      expect(quality(mkTrial(rtMs: 1200), ItemType.direct, cfg), 5);
    });
    test('正确 零提示 RT=1600 DIRECT → q4', () {
      expect(quality(mkTrial(rtMs: 1600), ItemType.direct, cfg), 4);
    });
    test('正确 提示级2 → q3', () {
      expect(quality(mkTrial(hint: 2), ItemType.relation, cfg), 3);
    });
    test('错误 → q1', () {
      expect(quality(mkTrial(correct: false), ItemType.direct, cfg), 1);
    });
    test('超时（即使答案碰巧对）→ q1', () {
      expect(
          quality(mkTrial(correct: true, timeout: true), ItemType.direct, cfg),
          1);
    });
  });

  group('T2 间隔阶梯（ease=2.5, factor=1.0）', () {
    late FakeClock clock;
    late int endTs;
    setUp(() {
      clock = FakeClock(localDate: DateTime(2026, 1, 1));
      endTs = clock.localEndOfDayUtcMs(clock.localDate());
    });

    test('新条目 q5×5 → interval 1,3,7,14,30', () {
      var m = const Mastery(itemId: 1, state: ItemState.learning);
      const expected = [1, 3, 7, 14, 30];
      for (var i = 0; i < 5; i++) {
        m = advance(m, 5, endTs, clock, cfg);
        expect(m.intervalDays, expected[i].toDouble());
        expect(m.dueAt,
            clock.localMidnightUtcMs(DateTime(2026, 1, 1 + expected[i])));
        expect(m.state, ItemState.reviewing);
        expect(m.reps, i + 1);
        // 08 T2 表头口径：ease=2.5、factor=1.0。05 §2 每次作答会更新 ease，
        // 本用例隔离阶梯本身，故每步重置 ease=2.5（ease 更新另见第5行用例）。
        m = m.copyWith(ease: 2.5);
      }
    });

    test('rung1(=1天) q3 → ceil((1+3)/2)=2 天，rung 不动', () {
      const m = Mastery(
          itemId: 1, state: ItemState.reviewing, intervalDays: 1);
      expect(currentRung(m, cfg), 1);
      final m2 = advance(m, 3, endTs, clock, cfg);
      expect(m2.intervalDays, 2.0);
      // 同上：按 factor=1.0 口径反查档位（q3 使 ease 2.5→2.36，重置后验证）。
      expect(currentRung(m2.copyWith(ease: 2.5), cfg), 1);
    });

    test('任意 rung q1 → interval 0、due=会话末、lapses+1', () {
      const m = Mastery(
          itemId: 1,
          state: ItemState.reviewing,
          intervalDays: 7,
          lapses: 2);
      final m2 = advance(m, 1, endTs, clock, cfg);
      expect(m2.intervalDays, 0);
      expect(m2.dueAt, endTs);
      expect(m2.lapses, 3);
      expect(m2.state, ItemState.learning);
      expect(currentRung(m2, cfg), 0);
      // 会话已结束（sessionEndTs=null）→ due=本地今日 23:59:59.999。
      final m3 = advance(m, 1, null, clock, cfg);
      expect(m3.dueAt, clock.localEndOfDayUtcMs(DateTime(2026, 1, 1)));
    });

    test('ease=1.3 时 rung2 → 3×(1.3/2.5)=1.56', () {
      final m = Mastery(
          itemId: 1,
          state: ItemState.reviewing,
          ease: 1.3,
          intervalDays: 1 * (1.3 / 2.5));
      expect(currentRung(m, cfg), 1);
      final m2 = advance(m, 5, endTs, clock, cfg);
      expect(m2.intervalDays, closeTo(1.56, 1e-9));
      expect(currentRung(m2, cfg), 2);
    });

    test('q1 后 ease 2.5→1.96，且不低于 1.3', () {
      const m = Mastery(itemId: 1, state: ItemState.reviewing);
      final m2 = advance(m, 1, endTs, clock, cfg);
      expect(m2.ease, closeTo(1.96, 1e-9));
      var m3 = m2;
      for (var i = 0; i < 10; i++) {
        m3 = advance(m3, 1, endTs, clock, cfg);
        expect(m3.ease, greaterThanOrEqualTo(cfg.easeMin));
      }
      expect(m3.ease, cfg.easeMin);
    });
  });

  group('T3 稳定判定（05 §2）', () {
    Mastery base({
      double interval = 7,
      double dep = 0.3,
      List<TrialResult>? results,
    }) =>
        Mastery(
          itemId: 1,
          state: ItemState.reviewing,
          intervalDays: interval,
          hintDependency: dep,
          lastResults: results ??
              List.generate(5, (i) => okResult(i)),
        );

    test('interval=7, dep=0.3, 最近5全对 → stable', () {
      expect(stable(base(), cfg), isTrue);
    });
    test('dep=0.31 → 非', () {
      expect(stable(base(dep: 0.31), cfg), isFalse);
    });
    test('最近5含1错 → 非', () {
      final results = List.generate(5, (i) => okResult(i));
      results[2] =
          const TrialResult(correct: false, rtMs: 900, hintLevel: 0, ts: 2);
      expect(stable(base(results: results), cfg), isFalse);
    });
    test('interval=3 → 非', () {
      expect(stable(base(interval: 3), cfg), isFalse);
    });
  });
}