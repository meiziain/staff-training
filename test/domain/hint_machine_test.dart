// 规格: 08 T7/T8 / 05 §7 提示状态机。固定 Config 默认值（04 settings 种子）。
import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/hint_machine.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/mastery.dart';

void main() {
  const config = Config.defaults;

  TrialResult tr(int hint) =>
      TrialResult(correct: hint < 5, rtMs: 1000, hintLevel: hint, ts: 0);

  group('T7 提示状态机', () {
    test('初始 level=3', () {
      expect(HintMachine.initial(config).level, 3);
    });

    test('3连对(零提示,RT<=2000) → level 2', () {
      var m = HintMachine.initial(config);
      for (var i = 0; i < 3; i++) {
        m = m.onCorrect(rtMs: 2000, hintLevelUsed: 0, config: config);
      }
      expect(m.level, 2);
      expect(m.cleanStreak, 0);
    });

    test('level0 时 DIRECTION 错 → 1', () {
      final m = const HintMachine(level: 0)
          .onWrong(errorType: ErrorType.direction, config: config);
      expect(m.level, 1);
    });

    test('level1 时 ANCHOR_ERROR 错 → 4', () {
      final m = const HintMachine(level: 1)
          .onWrong(errorType: ErrorType.anchorError, config: config);
      expect(m.level, 4);
    });

    test('连续第2次错（任意类型）→ 5', () {
      var m = const HintMachine(level: 0)
          .onWrong(errorType: ErrorType.direction, config: config);
      m = m.onWrong(errorType: ErrorType.other, config: config);
      expect(m.level, 5);
      expect(m.consecutiveFail, 2);
    });

    test('级5后答对1题 → consecutiveFail 清零，level 保持5', () {
      var m = const HintMachine(level: 0)
          .onWrong(errorType: ErrorType.direction, config: config)
          .onWrong(errorType: ErrorType.other, config: config);
      m = m.onCorrect(rtMs: 1000, hintLevelUsed: 0, config: config);
      expect(m.consecutiveFail, 0);
      expect(m.level, 5);
    });
  });

  group('T7 补充边界（05 §7）', () {
    test('微课练习期 level=5；DIRECT/ANCHOR 闪现恒0', () {
      expect(HintMachine.microLesson(config).level, 5);
      expect(HintMachine.flash().level, 0);
    });

    test('RT=2001 清零 cleanStreak，不降级', () {
      var m = HintMachine.initial(config);
      m = m.onCorrect(rtMs: 1000, hintLevelUsed: 0, config: config);
      m = m.onCorrect(rtMs: 2001, hintLevelUsed: 0, config: config);
      m = m.onCorrect(rtMs: 1000, hintLevelUsed: 0, config: config);
      expect(m.level, 3);
      expect(m.cleanStreak, 1);
    });

    test('用了提示的正确作答清零 cleanStreak', () {
      var m = HintMachine.initial(config);
      m = m.onCorrect(rtMs: 1000, hintLevelUsed: 0, config: config);
      m = m.onCorrect(rtMs: 1000, hintLevelUsed: 2, config: config);
      expect(m.cleanStreak, 0);
      expect(m.level, 3);
    });

    test('升级只到最低必要层级，不降已有更高级', () {
      final m = const HintMachine(level: 4)
          .onWrong(errorType: ErrorType.distance, config: config);
      expect(m.level, 4);
    });

    test('level0 时3连干净对不再降', () {
      var m = HintMachine.flash();
      for (var i = 0; i < 3; i++) {
        m = m.onCorrect(rtMs: 500, hintLevelUsed: 0, config: config);
      }
      expect(m.level, 0);
    });
  });

  group('T8 提示依赖度', () {
    test('[0,0,1,2,3,4,5,0,0,0] → 0.30（恰好稳定边界）', () {
      final results = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0].map(tr).toList();
      final dep = HintMachine.hintDependency(results, config);
      expect(dep, closeTo(0.30, 1e-9));
      expect(dep <= config.hintDepStableMax, isTrue);
    });

    test('不足10条按实际条数除', () {
      final results = [0, 0, 1].map(tr).toList();
      expect(HintMachine.hintDependency(results, config),
          closeTo(0.2 / 3, 1e-9));
      expect(HintMachine.hintDependency([tr(5)], config), closeTo(1.0, 1e-9));
    });

    test('空集为0；全零提示为0', () {
      expect(HintMachine.hintDependency([], config), 0);
      expect(
          HintMachine.hintDependency(
              List.generate(10, (_) => tr(0)), config),
          0);
    });
  });
}