// T03 验收：旧 submit 直接推进语义完整迁移到 SightFreeEngine（分手练习入口）。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_free_engine.dart';

SightScore single(SightMode mode, List<int> seq) {
  final voice =
      mode == SightMode.trebleOnly ? SightVoice.upper : SightVoice.lower;
  return SightScore(
    mode: mode,
    columns: [for (final n in seq) SightColumn.single(voice, n)],
  );
}

void main() {
  group('单手推进', () {
    test('答对前进、答错原地不动并累计错误', () {
      final e = SightFreeEngine(single(SightMode.trebleOnly, [2, 4, 5]));
      expect(e.totalNotes, 3);
      expect(e.pending.single.diatonicIndex, 2);

      final wrong = e.submit(4);
      expect(wrong.accepted, false);
      expect(wrong.voice, isNull);
      expect(e.errorCount, 1);
      expect(e.pending.single.diatonicIndex, 2, reason: '答错不得推进');

      final ok = e.submit(2);
      expect(ok.accepted, true);
      expect(ok.voice, SightVoice.upper);
      expect(ok.note!.diatonicIndex, 2);
      expect(e.cursorColumnOf(SightVoice.upper), 1);
      expect(e.correctNotes, 1);
      expect(e.progress, closeTo(1 / 3, 1e-9));
    });

    test('走完全部音后 finished，之后提交抛错', () {
      final e = SightFreeEngine(single(SightMode.bassOnly, [-7, -5]));
      expect(e.submit(-7).finished, false);
      final last = e.submit(-5);
      expect(last.finished, true);
      expect(e.finished, true);
      expect(e.progress, 1);
      expect(() => e.submit(-5), throwsStateError);
    });

    test('单手模式另一声部不参与（即便谱例里混入也不建轨）', () {
      final score = SightScore(mode: SightMode.trebleOnly, columns: [
        const SightColumn(upper: 2, lower: -5),
      ]);
      final e = SightFreeEngine(score);
      expect(e.lower, isNull);
      expect(e.totalNotes, 1);
      expect(e.submit(-5).accepted, false);
    });
  });

  group('双声部独立光标', () {
    SightScore grand() => const SightScore(mode: SightMode.grand, columns: [
          SightColumn(upper: 2, lower: -5),
          SightColumn(upper: 4, lower: null),
          SightColumn(upper: null, lower: -7),
        ]);

    test('先下后上，两个光标各自推进', () {
      final e = SightFreeEngine(grand());
      expect(e.totalNotes, 4);

      var r = e.submit(-5);
      expect(r.accepted, true);
      expect(r.voice, SightVoice.lower);
      expect(e.cursorColumnOf(SightVoice.lower), 2, reason: '跳过列 1 的休止');
      expect(e.cursorColumnOf(SightVoice.upper), 0, reason: '上声部不受影响');

      r = e.submit(2);
      expect(r.voice, SightVoice.upper);
      expect(e.cursorColumnOf(SightVoice.upper), 1);

      r = e.submit(-7);
      expect(r.voice, SightVoice.lower);
      expect(e.lower!.done, true);
      expect(e.finished, false, reason: '上声部还剩列 1');

      r = e.submit(4);
      expect(r.finished, true);
    });

    test('可先走完上声部再走下声部（单谱走）', () {
      final e = SightFreeEngine(grand());
      expect(e.submit(2).accepted, true);
      expect(e.submit(4).accepted, true);
      expect(e.upper!.done, true);
      expect(e.finished, false);
      expect(e.submit(-5).accepted, true);
      expect(e.submit(-7).finished, true);
    });

    test('两侧同音：一次输入只满足上声部，第二次才满足下声部', () {
      final e = SightFreeEngine(
        const SightScore(mode: SightMode.grand, columns: [
          SightColumn(upper: 0, lower: 0),
        ]),
      );
      final first = e.submit(0);
      expect(first.voice, SightVoice.upper);
      expect(e.upper!.done, true);
      expect(e.lower!.done, false);
      final second = e.submit(0);
      expect(second.voice, SightVoice.lower);
      expect(second.finished, true);
    });

    test('不匹配任何待答音时两个光标都不动', () {
      final e = SightFreeEngine(grand());
      final r = e.submit(14);
      expect(r.accepted, false);
      expect(e.cursorColumnOf(SightVoice.upper), 0);
      expect(e.cursorColumnOf(SightVoice.lower), 0);
      expect(e.errorCount, 1);
    });
  });

  group('连错提示与统计', () {
    test('连错 3 次 hintDue，答对后清零重新计数', () {
      final e = SightFreeEngine(single(SightMode.trebleOnly, [2, 4]));
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, true);
      expect(e.errorStreak, 3);

      expect(e.submit(2).accepted, true);
      expect(e.errorStreak, 0);

      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, true);
    });

    test('自定义阈值', () {
      final e = SightFreeEngine(
        single(SightMode.trebleOnly, [2]),
        hintThreshold: 2,
      );
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, true);
    });

    test('易错音位统计：双手两侧待答只记上声部', () {
      final e = SightFreeEngine(
        const SightScore(mode: SightMode.grand, columns: [
          SightColumn(upper: 2, lower: -5),
        ]),
      );
      e.submit(9);
      expect(e.errorPositions, {2: 1});
    });
  });

  group('边界', () {
    test('空谱例构造抛错', () {
      expect(
        () => SightFreeEngine(
          const SightScore(mode: SightMode.grand, columns: []),
        ),
        throwsArgumentError,
      );
    });

    test('doneColumns 只含已答列', () {
      final e = SightFreeEngine(single(SightMode.trebleOnly, [2, 4, 5]));
      e.submit(2);
      expect(e.upper!.doneColumns, [0]);
      e.submit(4);
      expect(e.upper!.doneColumns.toList(), [0, 1]);
    });
  });
}
