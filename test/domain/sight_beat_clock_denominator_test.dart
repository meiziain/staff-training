// T06 验收：拍钟分母缩放；默认 denominator=4 与旧公式逐拍一致（零漂移回归）。
import 'package:test/test.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/domain/sight_beat_clock.dart';

void main() {
  group('拍号分母', () {
    test('denominator=8 的 onset 是 4/4 的一半', () {
      for (final bpm in [50, 60, 70, 80, 90, 120]) {
        final four = SightBeatClock(clock: FakeClock(), bpm: bpm)..start(1000);
        final eight = SightBeatClock(
          clock: FakeClock(),
          bpm: bpm,
          denominator: 8,
        )..start(1000);
        for (var beat = 0; beat < 1000; beat++) {
          // 两次独立 round 可能因奇偶差 1ms，按 ±1ms 容差断言。
          expect(
            ((eight.onsetOf(beat) - 1000) * 2 - (four.onsetOf(beat) - 1000))
                .abs(),
            lessThanOrEqualTo(1),
            reason: 'bpm=$bpm beat=$beat 分母缩放不准',
          );
        }
      }
    });

    test('denominator=4 与旧公式 (beat*60000/bpm).round() 完全一致', () {
      for (final bpm in [50, 60, 70, 80, 90, 120]) {
        final clock = SightBeatClock(clock: FakeClock(), bpm: bpm)..start(0);
        for (var beat = 0; beat < 1000; beat++) {
          expect(clock.onsetOf(beat), (beat * 60000 / bpm).round());
        }
      }
    });

    test('分母 <=0 构造抛 ArgumentError', () {
      for (final denominator in [0, -1]) {
        expect(
          () => SightBeatClock(
            clock: FakeClock(),
            bpm: 60,
            denominator: denominator,
          ),
          throwsArgumentError,
        );
      }
    });
  });
}
