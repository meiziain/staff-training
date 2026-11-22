// T03 验收：四色边界、submit/tick 分工、统计、SR-P 配对窗与拍号单调递增。
import 'package:test/test.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/domain/models/sight_beat_result.dart';
import 'package:sight_reading/domain/models/sight_level.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_beat_clock.dart';
import 'package:sight_reading/domain/sight_engine.dart';

SightSessionEngine oneNote({
  SightLevel level = SightLevel.L1,
  SightTimingWindow window = SightTimingWindow.standard,
  int onsetMs = 0,
  int bpm = 60,
  int pairWindowMs = 150,
  SightScore? score,
}) {
  final clock = FakeClock();
  final beatClock = SightBeatClock(clock: clock, bpm: bpm)..start(onsetMs);
  return SightSessionEngine(
    score ?? const SightScore(
      mode: SightMode.trebleOnly,
      columns: [SightColumn(upper: 2)],
    ),
    level: level,
    timingWindow: window,
    pairWindowMs: pairWindowMs,
    clock: clock,
    beatClock: beatClock,
  );
}

SightHitGrade gradeAt(int deltaMs, {SightTimingWindow window = SightTimingWindow.standard}) {
  final e = oneNote(window: window);
  e.submit(2, atMonoMs: onsetMsOf(e) + deltaMs);
  return e.tick(0, nowMonoMs: onsetMsOf(e) + 1000).grade;
}

int onsetMsOf(SightSessionEngine e) => e.beatClock.onsetOf(0);

void main() {
  group('四色与判定窗', () {
    test('标准窗 ±120：−121/−120/0/+120/+121', () {
      expect(gradeAt(-121), SightHitGrade.early);
      expect(gradeAt(-120), SightHitGrade.onBeat);
      expect(gradeAt(0), SightHitGrade.onBeat);
      expect(gradeAt(120), SightHitGrade.onBeat);
      expect(gradeAt(121), SightHitGrade.late, reason: 'Δ 正号=晚，不得反号');
    });

    test('三档窗口 200/120/80', () {
      expect(SightTimingWindow.relaxed.windowMs, 200);
      expect(SightTimingWindow.normal.windowMs, 120);
      expect(SightTimingWindow.strict.windowMs, 80);
      expect(gradeAt(150, window: SightTimingWindow.relaxed),
          SightHitGrade.onBeat);
      expect(gradeAt(150, window: SightTimingWindow.strict),
          SightHitGrade.late);
    });

    test('音高错记 miss，不以时间窗挽救', () {
      final e = oneNote();
      e.submit(9, atMonoMs: 0);
      final r = e.tick(0, nowMonoMs: 0);
      expect(r.grade, SightHitGrade.miss);
      expect(r.hits.single.deltaMs, isNull);
      expect(e.missCount, 1);
      expect(e.timingBiasMs, 0);
    });
  });

  group('光标与统计', () {
    test('submit 不推进、tick 推进；miss 也推进', () {
      final e = oneNote();
      final before = e.cursorColumnOf(SightVoice.upper);
      e.submit(9, atMonoMs: 0);
      expect(e.cursorColumnOf(SightVoice.upper), before);
      expect(e.pendingInputCount, 1);
      final r = e.tick(0, nowMonoMs: 0);
      expect(e.cursorColumnOf(SightVoice.upper), isNull, reason: '单音已完成');
      expect(e.pendingInputCount, 0);
      expect(r.finished, true);
    });

    test('timingBias 保留符号：早期负、晚期正', () {
      final e = oneNote(
        score: SightScore(
          mode: SightMode.trebleOnly,
          columns: const [
            SightColumn(upper: 2, onsetBeat: 0),
            SightColumn(upper: 4, onsetBeat: 1),
          ],
        ),
      );
      e.submit(2, atMonoMs: -170);
      e.tick(0, nowMonoMs: 0);
      e.submit(4, atMonoMs: 1130);
      e.tick(1, nowMonoMs: 1000);
      expect(e.onBeatCount, 0);
      expect(e.earlyCount, 1);
      expect(e.lateCount, 1);
      expect(e.timingBiasMs, closeTo(-20, 1e-9));
    });

    test('longestHitStreak 为最长连续非 miss 拍', () {
      final seq = [2, 3, 4, 5, 6, 7];
      final e = oneNote(
        score: SightScore(
          mode: SightMode.trebleOnly,
          columns: [
            for (var i = 0; i < seq.length; i++)
              SightColumn(upper: seq[i], onsetBeat: i),
          ],
        ),
      );
      for (var b = 0; b < seq.length; b++) {
        if (b == 3) {
          e.submit(99, atMonoMs: b * 1000);
        } else {
          e.submit(seq[b], atMonoMs: b * 1000);
        }
        e.tick(b, nowMonoMs: b * 1000);
      }
      expect(e.longestHitStreak, 3);
      expect(e.correctNotes, 5);
      expect(e.errorCount, 1);
      expect(e.progress, 1, reason: 'miss 也推进，完成后进度为 1');
    });

    test('skipCurrentBeat 强制 miss 并推进', () {
      final e = oneNote();
      final r = e.skipCurrentBeat(nowMonoMs: 0);
      expect(r.skipped, true);
      expect(r.grade, SightHitGrade.miss);
      expect(e.finished, true);
      expect(e.missCount, 1);
    });

    test('beatIndex 必须严格递增', () {
      final e = oneNote(
        score: SightScore(
          mode: SightMode.trebleOnly,
          columns: const [
            SightColumn(upper: 2, onsetBeat: 0),
            SightColumn(upper: 3, onsetBeat: 1),
          ],
        ),
      );
      e.tick(0, nowMonoMs: 0);
      expect(() => e.tick(0, nowMonoMs: 0), throwsStateError);
      expect(() => e.tick(-1, nowMonoMs: 0), throwsStateError);
    });
  });

  group('SR-P 共享光标配对窗', () {
    SightScore grand() => const SightScore(
          mode: SightMode.grand,
          columns: [SightColumn(upper: 2, lower: -5, onsetBeat: 0, durationBeats: 1)],
        );

    test('时差 ≤150ms 配对成功，>150ms 不配对', () {
      final ok = oneNote(
        level: SightLevel.L5_SR_P,
        onsetMs: 1000,
        score: grand(),
      );
      ok.submit(2, atMonoMs: 980); // Δ=-20
      ok.submit(-5, atMonoMs: 1130); // Δ=+130（late），差 150
      final r = ok.tick(0, nowMonoMs: 1150);
      expect(r.paired, true);
      expect(r.grade, SightHitGrade.late, reason: '聚合含 late');

      final bad = oneNote(
        level: SightLevel.L5_SR_P,
        onsetMs: 1000,
        score: grand(),
      );
      bad.submit(2, atMonoMs: 850); // Δ=-150
      bad.submit(-5, atMonoMs: 1130); // Δ=+130，差 280
      expect(bad.tick(0, nowMonoMs: 1150).paired, false);
    });

    test('单音错给分项 hits（一命中一 miss）但仍推进', () {
      final e = oneNote(
        level: SightLevel.L5_SR_P,
        onsetMs: 1000,
        score: grand(),
      );
      e.submit(2, atMonoMs: 1000);
      final r = e.tick(0, nowMonoMs: 1000);
      expect(r.hits.length, 2);
      expect(r.hits.map((h) => h.grade), [
        SightHitGrade.onBeat,
        SightHitGrade.miss,
      ]);
      expect(r.paired, false);
      expect(e.upper!.done, true);
      expect(e.lower!.done, true, reason: 'miss 也推进');
    });
  });
}
