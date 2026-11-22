// T01 验收：P0 五个动机的 applyFrom / fits / 跳进上限。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_motive.dart';

void main() {
  group('P0 动机库', () {
    test('五个种类、时长全 1、无四度以上跳进', () {
      expect(kP0Motives.length, 5);
      expect(
        kP0Motives.map((m) => m.kind).toSet(),
        SightMotiveKind.values.toSet(),
      );
      for (final m in kP0Motives) {
        expect(m.steps.length, 2);
        expect(m.durations, [1, 1]);
        for (final step in m.steps) {
          expect(step.abs(), lessThanOrEqualTo(2), reason: 'P0 禁止四度以上跳进');
        }
      }
    });

    test('applyFrom 含起始音且逐步累加', () {
      expect(stepUpMotive.applyFrom(0), [0, 1, 2]);
      expect(stepDownMotive.applyFrom(4), [4, 3, 2]);
      expect(skipReturnMotive.applyFrom(0), [0, 2, 1]);
      expect(repeatMotive.applyFrom(3), [3, 3, 3]);
      expect(neighborMotive.applyFrom(0), [0, 1, 0]);
      for (final m in kP0Motives) {
        final out = m.applyFrom(5);
        expect(out.length, m.steps.length + 1);
        expect(out.first, 5);
      }
    });

    test('fits 同时检查起点与每个落点', () {
      expect(stepUpMotive.fits(0, 0, 2), true);
      expect(stepUpMotive.fits(0, 0, 1), false, reason: '落点 2 越界');
      expect(stepUpMotive.fits(-1, -1, 0), false, reason: '第二个落点 1 越界');
      expect(stepDownMotive.fits(0, -2, 0), true);
      expect(stepDownMotive.fits(0, -1, 0), false);
      expect(skipReturnMotive.fits(0, 0, 2), true);
      expect(skipReturnMotive.fits(0, 0, 1), false);
      expect(repeatMotive.fits(7, 0, 7), true);
      expect(repeatMotive.fits(8, 0, 7), false, reason: '起点越界');
      expect(neighborMotive.fits(0, 0, 1), true);
      expect(neighborMotive.fits(0, 1, 3), false);
    });

    test('wire 往返', () {
      for (final m in kP0Motives) {
        expect(SightMotiveKind.fromWire(m.wire), m.kind);
      }
    });
  });
}
