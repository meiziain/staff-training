// T01 验收：难度阶梯 7 档默认参数与 wire 往返。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_level.dart';
import 'package:sight_reading/domain/models/sight_score.dart';

void main() {
  group('SightLevel 阶梯参数', () {
    test('wire 往返覆盖全部 7 档', () {
      for (final level in SightLevel.values) {
        expect(SightLevel.fromWire(level.wire), level);
      }
    });

    test('L1–L4 单手阶梯', () {
      final l1 = SightLevel.L1.spec;
      expect(l1.mode, SightMode.trebleOnly);
      expect(l1.bpmMin, 50);
      expect(l1.bpmMax, 60);
      expect(l1.pitchMin, 0);
      expect(l1.pitchMax, 4);
      expect(l1.allowedDurations, {1});
      expect(l1.beatsPerBar, 4);
      expect(l1.readAheadBeats, 0);
      expect(l1.previewSeconds, 5);
      expect(l1.sharedCursor, false);

      final l2 = SightLevel.L2.spec;
      expect(l2.mode, SightMode.trebleOnly);
      expect(l2.bpmMin, 60);
      expect(l2.bpmMax, 70);
      expect(l2.pitchMin, 0);
      expect(l2.pitchMax, 7);
      expect(l2.allowedDurations, {1, 2});

      final l3 = SightLevel.L3.spec;
      expect(l3.allowedDurations, {1, 2, 3});
      expect(l3.pitchMin, l2.pitchMin);
      expect(l3.pitchMax, l2.pitchMax);
      expect(l3.bpmMin, l2.bpmMin);
      expect(l3.bpmMax, l2.bpmMax);

      final l4 = SightLevel.L4.spec;
      expect(l4.bpmMin, 60);
      expect(l4.bpmMax, 90);
      expect(l4.pitchMin, 0);
      expect(l4.pitchMax, sightTrebleMax);
      expect(l4.allowedDurations, {1, 2});
      expect(l4.readAheadBeats, inInclusiveRange(2, 4));
      expect(l4.beatsPerBar, inInclusiveRange(3, 4));
      expect(l4.sharedCursor, false);
    });

    test('L5–L7 双谱阶梯与共享光标', () {
      final l5 = SightLevel.L5_SR_P.spec;
      expect(l5.mode, SightMode.grand);
      expect(l5.bpmMin, 50);
      expect(l5.bpmMax, 70);
      expect(l5.allowedDurations, {1});
      expect(l5.sharedCursor, true);
      expect(l5.pitchMin, -7);
      expect(l5.pitchMax, 7);

      final l6 = SightLevel.L6_SR_A.spec;
      expect(l6.mode, SightMode.grand);
      expect(l6.bpmMin, 60);
      expect(l6.bpmMax, 80);
      expect(l6.sharedCursor, true);
      expect(l6.allowedDurations, contains(2), reason: '左手长音需要二分音符');

      final l7 = SightLevel.L7_SR_G.spec;
      expect(l7.mode, SightMode.grand);
      expect(l7.sharedCursor, false);
      expect(l7.allowedDurations, {1, 2});
      expect(l7.pitchMin, sightAllMin);
      expect(l7.pitchMax, sightAllMax);
    });

    test('代表速度 bpm 恒在档位区间内', () {
      for (final level in SightLevel.values) {
        final s = level.spec;
        expect(s.bpm, inInclusiveRange(s.bpmMin, s.bpmMax));
      }
    });
  });
}
