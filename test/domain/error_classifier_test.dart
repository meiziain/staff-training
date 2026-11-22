// 规格: 08 T9 错误判定优先级 / 05 §5 唯一优先级。固定 Config 默认值。
import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/domain/error_classifier.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';

void main() {
  const config = Config.defaults;
  const nameMode = InputMode.nameButtons;

  Item relation(int anchor, int dir, int steps) => Item(
        id: 1,
        type: ItemType.relation,
        payload: RelationPayload.single(
            anchorIndex: anchor, direction: dir, steps: steps),
        createdAt: 0,
      );
  Item direct(int i) => Item(
        id: 2,
        type: ItemType.direct,
        payload: DirectPayload(diatonicIndex: i),
        createdAt: 0,
      );

  Classification run({
    required Item item,
    required int target,
    required String? answer,
    int? octave,
    InputMode mode = nameMode,
    int stage = 2,
    int rtMs = 1500,
    bool timeout = false,
    required bool correct,
  }) =>
      classify(
        item: item,
        targetIndex: target,
        answerPitchClass: answer,
        answerOctave: octave,
        mode: mode,
        stage: stage,
        rtMs: rtMs,
        timeout: timeout,
        correct: correct,
        config: config,
      );

  group('T9 错误判定优先级', () {
    test('RELATION 锚G4→目标A4 答G → ANCHOR_ERROR（优先于相邻线间）', () {
      final r = run(
          item: relation(4, 1, 2), target: 5, answer: 'G', correct: false);
      expect(r.errorType, ErrorType.anchorError);
      expect(r.seedPair, (4, 5));
    });

    test('目标A4 答B4 → LINE_SPACE', () {
      final r = run(item: direct(5), target: 5, answer: 'B', correct: false);
      expect(r.errorType, ErrorType.lineSpace);
      expect(r.seedPair, (5, 6));
    });

    test('目标A4 答C5 → DISTANCE', () {
      final r = run(item: direct(5), target: 5, answer: 'C', correct: false);
      expect(r.errorType, ErrorType.distance);
      expect(r.seedPair, (5, 7));
    });

    test('键盘模式 目标C4 答C5 → OCTAVE', () {
      final r = run(
        item: direct(0),
        target: 0,
        answer: 'C',
        octave: 5,
        mode: InputMode.virtualKey,
        correct: false,
      );
      expect(r.errorType, ErrorType.octave);
      // 05 §5：answerIndex=同音名最近音位=target 自身，pair=(0,0)。
      expect(r.seedPair, (0, 0));
    });

    test('阶段3 目标C5(7) 答E（pitchClass(-5)）→ CROSS_CLEF', () {
      final r = run(
          item: direct(7), target: 7, answer: 'E', stage: 3, correct: false);
      expect(r.errorType, ErrorType.crossClef);
      expect(r.seedPair, (7, 9));
    });

    test('锚C4→目标E4(上行) 答B3 → DIRECTION', () {
      final r = run(
          item: relation(0, 1, 3), target: 2, answer: 'B', correct: false);
      expect(r.errorType, ErrorType.direction);
      expect(r.seedPair, (-1, 2));
    });

    test('超时 → TIMEOUT（无作答则无 seedPair）', () {
      final r = run(
          item: direct(5),
          target: 5,
          answer: null,
          timeout: true,
          correct: false);
      expect(r.errorType, ErrorType.timeout);
      expect(r.seedPair, isNull);
    });

    test('正确 RT=4500 → SLOW_CORRECT（correct 保持1，不写 seed）', () {
      final r = run(
          item: direct(5), target: 5, answer: 'A', rtMs: 4500, correct: true);
      expect(r.errorType, ErrorType.slowCorrect);
      expect(r.seedPair, isNull);
    });

    test('错误试次 confusion_seed pair = sort(targetIndex, answerIndex)', () {
      // 答案在目标下方：pair 仍按 min/max 排序。
      final r = run(item: direct(2), target: 2, answer: 'D', correct: false);
      expect(r.errorType, ErrorType.lineSpace);
      expect(r.seedPair, (1, 2));
    });
  });

  group('T9 补充边界（05 §5）', () {
    test('正确且非慢 → errorType=null', () {
      final r = run(
          item: direct(5), target: 5, answer: 'A', rtMs: 4000, correct: true);
      expect(r.errorType, isNull);
      expect(r.seedPair, isNull);
    });

    test('阶段<3 不判 CROSS_CLEF：目标C5 答E → DISTANCE', () {
      final r = run(
          item: direct(7), target: 7, answer: 'E', stage: 2, correct: false);
      expect(r.errorType, ErrorType.distance);
    });

    test('键盘模式八度相同且正确 → null', () {
      final r = run(
        item: direct(0),
        target: 0,
        answer: 'C',
        octave: 4,
        mode: InputMode.virtualKey,
        correct: true,
      );
      expect(r.errorType, isNull);
    });

    test('音名模式不判 OCTAVE（answer 无 octave）', () {
      final r = run(item: direct(0), target: 0, answer: 'C', correct: true);
      expect(r.errorType, isNull);
    });

    test('远距离错误 → OTHER', () {
      // 目标C4(0) 答F：answerIndex=3（F4，差3）→ 非1/2 → OTHER。
      final r = run(item: direct(0), target: 0, answer: 'F', correct: false);
      expect(r.errorType, ErrorType.other);
      expect(r.seedPair, (0, 3));
    });
  });
}