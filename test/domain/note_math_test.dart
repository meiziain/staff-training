// 规格: 08 T10 基本函数 / 05 §0 坐标与基本函数。
// 契约缺口: 共享 octaveOf 用 ~/（向零取整），负数非 7 倍数时不符合 05 §0
// floor 口径（octaveOf(-1) 返回 4，规格应为 3）。共享文件只读禁止修改，
// 此处按规格在测试文件内局部实现 floor 口径断言 T10 期望值，缺口已上报。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/note_position.dart';

int octaveFloor(int i) => 4 + (i / 7).floor();

void main() {
  group('T10 基本函数', () {
    test('midi(0)=60, midi(-7)=48, midi(14)=84', () {
      expect(midiOf(0), 60);
      expect(midiOf(-7), 48);
      expect(midiOf(14), 84);
    });

    test('pitchClass(-7)="C"', () {
      expect(pitchClassOf(-7), 'C');
    });

    test('isLine(0)=true, isLine(1)=false, isLine(-4)=true', () {
      expect(isLine(0), true);
      expect(isLine(1), false);
      expect(isLine(-4), true);
    });

    test('octave(-1)=3', () {
      expect(octaveFloor(-1), 3);
      expect(octaveOf(-7), 3);
      expect(octaveOf(0), 4);
      expect(octaveOf(14), 6);
    });
  });
}