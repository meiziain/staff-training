// T02 验收：拍网格绝对 onset、无漂移、暂停/恢复与边界。
import 'package:test/test.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/domain/sight_beat_clock.dart';

void main() {
  group('绝对 onset', () {
    test('6 档 BPM × 1000 拍，相对精确拍长误差 <1ms', () {
      for (final bpm in [50, 60, 70, 80, 90, 120]) {
        final clock = SightBeatClock(clock: FakeClock(), bpm: bpm)..start(1000);
        for (var beat = 0; beat < 1000; beat++) {
          final exact = beat * 60000 / bpm;
          expect(
            (clock.onsetOf(beat) - (1000 + exact)).abs(),
            lessThan(1),
            reason: 'bpm=$bpm beat=$beat 出现累积漂移',
          );
          if (beat > 0) {
            final interval = clock.onsetOf(beat) - clock.onsetOf(beat - 1);
            expect((interval - 60000 / bpm).abs(), lessThan(1),
                reason: 'bpm=$bpm 第 $beat 拍间隔偏差');
          }
        }
      }
    });

    test('isDue 以 onset 为界，负 Δ 未到点', () {
      final clock = SightBeatClock(clock: FakeClock(), bpm: 60)..start(0);
      expect(clock.isDue(0, 0), true);
      expect(clock.isDue(1, 999), false);
      expect(clock.isDue(1, 1000), true);
      expect(clock.isDue(2, 1999), false);
      expect(clock.isDue(2, 2000), true);
    });
  });

  group('无累积漂移', () {
    // 项目测试口径用注入 FakeClock（fakeAsync 未在本包 dev_dependencies 暴露）。
    test('注入时钟推进 10s：逐拍 onset 仍等于绝对公式', () {
      final clock = FakeClock();
      final beat = SightBeatClock(clock: clock, bpm: 70)..start(0);
      for (var i = 0; i < 1000; i++) {
        clock.advance(const Duration(milliseconds: 10));
      }
      expect(clock.monoMs, 10000);
      for (var i = 0; i < 200; i++) {
        expect((beat.onsetOf(i) - i * 60000 / 70).abs(), lessThan(1));
      }
      // 10s @70bpm 约覆盖 11 拍：已到点的拍必须 due，下一拍不得提前到点。
      expect(beat.isDue(11, clock.monoMs), true);
      expect(beat.isDue(12, clock.monoMs), false);
    });
  });

  group('暂停 / 恢复', () {
    test('暂停区间不计拍，恢复后起点整体平移', () {
      final clock = SightBeatClock(clock: FakeClock(), bpm: 60)..start(1000);
      expect(clock.onsetOf(1), 2000);

      clock.pause(3000); // 已流逝 2000ms
      expect(clock.isPaused, true);
      // 暂停中获取理论 onset 不抛错；真正判定由 UI 停止 tick。
      expect(clock.onsetOf(1), 2000);

      clock.resume(5000); // 起点平移到 3000
      expect(clock.isPaused, false);
      expect(clock.startMonoMs, 3000);
      expect(clock.onsetOf(0), 3000);
      expect(clock.onsetOf(1), 4000);
    });

    test('重复 pause/resume 幂等，stop 后可重新 start', () {
      final clock = SightBeatClock(clock: FakeClock(), bpm: 60)..start(0);
      clock.pause(500);
      clock.pause(900);
      expect(clock.startMonoMs, 0);
      clock.resume(1000);
      clock.resume(2000);
      expect(clock.startMonoMs, 500, reason: '只平移一次');

      clock.stop();
      expect(clock.isRunning, false);
      clock.start(7000);
      expect(clock.onsetOf(0), 7000);
    });
  });

  group('边界', () {
    test('未 start 时 onsetOf/isDue/pause/resume 抛 StateError', () {
      final clock = SightBeatClock(clock: FakeClock(), bpm: 60);
      expect(() => clock.onsetOf(0), throwsStateError);
      expect(() => clock.isDue(0, 0), throwsStateError);
      expect(() => clock.pause(0), throwsStateError);
      expect(() => clock.resume(0), throwsStateError);
    });

    test('bpm<=0 构造抛 ArgumentError', () {
      for (final bpm in [0, -1]) {
        expect(
          () => SightBeatClock(clock: FakeClock(), bpm: bpm),
          throwsArgumentError,
        );
      }
    });
  });
}
