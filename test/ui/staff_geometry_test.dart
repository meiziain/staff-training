// 规格: 06 §4 StaffView / 02 §2.2 §9 / 03 §4.2 —— 几何纯函数单测（dart test）。
// 裁决: 低音第一线按标准记谱取 G2(-10)。任务文本"G3(-3)=第一线"与
// "C4 低音上加一线"、"F3=第四线"及 domain ledgerBass(C4) 矛盾，
// 详见 lib/ui/staff_geometry.dart 头注。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/ui/staff_geometry.dart';

void main() {
  const ss = 10.0;
  const bottom = 100.0;

  group('noteY 基准', () {
    test('高音 E4(2)=第一线', () {
      expect(noteY(2, Clef.treble, ss, bottom), bottom);
    });

    test('高音每 +1 上移半间距', () {
      expect(noteY(3, Clef.treble, ss, bottom), bottom - ss / 2);
      expect(noteY(4, Clef.treble, ss, bottom), bottom - ss);
      expect(noteY(6, Clef.treble, ss, bottom), bottom - 2 * ss);
    });

    test('高音 C4(0)=下加一线位置', () {
      expect(noteY(0, Clef.treble, ss, bottom), bottom + ss);
    });

    test('低音 G2(-10)=第一线（标准记谱裁决）', () {
      expect(noteY(-10, Clef.bass, ss, bottom), bottom);
    });

    test('低音 F3(-4)=第四线（谱号对齐基准）', () {
      expect(noteY(-4, Clef.bass, ss, bottom), bottom - 3 * ss);
    });

    test('低音 C4(0)=上加一线位置', () {
      expect(noteY(0, Clef.bass, ss, bottom), bottom - 5 * ss);
    });
  });

  group('ledgerLinesFor', () {
    test('高音 C4(0) 1 条（下加一线）', () {
      expect(ledgerLinesFor(0, Clef.treble), [-2]);
    });

    test('高音 A5(12) 1 条（上加一线）', () {
      expect(ledgerLinesFor(12, Clef.treble), [10]);
    });

    test('高音 C6(14) 2 条（上加一、二线）', () {
      expect(ledgerLinesFor(14, Clef.treble), [10, 12]);
    });

    test('低音 C4(0) 1 条（上加一线）', () {
      expect(ledgerLinesFor(0, Clef.bass), [10]);
    });

    test('线内音 0 条', () {
      for (final i in [2, 4, 6, 10, 11]) {
        expect(ledgerLinesFor(i, Clef.treble), isEmpty, reason: 'treble $i');
      }
      for (final i in [-7, -3, -1]) {
        expect(ledgerLinesFor(i, Clef.bass), isEmpty, reason: 'bass $i');
      }
    });

    test('紧贴五线边界的间音 0 条（D4 高音 / G5 高音）', () {
      expect(ledgerLinesFor(1, Clef.treble), isEmpty);
      expect(ledgerLinesFor(11, Clef.treble), isEmpty);
    });

    test('五线外间音画相邻线（B5 高音 / B3 高音）', () {
      expect(ledgerLinesFor(13, Clef.treble), [10]);
      expect(ledgerLinesFor(-1, Clef.treble), [-2]);
    });

    test('低音下加线（C3 低音线内 / E2 低音 1 条）', () {
      expect(ledgerLinesFor(-7, Clef.bass), isEmpty);
      expect(ledgerLinesFor(-12, Clef.bass), [-2]);
    });

    test('ledgerLineYs 换算', () {
      expect(ledgerLineYs(14, Clef.treble, ss, bottom),
          [bottom - 5 * ss, bottom - 6 * ss]);
      expect(ledgerLineYs(0, Clef.treble, ss, bottom), [bottom + ss]);
    });
  });

  group('jitterOffset 确定性', () {
    test('同 seed 同 index 同偏移', () {
      final a = jitterOffset(42, 7, ss);
      final b = jitterOffset(42, 7, ss);
      expect(a.dx, b.dx);
      expect(a.dy, b.dy);
    });

    test('不同 seed 不同偏移', () {
      final a = jitterOffset(1, 0, ss);
      final b = jitterOffset(2, 0, ss);
      expect(a.dx == b.dx && a.dy == b.dy, isFalse);
    });

    test('同 seed 不同 index 不同偏移', () {
      final a = jitterOffset(7, 0, ss);
      final b = jitterOffset(7, 1, ss);
      expect(a.dx == b.dx && a.dy == b.dy, isFalse);
    });

    test('幅度：|dx|≤staffSpace，|dy|≤0.5×staffSpace', () {
      for (var seed = 0; seed < 50; seed++) {
        for (var i = -7; i <= 14; i++) {
          final j = jitterOffset(seed, i, ss);
          expect(j.dx.abs(), lessThanOrEqualTo(ss));
          expect(j.dy.abs(), lessThanOrEqualTo(0.5 * ss));
        }
      }
    });
  });

  group('staffMetrics 符头下限', () {
    test('小宽度下符头 ≥12dp', () {
      expect(staffMetrics(80).noteheadDiameter,
          greaterThanOrEqualTo(minNoteheadDiameter));
      expect(staffMetrics(200).noteheadDiameter,
          greaterThanOrEqualTo(minNoteheadDiameter));
    });

    test('宽度不足时间距缩小但符头保底 12', () {
      final m = staffMetrics(100);
      expect(m.staffSpace, lessThan(minNoteheadDiameter));
      expect(m.noteheadDiameter, minNoteheadDiameter);
    });

    test('override 低于 12 被钳制', () {
      expect(staffMetrics(400, noteheadDiameter: 4).noteheadDiameter,
          minNoteheadDiameter);
      expect(staffMetrics(400, noteheadDiameter: 20).noteheadDiameter, 20);
    });

    test('线间距随宽度缩放', () {
      expect(staffMetrics(800).staffSpace,
          greaterThan(staffMetrics(200).staffSpace));
    });
  });
}