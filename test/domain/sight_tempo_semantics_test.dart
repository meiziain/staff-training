// T07 验收：速度 = 每分钟四分音符数（♩=N），与拍号无关。
//
// 反算口径：一拍 = 4/denominator 个四分音符，
//   ♩ = (60000 / 一拍毫秒数) * (4 / denominator)。
// 注意：spec 文案里写的 (denominator/4) 是倒数，4/8 会反算成 240，属于笔误；
// 这里按音乐定义用 (4/denominator)，并在汇报中说明。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_time_signature.dart';

int quartersFromBeat(int beatMs, int denominator) =>
    (60000 / beatMs * (4 / denominator)).round();

void main() {
  group('速度语义不随拍号变化', () {
    test('♩=60：4/4 一拍 1000ms、4/8 一拍 500ms，反算均为 60', () {
      const fourFour = SightTimeSignature(4, 4);
      const fourEight = SightTimeSignature(4, 8);
      final ms44 = fourFour.beatMsAt(60);
      final ms48 = fourEight.beatMsAt(60);
      expect(ms44, 1000);
      expect(ms48, 500);
      expect(quartersFromBeat(ms44, 4), 60);
      expect(quartersFromBeat(ms48, 8), 60);
    });

    test('♩=80：4/4 一拍 750ms、4/8 一拍 375ms，反算均为 80', () {
      const fourFour = SightTimeSignature(4, 4);
      const fourEight = SightTimeSignature(4, 8);
      final ms44 = fourFour.beatMsAt(80);
      final ms48 = fourEight.beatMsAt(80);
      expect(ms44, 750);
      expect(ms48, 375);
      expect(quartersFromBeat(ms44, 4), 80);
      expect(quartersFromBeat(ms48, 8), 80);
    });

    test('同速度下不同分子的拍号不改动每拍时长', () {
      for (final numerator in [2, 3, 4, 6]) {
        final sig = SightTimeSignature(numerator, 8);
        expect(sig.beatMsAt(96), SightTimeSignature(4, 8).beatMsAt(96));
        expect(quartersFromBeat(sig.beatMsAt(96), 8), 96);
      }
    });
  });
}
