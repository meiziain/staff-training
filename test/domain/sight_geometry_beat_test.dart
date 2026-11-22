// T01 验收：拍网格几何（beatCount）与列/谱 JSON 新旧格式往返。
import 'package:test/test.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/sight_score.dart';

void main() {
  group('列 JSON 兼容', () {
    test('2 元素旧格式缺项默认 onset=0 / duration=1', () {
      final c = SightColumn.fromJson([2, -5]);
      expect(c.upper, 2);
      expect(c.lower, -5);
      expect(c.onsetBeat, 0);
      expect(c.durationBeats, 1);
      expect(c.toJson(), [2, -5, 0, 1]);
    });

    test('4 元素新格式完整往返', () {
      final c = SightColumn.fromJson([2, -5, 3, 2]);
      expect(c.onsetBeat, 3);
      expect(c.durationBeats, 2);
      expect(SightColumn.fromJson(c.toJson()), c);
    });

    test('旧 map 缺新键默认，新 map 完整往返', () {
      final old = SightColumn.fromJsonObject({'upper': 2, 'lower': null});
      expect(old.onsetBeat, 0);
      expect(old.durationBeats, 1);

      final fresh = SightColumn(upper: 4, onsetBeat: 6, durationBeats: 3);
      final rebuilt = SightColumn.fromJsonObject(fresh.toJsonObject());
      expect(rebuilt, fresh);
      expect(rebuilt.toJson(), [4, null, 6, 3]);
    });

    test('相等性纳入新字段', () {
      expect(
        const SightColumn(upper: 2, onsetBeat: 1),
        isNot(const SightColumn(upper: 2, onsetBeat: 0)),
      );
      expect(
        const SightColumn(upper: 2, durationBeats: 2),
        isNot(const SightColumn(upper: 2, durationBeats: 1)),
      );
    });
  });

  group('beatCount', () {
    test('1000 组随机列 beatCount == max(onset + duration)', () {
      final r = rng(20261124);
      for (var i = 0; i < 1000; i++) {
        final n = r.randInt(1, 12);
        final columns = List<SightColumn>.generate(n, (_) {
          return SightColumn(
            upper: r.randInt(0, 14),
            onsetBeat: r.randInt(0, 20),
            durationBeats: r.randInt(1, 4),
          );
        });
        final score = SightScore(mode: SightMode.trebleOnly, columns: columns);
        final expected = columns
            .map((c) => c.onsetBeat + c.durationBeats)
            .reduce((a, b) => a > b ? a : b);
        expect(score.beatCount, expected);
      }
    });

    test('空谱为 0；默认列仍为 1 拍', () {
      expect(
        const SightScore(mode: SightMode.grand, columns: []).beatCount,
        0,
      );
      expect(
        SightScore(
          mode: SightMode.trebleOnly,
          columns: const [SightColumn(upper: 0), SightColumn(upper: 1)],
        ).beatCount,
        1,
        reason: 'legacy 列全在 beat 0、各 1 拍',
      );
    });
  });

  group('SightScore 新字段序列化', () {
    test('谱面 JSON map 往返（含 beatsPerBar / chunkRanges / motiveIds）', () {
      final score = SightScore(
        mode: SightMode.grand,
        columns: const [SightColumn(upper: 2, lower: -5, onsetBeat: 0, durationBeats: 2)],
        beatsPerBar: 3,
        chunkRanges: const [SightChunkRange(0, 4)],
        motiveIds: const ['stepUp', 'neighbor'],
      );
      final rebuilt = SightScore.fromJsonObject(
        Map<String, dynamic>.from(score.toJsonObject()),
      );
      expect(rebuilt.mode, SightMode.grand);
      expect(rebuilt.beatsPerBar, 3);
      expect(rebuilt.chunkRanges, [const SightChunkRange(0, 4)]);
      expect(rebuilt.motiveIds, ['stepUp', 'neighbor']);
      expect(rebuilt.columns, score.columns);
      expect(rebuilt.beatCount, 2);
    });

    test('旧谱面 map 缺新键时取默认值', () {
      final rebuilt = SightScore.fromJsonObject({
        'mode': 'trebleOnly',
        'columns': [
          {'upper': 0, 'lower': null},
        ],
      });
      expect(rebuilt.beatsPerBar, 4);
      expect(rebuilt.chunkRanges, isEmpty);
      expect(rebuilt.motiveIds, isNull);
      expect(rebuilt.beatCount, 1);
    });
  });
}
