// T03 验收：动机库新路径 7 档 × 1000 条不越界、去重、L5  parallelism、强制动机。
import 'package:test/test.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/sight_level.dart';
import 'package:sight_reading/domain/models/sight_motive.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_generator.dart';

void main() {
  group('难度档生成性质', () {
    test('7 档各 1000 条：音域/时长/非空列/节拍全部合法', () {
      for (final level in SightLevel.values) {
        final r = rng(20261201 + level.index);
        final spec = level.spec;
        for (var i = 0; i < 1000; i++) {
          final score = generateSightScore(
            mode: spec.mode,
            level: level,
            rng: r,
            columnCount: 8,
          ).score;
          expect(score.mode, spec.mode);
          expect(score.beatsPerBar, spec.beatsPerBar);
          expect(score.columns, isNotEmpty);
          expect(score.inRange, true, reason: '$level 第 $i 条越界');
          expect(score.columns.any((c) => c.isEmpty), false);
          expect(score.beatCount, greaterThan(0));
          expect(score.motiveIds, isNotNull);
          for (final c in score.columns) {
            expect(c.durationBeats >= 1, true);
            expect(spec.allowedDurations.contains(c.durationBeats), true,
                reason: '$level 出现不允许的时值 ${c.durationBeats}');
            expect(c.onsetBeat >= 0, true);
          }
          if (spec.mode == SightMode.grand) {
            expect(score.voiceAbsent(SightVoice.upper), false);
            expect(score.voiceAbsent(SightVoice.lower), false);
          } else {
            final other = spec.mode == SightMode.trebleOnly
                ? SightVoice.lower
                : SightVoice.upper;
            expect(score.voiceAbsent(other), true);
          }
        }
      }
    });

    test('L5_SR_P 下声部恒为上声部 −7 且同列', () {
      final r = rng(777);
      for (var i = 0; i < 1000; i++) {
        final score = generateSightScore(
          mode: SightMode.grand,
          level: SightLevel.L5_SR_P,
          rng: r,
        ).score;
        for (final c in score.columns) {
          expect(c.upper, isNotNull);
          expect(c.lower, isNotNull);
          expect(c.lower, c.upper! - 7);
        }
      }
    });

    test('forceMotive 强制首个动机', () {
      for (final motive in kP0Motives) {
        final score = generateSightScore(
          mode: SightMode.trebleOnly,
          level: SightLevel.L3,
          rng: rng(42),
          columnCount: 8,
          forceMotive: motive,
        ).score;
        expect(score.motiveIds!.first, motive.wire);
      }
    });

    test('动机签名格式与去重', () {
      final r = rng(31337);
      final recent = <String>[];
      var relaxed = 0;
      for (var i = 0; i < 300; i++) {
        final res = generateSightScore(
          mode: SightMode.trebleOnly,
          level: SightLevel.L3,
          rng: r,
          columnCount: 8,
          recentSignatures: recent,
        );
        final sig = sightMotiveSignature(res.score, SightLevel.L3);
        expect(sig.startsWith('MOTIVE|L3|'), true, reason: '签名前缀: $sig');
        if (res.dedupRelaxed) {
          relaxed++;
        } else {
          final window = recent.length <= 20
              ? recent
              : recent.sublist(recent.length - 20);
          expect(window.contains(sig), false, reason: '与最近窗口重复: $sig');
        }
        recent.add(sig);
      }
      expect(relaxed, lessThan(30), reason: '去重放宽过于频繁: $relaxed/300');
    });

    test('legacy 路径签名格式不变', () {
      final score = generateSightScore(
        mode: SightMode.grand,
        rng: rng(2026),
      ).score;
      expect(sightSignature(score), contains('-99'));
      expect(score.motiveIds, isNull);
    });
  });
}
