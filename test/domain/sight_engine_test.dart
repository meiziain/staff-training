// 规格: 11 §3 / T03 —— 拍网格引擎：submit 只入槽，tick 才推进（含 miss 也走）。
import 'package:test/test.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/domain/models/sight_beat_result.dart';
import 'package:sight_reading/domain/models/sight_level.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_beat_clock.dart';
import 'package:sight_reading/domain/sight_engine.dart';

SightScore single(SightMode mode, List<int> seq) {
  final voice =
      mode == SightMode.trebleOnly ? SightVoice.upper : SightVoice.lower;
  return SightScore(
    mode: mode,
    columns: [for (final n in seq) SightColumn.single(voice, n)],
  );
}

SightSessionEngine engineOf(
  SightScore score, {
  SightLevel level = SightLevel.L1,
  int pairWindowMs = 150,
  SightTimingWindow timingWindow = SightTimingWindow.standard,
  Clock? clock,
  int startMs = 0,
  int bpm = 60,
}) {
  final c = clock ?? FakeClock();
  final beat = SightBeatClock(clock: c, bpm: bpm)..start(startMs);
  return SightSessionEngine(
    score,
    level: level,
    pairWindowMs: pairWindowMs,
    timingWindow: timingWindow,
    clock: c,
    beatClock: beat,
  );
}

void main() {
  group('两段式推进', () {
    test('submit 后光标不变，tick 后前进', () {
      final e = engineOf(single(SightMode.trebleOnly, [2, 4, 5]));
      expect(e.totalNotes, 3);
      expect(e.pending.single.diatonicIndex, 2);

      final ok = e.submit(2, atMonoMs: 0);
      expect(ok.accepted, true);
      expect(ok.voice, SightVoice.upper);
      expect(ok.note!.diatonicIndex, 2);
      expect(e.cursorColumnOf(SightVoice.upper), 0, reason: 'submit 不推进');
      expect(e.correctNotes, 0, reason: '结算前不计命中');

      final beat = e.tick(0, nowMonoMs: 10);
      expect(beat.grade, SightHitGrade.onBeat);
      expect(beat.hits.single.voice, SightVoice.upper);
      expect(e.cursorColumnOf(SightVoice.upper), 1);
      expect(e.correctNotes, 1);
      expect(e.progress, closeTo(1 / 3, 1e-9));
    });

    test('答错也走：miss 推进并累计错误', () {
      final e = engineOf(single(SightMode.trebleOnly, [2, 4]));
      final wrong = e.submit(9, atMonoMs: 0);
      expect(wrong.accepted, false);
      expect(wrong.voice, isNull);
      expect(e.cursorColumnOf(SightVoice.upper), 0);

      final beat = e.tick(0, nowMonoMs: 0);
      expect(beat.grade, SightHitGrade.miss);
      expect(beat.hits.single.grade, SightHitGrade.miss);
      expect(e.cursorColumnOf(SightVoice.upper), 1, reason: 'miss 也推进');
      expect(e.errorCount, 1);
      expect(e.missCount, 1);
      expect(e.errorPositions, {2: 1});
    });

    test('走完所有音后 finished，之后提交抛错', () {
      final e = engineOf(single(SightMode.bassOnly, [-7, -5]));
      e.submit(-7, atMonoMs: 0);
      expect(e.tick(0, nowMonoMs: 0).finished, false);
      final last = e.tick(1, nowMonoMs: 1000);
      expect(last.finished, true);
      expect(e.finished, true);
      expect(e.progress, 1);
      expect(() => e.submit(-5), throwsStateError);
    });

    test('单手模式另一声部不参与', () {
      final score = SightScore(mode: SightMode.trebleOnly, columns: [
        const SightColumn(upper: 2, lower: -5),
      ]);
      final e = engineOf(score);
      expect(e.lower, isNull);
      expect(e.totalNotes, 1);
      expect(e.submit(-5, atMonoMs: 0).accepted, false);
      expect(e.tick(0, nowMonoMs: 0).grade, SightHitGrade.miss);
      expect(e.finished, true);
    });
  });

  group('双声部同拍', () {
    SightScore grand() => const SightScore(mode: SightMode.grand, columns: [
          SightColumn(upper: 2, lower: -5),
          SightColumn(upper: 4, lower: null),
          SightColumn(upper: null, lower: -7),
        ]);

    test('先下后上，两声部各自推进', () {
      final e = engineOf(grand());
      expect(e.totalNotes, 4);
      e.submit(-5, atMonoMs: 0);
      e.submit(2, atMonoMs: 0);
      final first = e.tick(0, nowMonoMs: 0);
      expect(first.hits.map((h) => h.voice), [
        SightVoice.upper,
        SightVoice.lower,
      ]);
      expect(e.cursorColumnOf(SightVoice.lower), 2, reason: '跳过休止列');
      expect(e.cursorColumnOf(SightVoice.upper), 1);

      // 两声部剩余音的 onset 都是 0，必须在同一拍 tick 一起结算。
      e.submit(4, atMonoMs: 1000);
      e.submit(-7, atMonoMs: 1000);
      final last = e.tick(1, nowMonoMs: 1000);
      expect(last.hits.length, 2);
      expect(e.upper!.done, true);
      expect(e.lower!.done, true);
      expect(last.finished, true);
    });

    test('两侧同音：两次输入分别归上下，同拍 tick 同时推进', () {
      final e = engineOf(
        const SightScore(mode: SightMode.grand, columns: [
          SightColumn(upper: 0, lower: 0),
        ]),
      );
      expect(e.submit(0, atMonoMs: 0).voice, SightVoice.upper);
      expect(e.submit(0, atMonoMs: 10).voice, SightVoice.lower);
      final beat = e.tick(0, nowMonoMs: 10);
      expect(e.upper!.done, true);
      expect(e.lower!.done, true);
      expect(beat.hits.length, 2);
    });

    test('不匹配任何待答音：整拍 miss 且两轨都推进', () {
      final e = engineOf(grand());
      e.submit(14, atMonoMs: 0);
      final beat = e.tick(0, nowMonoMs: 0);
      expect(beat.hits.length, 2);
      expect(beat.grade, SightHitGrade.miss);
      expect(e.errorCount, 2, reason: '两个声部各记一次 miss');
      expect(e.cursorColumnOf(SightVoice.upper), 1);
      expect(e.cursorColumnOf(SightVoice.lower), 2);
    });
  });

  group('连错提示与统计', () {
    test('连续 miss 3 次 hintDue，命中后清零', () {
      final e = engineOf(single(SightMode.trebleOnly, [2, 4, 5, 6]));
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, true);
      expect(e.errorStreak, 0, reason: '结算前 streak 不变');
      for (var i = 0; i < 3; i++) {
        e.tick(i, nowMonoMs: i * 1000);
      }
      expect(e.errorStreak, 3);
      expect(e.longestHitStreak, 0);

      expect(e.submit(6).accepted, true);
      e.tick(3, nowMonoMs: 3000);
      expect(e.errorStreak, 0);
      expect(e.longestHitStreak, 1);
    });

    test('自定义阈值', () {
      final e = SightSessionEngine(
        single(SightMode.trebleOnly, [2]),
        hintThreshold: 2,
        clock: FakeClock(),
      );
      expect(e.submit(9).hintDue, false);
      expect(e.submit(9).hintDue, true);
    });

    test('空谱例构造抛错；全休止声部按空轨处理', () {
      expect(
        () => SightSessionEngine(
          const SightScore(mode: SightMode.grand, columns: []),
        ),
        throwsArgumentError,
      );
      final e = engineOf(SightScore(mode: SightMode.grand, columns: [
        const SightColumn(upper: 2),
        const SightColumn(upper: 4),
      ]));
      expect(e.lower, isNull);
      e.submit(2);
      e.tick(0, nowMonoMs: 0);
      e.submit(4);
      expect(e.tick(1, nowMonoMs: 1000).finished, true);
    });
  });
}
