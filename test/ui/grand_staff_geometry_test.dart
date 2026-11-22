// 规格: 11 §6.2 §6.3 —— 视奏大谱表几何单测（纯 Dart，零 Flutter 依赖）。
//
// 加线（§6.3 硬性要求）：五线外的每个线位置都必须画，间音只画到相邻线，
// 一条不能少、也不能多。这里直接对 GrandStaffGeometry.compute 的输
// 出断言，不依赖像素。
//
// 坐标口径以 staff_geometry 为准：y = bottomLineY - staffPos * ss / 2，
// 加线位置为偶数 staffPos（-2 = 下加一线，10 = 上加一线）。
library;

import 'package:test/test.dart';

import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/ui/grand_staff_geometry.dart';
import 'package:sight_reading/ui/staff_geometry.dart';

const double _ss = 10;
const double _head = 12;
const double _eps = 0.01;

/// compute 的薄包装，只暴露各用例关心的参数。
GrandStaffGeometry _geom({
  required SightMode mode,
  required List<SightColumn> columns,
  int? upperCursor,
  int? lowerCursor,
  Set<int> upperDone = const {},
  Set<int> lowerDone = const {},
  Set<int> upperHints = const {},
  Set<int> lowerHints = const {},
  double width = 360,
  double height = 300,
  double staffSpace = _ss,
  double notehead = _head,
}) {
  return GrandStaffGeometry.compute(
    mode: mode,
    columns: columns,
    upperCursorColumn: upperCursor,
    lowerCursorColumn: lowerCursor,
    upperDoneColumns: upperDone,
    lowerDoneColumns: lowerDone,
    upperHintColumns: upperHints,
    lowerHintColumns: lowerHints,
    availableWidth: width,
    availableHeight: height,
    staffSpace: staffSpace,
    noteheadDiameter: notehead,
  );
}

GrandStaffNoteGeometry _only(GrandStaffGeometry g) => g.notes.single;

void main() {
  group('前提：staffPos 与规格表一致', () {
    test('高音 C4=-2 / A5=10 / C6=12 / E4=0', () {
      expect(staffPos(0, Clef.treble), -2);
      expect(staffPos(12, Clef.treble), 10);
      expect(staffPos(14, Clef.treble), 12);
      expect(staffPos(2, Clef.treble), 0);
    });

    test('低音 C2=-4 / C4=10 / B3=9', () {
      expect(staffPos(-14, Clef.bass), -4);
      expect(staffPos(0, Clef.bass), 10);
      expect(staffPos(-1, Clef.bass), 9);
    });
  });

  group('加线数量（§6.3 硬指标）', () {
    final cases = <({
      String name,
      SightMode mode,
      SightColumn column,
      SightVoice voice,
      int ledgers,
    })>[
      (
        name: '高音 C4(0) 下加一线',
        mode: SightMode.trebleOnly,
        column: const SightColumn(upper: 0),
        voice: SightVoice.upper,
        ledgers: 1,
      ),
      (
        name: '高音 A5(12) 上加一线',
        mode: SightMode.trebleOnly,
        column: const SightColumn(upper: 12),
        voice: SightVoice.upper,
        ledgers: 1,
      ),
      (
        name: '高音 C6(14) 上加一、二线',
        mode: SightMode.trebleOnly,
        column: const SightColumn(upper: 14),
        voice: SightVoice.upper,
        ledgers: 2,
      ),
      (
        name: '低音 C2(-14) 下加一、二线',
        mode: SightMode.bassOnly,
        column: const SightColumn(lower: -14),
        voice: SightVoice.lower,
        ledgers: 2,
      ),
      (
        name: '低音 C4(0) 上加一线',
        mode: SightMode.bassOnly,
        column: const SightColumn(lower: 0),
        voice: SightVoice.lower,
        ledgers: 1,
      ),
      (
        name: '低音 B3(-1) 五线外间音，不得多画',
        mode: SightMode.bassOnly,
        column: const SightColumn(lower: -1),
        voice: SightVoice.lower,
        ledgers: 0,
      ),
      (
        name: '高音 E4(2) 底线，无需加线',
        mode: SightMode.trebleOnly,
        column: const SightColumn(upper: 2),
        voice: SightVoice.upper,
        ledgers: 0,
      ),
    ];

    for (final c in cases) {
      test(c.name, () {
        final g = _geom(mode: c.mode, columns: [c.column]);
        final n = _only(g);
        expect(n.voice, c.voice);
        expect(n.column, 0);
        expect(n.ledgerYs.length, c.ledgers);
      });
    }

    test('加线音同时出现在双手谱时数量不变', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [
          SightColumn(upper: 14, lower: -14),
          SightColumn(upper: 0, lower: 0),
        ],
      );
      expect(g.noteAt(SightVoice.upper, 0)!.ledgerYs.length, 2); // C6
      expect(g.noteAt(SightVoice.lower, 0)!.ledgerYs.length, 2); // C2
      expect(g.noteAt(SightVoice.upper, 1)!.ledgerYs.length, 1); // C4
      expect(g.noteAt(SightVoice.lower, 1)!.ledgerYs.length, 1); // C4
    });
  });

  group('加线 y 坐标正确', () {
    test('高音 C6 两条 = 底线 -5ss / -6ss', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 14)],
      );
      final bottom = g.bottomLineUpper!;
      final n = _only(g);
      // 底线是上谱 staffPos 0 的 y；C6 位于 +12 半间距 = 上方 6 个间距。
      expect(n.y, closeTo(bottom - 6 * _ss, _eps));
      expect(n.ledgerYs.length, 2);
      expect(n.ledgerYs[0], closeTo(bottom - 5 * _ss, _eps)); // 上加一线 pos=10
      expect(n.ledgerYs[1], closeTo(bottom - 6 * _ss, _eps)); // 上加二线 pos=12
    });

    test('低音 C2 两条 = 底线 +1ss / +2ss', () {
      // 注意：任务书写的「+2ss / +3ss」与其自身括注「staffPos -2 → +1ss，
      // -4 → +2ss」矛盾。以 staffPos * ss / 2 为准（与 staff_geometry 一致）：
      // C2 下落 4 个半间距 = 2 个间距，加线在 pos -2 与 -4。
      final g = _geom(
        mode: SightMode.bassOnly,
        columns: const [SightColumn(lower: -14)],
      );
      final bottom = g.bottomLineLower!;
      final n = _only(g);
      expect(staffPos(-14, Clef.bass), -4);
      expect(n.y, closeTo(bottom + 2 * _ss, _eps));
      expect(n.ledgerYs.length, 2);
      expect(n.ledgerYs[0], closeTo(bottom + 1 * _ss, _eps)); // 下加一线 pos=-2
      expect(n.ledgerYs[1], closeTo(bottom + 2 * _ss, _eps)); // 下加二线 pos=-4
    });

    test('加线互相平行且等距 ss', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [
          SightColumn(upper: 14, lower: -14),
        ],
      );
      final u = g.noteAt(SightVoice.upper, 0)!;
      final l = g.noteAt(SightVoice.lower, 0)!;
      expect((u.ledgerYs[1] - u.ledgerYs[0]).abs(), closeTo(_ss, _eps));
      expect((l.ledgerYs[1] - l.ledgerYs[0]).abs(), closeTo(_ss, _eps));
    });
  });

  group('上下声部列对齐', () {
    test('同一列上下两音 x 完全相等，且等于列中心', () {
      const columns = [
        SightColumn(upper: 4, lower: -4),
        SightColumn(upper: 7, lower: -7),
        SightColumn(upper: 9), // 该列下声部休止
      ];
      final g = _geom(mode: SightMode.grand, columns: columns);
      for (var i = 0; i < 2; i++) {
        final u = g.noteAt(SightVoice.upper, i)!;
        final l = g.noteAt(SightVoice.lower, i)!;
        expect(u.x, l.x, reason: '列 $i 上下音 x 必须相同');
        expect(u.x, g.columnX(i));
      }
      expect(g.noteAt(SightVoice.lower, 2), isNull);
    });

    test('列 x 单调递增且列距等于 columnWidth', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [
          SightColumn(upper: 2, lower: -10),
          SightColumn(upper: 4, lower: -8),
          SightColumn(upper: 6, lower: -6),
        ],
      );
      final xs = [for (var i = 0; i < 3; i++) g.columnX(i)];
      expect(xs[1] - xs[0], closeTo(g.columnWidth, _eps));
      expect(xs[2] - xs[1], closeTo(g.columnWidth, _eps));
    });
  });

  group('光标', () {
    test('每个声部只产生一个光标，且落在该列音符上', () {
      const columns = [
        SightColumn(upper: 4, lower: -4),
        SightColumn(upper: 7, lower: -7),
      ];
      final g = _geom(
        mode: SightMode.grand,
        columns: columns,
        upperCursor: 1,
        lowerCursor: 0,
      );
      final uppers = g.cursors.where((c) => c.voice == SightVoice.upper);
      final lowers = g.cursors.where((c) => c.voice == SightVoice.lower);
      expect(uppers.length, 1);
      expect(lowers.length, 1);

      final up = uppers.single;
      final upNote = g.noteAt(SightVoice.upper, 1)!;
      expect(up.column, 1);
      expect(up.x, upNote.x);
      expect(up.y, closeTo(upNote.y, _eps));

      final lo = lowers.single;
      final loNote = g.noteAt(SightVoice.lower, 0)!;
      expect(lo.column, 0);
      expect(lo.x, loNote.x);
      expect(lo.y, closeTo(loNote.y, _eps));
    });

    test('光标 y 随音高上移（加线音也对齐符头）', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 14)],
        upperCursor: 0,
      );
      final c = g.cursors.single;
      expect(c.y, closeTo(g.bottomLineUpper! - 6 * _ss, _eps));
    });

    test('该列无声部音符时不画光标（不越界）', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [SightColumn(upper: 4)],
        lowerCursor: 0,
      );
      expect(g.cursors.where((c) => c.voice == SightVoice.lower), isEmpty);
      expect(g.cursors.length, 0);
    });

    test('光标列超出列数时不崩、不画', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 4)],
        upperCursor: 9,
      );
      expect(g.cursors, isEmpty);
    });

    test('负光标列属于非法输入：按无光标处理，不崩', () {
      // 修复前 compute 直接 columns[-1]，抛 RangeError 打断整张谱面。
      final g = _geom(
        mode: SightMode.grand,
        columns: const [SightColumn(upper: 4, lower: -4)],
        upperCursor: -1,
        lowerCursor: -1,
      );
      expect(g.cursors, isEmpty);
    });

    test('单手模式只出一个声部光标', () {
      final g = _geom(
        mode: SightMode.bassOnly,
        columns: const [SightColumn(lower: -4)],
        lowerCursor: 0,
      );
      expect(g.cursors.length, 1);
      expect(g.cursors.single.voice, SightVoice.lower);
    });
  });

  group('单手模式不画另一行', () {
    test('高音单手：无下谱、无大括号下半', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 4), SightColumn(upper: 7)],
      );
      expect(g.bottomLineUpper, isNotNull);
      expect(g.bottomLineLower, isNull);
      expect(g.lowerLines, isEmpty);
      expect(g.upperLines.length, 5);
      expect(g.braceBottom, 0);
    });

    test('低音单手：无上谱', () {
      final g = _geom(
        mode: SightMode.bassOnly,
        columns: const [SightColumn(lower: -4), SightColumn(lower: -7)],
      );
      expect(g.bottomLineUpper, isNull);
      expect(g.upperLines, isEmpty);
      expect(g.lowerLines.length, 5);
      expect(g.bottomLineLower, isNotNull);
    });

    test('双手：两行各五线，大括号覆盖两谱', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [SightColumn(upper: 4, lower: -4)],
      );
      expect(g.upperLines.length, 5);
      expect(g.lowerLines.length, 5);
      expect(g.braceTop, closeTo(g.bottomLineUpper! - 4 * _ss, _eps));
      expect(g.braceBottom, closeTo(g.bottomLineLower!, _eps));
      expect(g.braceTop, lessThan(g.braceBottom));
    });

    test('单手模式下另一声部的音不产生符头', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 4, lower: -4)],
      );
      expect(g.notes.length, 1);
      expect(g.notes.single.voice, SightVoice.upper);
    });
  });

  group('横向滚动阈值', () {
    test('16 列 × 320 宽：内容超宽，需要横向滚动', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: List.filled(16, const SightColumn(upper: 4, lower: -4)),
        width: 320,
      );
      expect(g.contentWidth, greaterThan(320));
      expect(g.columnWidth, greaterThanOrEqualTo(kMinSightSlotWidth - _eps));
      // 滚动后每列仍不小于最小列宽，符头不缩。
      expect(g.columnWidth, closeTo(kMinSightSlotWidth, _eps));
    });

    test('8 列 × 360 宽：不滚动，内容宽度等于可用宽度', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: List.filled(8, const SightColumn(upper: 4, lower: -4)),
        width: 360,
      );
      expect(g.contentWidth, 360);
      expect(g.columnWidth, greaterThan(kMinSightSlotWidth));
    });

    test('列宽足够时无最小宽余量强制扩展', () {
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: List.filled(6, const SightColumn(upper: 4)),
        width: 360,
      );
      expect(g.contentWidth, 360);
    });
  });

  group('极端音域不裁剪', () {
    test('C2 + C6 同谱：内容高度装得下且各元素留在画布内', () {
      const h = 300.0;
      final g = _geom(
        mode: SightMode.grand,
        columns: const [
          SightColumn(upper: 14, lower: -14), // C6 / C2
          SightColumn(upper: 0, lower: 0), // C4 / C4
        ],
        height: h,
      );
      expect(g.contentHeight, lessThanOrEqualTo(h));

      void inCanvas(double y, String what) {
        expect(y, greaterThanOrEqualTo(0), reason: '$what 超出上边界');
        expect(y, lessThanOrEqualTo(h), reason: '$what 超出下边界');
      }

      for (final n in g.notes) {
        inCanvas(n.y, 'note ${n.diatonicIndex}');
        for (final ly in n.ledgerYs) {
          inCanvas(ly, 'ledger of ${n.diatonicIndex}');
        }
      }
      for (final l in [...g.upperLines, ...g.lowerLines]) {
        inCanvas(l.y, 'staff line');
      }
    });

    test('单手 C4 + C6：加线不出画布', () {
      const h = 200.0;
      final g = _geom(
        mode: SightMode.trebleOnly,
        columns: const [SightColumn(upper: 0), SightColumn(upper: 14)],
        height: h,
      );
      expect(g.contentHeight, lessThanOrEqualTo(h));
      for (final n in g.notes) {
        expect(n.y, inInclusiveRange(0, h));
        for (final ly in n.ledgerYs) {
          expect(ly, inInclusiveRange(0, h));
        }
      }
    });

    test('低音 C2 单手：上加线到符头之间不留缺口', () {
      final g = _geom(
        mode: SightMode.bassOnly,
        columns: const [SightColumn(lower: -14)],
      );
      final n = _only(g);
      // 五线外每一条线都画：-2 与 -4，两条互不重合。
      expect(n.ledgerYs.toSet().length, 2);
      expect(n.ledgerYs.first, lessThan(n.ledgerYs.last));
    });
  });

  group('已答 / 提示标记透传', () {
    test('done 与 hinted 按列归属到正确声部', () {
      final g = _geom(
        mode: SightMode.grand,
        columns: const [
          SightColumn(upper: 4, lower: -4),
          SightColumn(upper: 7, lower: -7),
        ],
        upperDone: {0},
        lowerHints: {1},
      );
      final u0 = g.noteAt(SightVoice.upper, 0)!;
      final l0 = g.noteAt(SightVoice.lower, 0)!;
      final l1 = g.noteAt(SightVoice.lower, 1)!;
      expect(u0.done, isTrue);
      expect(u0.hinted, isFalse);
      expect(l0.done, isFalse);
      expect(l0.hinted, isFalse);
      expect(l1.hinted, isTrue);
      expect(l1.done, isFalse);
    });
  });
}
