// 规格: 11 §4 —— 视奏生成器性质测试（固定种子各跑 1000 次）。
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_generator.dart';

void main() {
  group('单手生成', () {
    test('高音谱表：8/12/16 列、音域 C4–C6、级进≥60%、无四度以上跳进', () {
      final r = rng(20261121);
      for (final len in sightSingleLengths) {
        for (var i = 0; i < 1000; i++) {
          final score = generateSightScore(
            mode: SightMode.trebleOnly,
            rng: r,
            columnCount: len,
          ).score;
          expect(score.columns.length, len);
          expect(score.mode, SightMode.trebleOnly);
          final seq = score.sequenceOf(SightVoice.upper).whereType<int>().toList();
          expect(seq.length, len, reason: '上声部每列都应有音');
          expect(score.sequenceOf(SightVoice.lower).every((e) => e == null), true,
              reason: '单手高音谱例下声部必须全空');
          for (final n in seq) {
            expect(n >= sightTrebleMin && n <= sightTrebleMax, true,
                reason: '越出高音音域 C4–C6: $seq');
          }
          _checkSteps(seq, maxLeap: 2, label: 'treble-$len');
        }
      }
    });

    test('低音谱表：音域 C2–C4（含新下探音位）、级进≥60%', () {
      final r = rng(777);
      var sawC2 = false;
      for (var i = 0; i < 1000; i++) {
        final score = generateSightScore(
          mode: SightMode.bassOnly,
          rng: r,
          columnCount: 12,
        ).score;
        final seq = score.sequenceOf(SightVoice.lower).whereType<int>().toList();
        expect(score.sequenceOf(SightVoice.upper).every((e) => e == null), true,
            reason: '单手低音谱例上声部必须全空');
        for (final n in seq) {
          expect(n >= sightBassMin && n <= sightBassMax, true,
              reason: '越出低音音域 C2–C4: $seq');
          if (n == sightBassMin) sawC2 = true;
        }
        _checkSteps(seq, maxLeap: 2, label: 'bass-12');
      }
      expect(sawC2, true, reason: '1000 条低音谱例应至少出现一次 C2');
    });

    test('起音落在音域中部 ±3 度', () {
      final r = rng(99);
      for (var i = 0; i < 200; i++) {
        final t = generateSightScore(mode: SightMode.trebleOnly, rng: r).score;
        final first = t.columns.first.upper!;
        expect(first >= 4 && first <= 10, true, reason: '高音起音应在中部 C5±3: $first');
        final b = generateSightScore(mode: SightMode.bassOnly, rng: r).score;
        final bf = b.columns.first.lower!;
        expect(bf >= -10 && bf <= -4, true, reason: '低音起音应在中部 C3±3: $bf');
      }
    });
  });

  group('双手生成', () {
    test('默认 8 列、两声部音数范围、双声部列≥1、单声部列≤ceil(0.7N)', () {
      final r = rng(31415);
      for (var i = 0; i < 1000; i++) {
        final score = generateSightScore(mode: SightMode.grand, rng: r).score;
        final n = score.columns.length;
        expect(n, 8, reason: '默认列数应为 8: $n');
        final uCount = score.noteCountOf(SightVoice.upper);
        final lCount = score.noteCountOf(SightVoice.lower);
        expect(uCount >= 4 && uCount <= 10, true, reason: '上声部音数: $uCount');
        expect(lCount >= 3 && lCount <= 8, true, reason: '下声部音数: $lCount');

        var both = 0;
        var single = 0;
        for (final c in score.columns) {
          expect(c.isEmpty, false, reason: '不允许整列空白: $score');
          if (c.upper != null && c.lower != null) {
            both++;
          } else {
            single++;
          }
        }
        expect(both >= 1, true, reason: '至少 1 列双声部');
        expect(single >= 1, true, reason: '至少 1 列单声部');
        expect(single <= (n * 0.7).ceil(), true,
            reason: '单声部列超出上限（N=$n, single=$single）');

        final u = score.sequenceOf(SightVoice.upper).whereType<int>().toList();
        final l = score.sequenceOf(SightVoice.lower).whereType<int>().toList();
        for (final x in u) {
          expect(x >= sightTrebleMin && x <= sightTrebleMax, true,
              reason: '上声部越界: $u');
        }
        for (final x in l) {
          expect(x >= sightBassMin && x <= sightBassMax, true,
              reason: '下声部越界: $l');
        }
        _checkSteps(u, maxLeap: 2, label: 'grand-upper');
        _checkSteps(l, maxLeap: 3, label: 'grand-lower');
      }
    });

    test('起音间距 8–12 自然音级，结束音落 C/F/G', () {
      final r = rng(2718);
      for (var i = 0; i < 500; i++) {
        final score = generateSightScore(mode: SightMode.grand, rng: r).score;
        final u = score.sequenceOf(SightVoice.upper).whereType<int>().toList();
        final l = score.sequenceOf(SightVoice.lower).whereType<int>().toList();
        final gap = u.first - l.first;
        expect(gap >= 8 && gap <= 12, true, reason: '起音间距: $gap ($u / $l)');
        for (final end in [u.last, l.last]) {
          expect(const {0, 3, 4}.contains(mod(end, 7)), true,
              reason: '结束音须为 C/F/G: idx=$end ($u / $l)');
        }
      }
    });

    test('音域跨度：上声部触达 C6、下声部下探到 A2 以下', () {
      final r = rng(4242);
      var uMax = -99;
      var lMin = 99;
      for (var i = 0; i < 1000; i++) {
        final score = generateSightScore(mode: SightMode.grand, rng: r).score;
        for (final x in score.sequenceOf(SightVoice.upper).whereType<int>()) {
          if (x > uMax) uMax = x;
        }
        for (final x in score.sequenceOf(SightVoice.lower).whereType<int>()) {
          if (x < lMin) lMin = x;
        }
      }
      expect(uMax, sightTrebleMax, reason: '1000 条内应触达 C6（实测 max=$uMax）');
      // 双手起音间距 8–12 把下声部起点限制在 C4 以下 4 度内，C2 概率极低；
      // 单手低音模式已在上面单独验证 C2 可达。
      expect(lMin <= -10, true, reason: '下声部应下探到 A2 以下（实测 min=$lMin）');
    });
  });

  group('旋律方向感（修正"波浪型"反馈）', () {
    test('1000 条里同向连续步占比 ≥ 55%，且多数谱例有长度 ≥4 的同向段', () {
      final r = rng(20261121);
      var sameDir = 0;
      var totalSteps = 0;
      var withLongRun = 0;
      for (var i = 0; i < 1000; i++) {
        final score = generateSightScore(
          mode: SightMode.trebleOnly,
          rng: r,
          columnCount: 12,
        ).score;
        final seq = score.sequenceOf(SightVoice.upper).whereType<int>().toList();
        var run = 1;
        var maxRun = 1;
        var lastSign = (seq[1] - seq[0]).sign;
        for (var k = 2; k < seq.length; k++) {
          final sign = (seq[k] - seq[k - 1]).sign;
          if (sign == lastSign) {
            sameDir++;
            run++;
          } else {
            run = 1;
          }
          if (run > maxRun) maxRun = run;
          lastSign = sign;
          totalSteps++;
        }
        if (maxRun >= 4) withLongRun++;
      }
      final ratio = sameDir / totalSteps;
      expect(ratio >= 0.55, true,
          reason: '连续同向占比 ${(ratio * 100).toStringAsFixed(1)}%，方向惯性不足');
      expect(withLongRun >= 500, true,
          reason: '只有 $withLongRun/1000 条出现长度 ≥4 的同向段，仍是等幅锯齿');
    });
  });

  group('去重与确定性', () {
    test('最近 20 条不重复；放宽时置标记', () {
      final r = rng(555);
      final recent = <String>[];
      var relaxed = 0;
      for (var i = 0; i < 600; i++) {
        final res = generateSightScore(
          mode: SightMode.trebleOnly,
          rng: r,
          columnCount: 8,
          recentSignatures: recent,
        );
        final sig = sightSignature(res.score);
        if (!res.dedupRelaxed) {
          // 生成器只对照最近 20 条去重，历史更早的重复不算违规。
          final window = recent.length <= 20
              ? recent
              : recent.sublist(recent.length - 20);
          expect(window.contains(sig), false, reason: '第 $i 条与最近窗口重复: $sig');
        } else {
          relaxed++;
        }
        recent.add(sig);
      }
      expect(relaxed, lessThan(30), reason: '去重放宽不应频繁发生');
    });

    test('同种子同结果', () {
      final a = generateSightScore(mode: SightMode.grand, rng: rng(2026)).score;
      final b = generateSightScore(mode: SightMode.grand, rng: rng(2026)).score;
      expect(a.columns, b.columns);
    });
  });

  group('自定义长度（S7 滑杆：单手 4–32 音 / 双手 4–12 列）', () {
    test('单手 4 / 18 / 32 音各 100 条：列数正确、音域与步长约束全满足', () {
      final r = rng(20261122);
      void check(SightMode mode, SightVoice voice, int len) {
        final score = generateSightScore(
          mode: mode,
          rng: r,
          columnCount: len,
        ).score;
        expect(score.columns.length, len, reason: '${mode.wire}-$len 列数');
        final seq = score.sequenceOf(voice).whereType<int>().toList();
        expect(seq.length, len, reason: '${mode.wire}-$len 该声部每列都应有音');
        final other =
            voice == SightVoice.upper ? SightVoice.lower : SightVoice.upper;
        expect(score.sequenceOf(other).every((e) => e == null), true,
            reason: '${mode.wire}-$len 另一声部必须全空');
        for (final n in seq) {
          expect(n >= sightVoiceMin(voice) && n <= sightVoiceMax(voice), true,
              reason: '${mode.wire}-$len 越界: $seq');
        }
        _checkSteps(seq, maxLeap: 2, label: '${mode.wire}-$len');
      }

      for (final len in const [sightSingleMinCount, 18, sightSingleMaxCount]) {
        for (var i = 0; i < 100; i++) {
          check(SightMode.trebleOnly, SightVoice.upper, len);
        }
        for (var i = 0; i < 100; i++) {
          check(SightMode.bassOnly, SightVoice.lower, len);
        }
      }
    });

    test('双手 4 / 10 / 12 列各 100 条：both≥1、无空列、音数区间正确', () {
      final r = rng(20261123);
      for (final n in const [sightGrandMinColumns, 10, sightGrandMaxColumns]) {
        final uMin = math.max(4, (n * 0.5).ceil());
        final uMax = math.min(10, n);
        final lMin = math.max(3, (n * 0.4).ceil());
        final lMax = math.min(8, n);
        for (var i = 0; i < 100; i++) {
          final score = generateSightScore(
            mode: SightMode.grand,
            rng: r,
            columnCount: n,
          ).score;
          expect(score.columns.length, n, reason: 'N=$n 列数');
          final uCount = score.noteCountOf(SightVoice.upper);
          final lCount = score.noteCountOf(SightVoice.lower);
          expect(uCount >= uMin && uCount <= uMax, true,
              reason: 'N=$n 上声部音数 $uCount 应在 [$uMin,$uMax]');
          expect(lCount >= lMin && lCount <= lMax, true,
              reason: 'N=$n 下声部音数 $lCount 应在 [$lMin,$lMax]');

          var both = 0;
          var single = 0;
          for (final c in score.columns) {
            expect(c.isEmpty, false, reason: 'N=$n 出现整列空白: $score');
            if (c.upper != null && c.lower != null) {
              both++;
            } else {
              single++;
            }
          }
          expect(both, uCount + lCount - n, reason: 'N=$n 双声部列数应唯一确定');
          expect(both >= 1, true, reason: 'N=$n 至少 1 列双声部');
          expect(single <= (n * 0.7).ceil(), true,
              reason: 'N=$n 单声部列超上限: single=$single');

          final u =
              score.sequenceOf(SightVoice.upper).whereType<int>().toList();
          final l =
              score.sequenceOf(SightVoice.lower).whereType<int>().toList();
          expect(u.length, uCount);
          expect(l.length, lCount);
          for (final x in u) {
            expect(x >= sightTrebleMin && x <= sightTrebleMax, true,
                reason: 'N=$n 上声部越界: $u');
          }
          for (final x in l) {
            expect(x >= sightBassMin && x <= sightBassMax, true,
                reason: 'N=$n 下声部越界: $l');
          }
          _checkSteps(u, maxLeap: 2, label: 'grand-$n-upper');
          _checkSteps(l, maxLeap: 3, label: 'grand-$n-lower');
          final gap = u.first - l.first;
          expect(gap >= 8 && gap <= 12, true, reason: 'N=$n 起音间距: $gap');
          for (final end in [u.last, l.last]) {
            expect(const {0, 3, 4}.contains(mod(end, 7)), true,
                reason: 'N=$n 结束音须为 C/F/G: idx=$end');
          }
        }
      }
    });
  });
}

void _checkSteps(List<int> seq, {required int maxLeap, required String label}) {
  var steps = 0;
  for (var i = 1; i < seq.length; i++) {
    final d = (seq[i] - seq[i - 1]).abs();
    expect(d >= 1, true, reason: '[$label] 出现同音重复或停滞: $seq');
    expect(d <= maxLeap, true, reason: '[$label] 跳进超过上限 $maxLeap: $seq');
    if (d == 1) steps++;
  }
  expect(steps / (seq.length - 1) >= 0.6, true,
      reason: '[$label] 级进比例不足: '
          '${(steps / (seq.length - 1) * 100).toStringAsFixed(0)}% $seq');
}
