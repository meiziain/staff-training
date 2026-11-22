// 规格: 11 §4.2 §5 —— 内置曲目资源逐条校验。
//
// 目的：手写 JSON 的旋律也要被机器守住约束，不允许「看起来差不多」就越界。
// 直接读 assets/scores/*.json 真实文件，而不是测试内构造的等价对象。
import 'dart:io';

import 'package:test/test.dart';

import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/score_library.dart';

/// 期望的 6 条曲目：文件 → 模式。
const Map<String, SightMode> expectedScores = {
  'assets/scores/sr_treble_01.json': SightMode.trebleOnly,
  'assets/scores/sr_treble_02.json': SightMode.trebleOnly,
  'assets/scores/sr_bass_01.json': SightMode.bassOnly,
  'assets/scores/sr_bass_02.json': SightMode.bassOnly,
  'assets/scores/sr_grand_01.json': SightMode.grand,
  'assets/scores/sr_grand_02.json': SightMode.grand,
};

/// 该声部的实际音序（跳过休止列）。
List<int> seqOf(SightScore score, SightVoice voice) =>
    score.sequenceOf(voice).whereType<int>().toList();

/// 级进（±1）步数占比；不足 2 个音时视为满足（无步可判）。
double progressionRatio(List<int> seq) {
  if (seq.length < 2) return 1;
  var steps = 0;
  for (var i = 1; i < seq.length; i++) {
    if ((seq[i] - seq[i - 1]).abs() == 1) steps++;
  }
  return steps / (seq.length - 1);
}

int maxStep(List<int> seq) {
  var m = 0;
  for (var i = 1; i < seq.length; i++) {
    final d = (seq[i] - seq[i - 1]).abs();
    if (d > m) m = d;
  }
  return m;
}

/// 收束音级：C/F/G（自然音级 mod 7 ∈ {0,3,4}）。
bool isStableEnd(int index) => const {0, 3, 4}.contains(index % 7);

void main() {
  group('解析器', () {
    test('6 条曲目全部解析成功、音域合法', () {
      expect(expectedScores.length, 6);
      for (final entry in expectedScores.entries) {
        final score = scoreFromJsonString(
          File(entry.key).readAsStringSync(),
        );
        expect(score.mode, entry.value, reason: entry.key);
        expect(score.scoreId, isNotNull, reason: entry.key);
        expect(score.title, isNotNull, reason: entry.key);
        expect(score.columns, isNotEmpty, reason: entry.key);
        expect(score.inRange, isTrue, reason: '${entry.key} 音域越界');
      }
    });

    test('id 唯一、三种模式各 2 条', () {
      final scores = [
        for (final path in expectedScores.keys)
          scoreFromJsonString(File(path).readAsStringSync()),
      ];
      expect(scores.map((s) => s.scoreId).toSet().length, 6);
      for (final mode in SightMode.values) {
        expect(scores.where((s) => s.mode == mode).length, 2,
            reason: mode.wire);
      }
    });

    test('resource 清单与文件一一对应', () {
      expect(builtinScoreAssetPaths.toSet(), expectedScores.keys.toSet());
      for (final path in builtinScoreAssetPaths) {
        expect(File(path).existsSync(), isTrue, reason: '$path 不存在');
      }
    });

    test('非法输入抛 FormatException', () {
      expect(() => scoreFromJsonString('not json'),
          throwsA(isA<FormatException>()));
      expect(() => scoreFromJsonString('[]'),
          throwsA(isA<FormatException>()));
      expect(
          () => scoreFromJsonString(
              '{"id":"x","mode":"nope","columns":[[0]]}'),
          throwsA(isA<FormatException>()));
      expect(
          () => scoreFromJsonString('{"id":"x","mode":"grand","columns":[]}'),
          throwsA(isA<FormatException>()));
      expect(() => parseScoreLibrary('{}'),
          throwsA(isA<FormatException>()));
      expect(() => parseScoreLibrary('[1,2]'),
          throwsA(isA<FormatException>()));
    });

    test('数组根解析出多条；位置错误带序号', () {
      final json = '['
          '{"id":"a","name":"A","mode":"trebleOnly","columns":[[0],[1]]},'
          '{"id":"b","name":"B","mode":"bassOnly","columns":[[-7],[-6]]}'
          ']';
      final scores = parseScoreLibrary(json);
      expect(scores.map((s) => s.scoreId), ['a', 'b']);
      expect(
        () => parseScoreLibrary('[{"id":"x","mode":"grand","columns":[[0]]},'
            '{"id":"y","mode":"bad","columns":[[0]]}]'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('第 2 项'),
        )),
      );
    });
  });

  group('曲目内容约束（11 §4.2 / §5）', () {
    for (final entry in expectedScores.entries) {
      final path = entry.key;
      final mode = entry.value;
      final score = scoreFromJsonString(File(path).readAsStringSync());
      final name = score.title ?? path;

      test('$name：列数与音数', () {
        if (mode == SightMode.grand) {
          expect(score.columnCount, inInclusiveRange(6, 8),
              reason: '$name 双手列数应为 6–8');
          expect(score.noteCountOf(SightVoice.upper), inInclusiveRange(4, 8),
              reason: '$name 上声部音数应为 4–8');
          expect(score.noteCountOf(SightVoice.lower), inInclusiveRange(3, 6),
              reason: '$name 下声部音数应为 3–6');
          expect(score.noteCountOf(SightVoice.upper),
              lessThanOrEqualTo(score.columnCount));
          expect(score.noteCountOf(SightVoice.lower),
              lessThanOrEqualTo(score.columnCount));
        } else {
          expect(score.columnCount, inInclusiveRange(8, 16),
              reason: '$name 单手列数应为 8–16');
          expect(score.noteCount, score.columnCount,
              reason: '$name 单手每个音独占一列');
        }
      });

      test('$name：声部与空列', () {
        for (final col in score.columns) {
          expect(col.isEmpty, isFalse, reason: '$name 存在整列休止（断档）');
        }
        if (mode == SightMode.trebleOnly) {
          expect(score.noteCountOf(SightVoice.lower), 0);
        }
        if (mode == SightMode.bassOnly) {
          expect(score.noteCountOf(SightVoice.upper), 0);
        }
        if (mode == SightMode.grand) {
          final both = score.columns
              .where((c) => c.upper != null && c.lower != null)
              .length;
          final single = score.columns.where((c) => c.upper == null || c.lower == null).length;
          expect(both, greaterThanOrEqualTo(1),
              reason: '$name 至少 1 列双声部');
          expect(single, greaterThanOrEqualTo(1),
              reason: '$name 至少 1 列单声部');
          expect(single, lessThanOrEqualTo((score.columnCount / 2).ceil()),
              reason: '$name 单声部列不应超过一半');
        }
      });

      test('$name：起音间距与结束音', () {
        if (mode == SightMode.grand) {
          final upper = seqOf(score, SightVoice.upper);
          final lower = seqOf(score, SightVoice.lower);
          final gap = upper.first - lower.first;
          expect(gap, inInclusiveRange(8, 12), reason: '$name 起音间距应 8–12');
          expect(isStableEnd(upper.last), isTrue,
              reason: '$name 上声部结束音 ${upper.last} 非 C/F/G');
          expect(isStableEnd(lower.last), isTrue,
              reason: '$name 下声部结束音 ${lower.last} 非 C/F/G');
        } else {
          final voice = mode == SightMode.trebleOnly
              ? SightVoice.upper
              : SightVoice.lower;
          expect(isStableEnd(seqOf(score, voice).last), isTrue,
              reason: '$name 结束音非稳定音级');
        }
      });

      test('$name：步长与级进比例', () {
        for (final voice in SightVoice.values) {
          final seq = seqOf(score, voice);
          if (seq.isEmpty) continue;
          final limit = voice == SightVoice.upper ? 2 : 3;
          expect(maxStep(seq), lessThanOrEqualTo(limit),
              reason: '$name 声部 ${voice.name} 出现超过 $limit 度的跳进');
          expect(progressionRatio(seq), greaterThanOrEqualTo(0.6),
              reason: '$name 声部 ${voice.name} 级进比例不足 60%');
        }
      });
    }
  });
}
