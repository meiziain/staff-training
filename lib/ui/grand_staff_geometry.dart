// 规格: 11 §6.3 —— 大谱表几何计算（纯函数，零 Flutter，可单测）。
//
// 为什么单独一层：加线、上下谱对齐、光标位置是"是否算错"的硬指标，
// 必须能不依赖像素地断言。绘制层（grand_staff_view.dart）只消费本层结果。
//
// 坐标约定与 staff_geometry 一致：bottomLineY 为该谱表底线的 y，
// staffPos 0 = 底线、8 = 顶线，每 +1 上移半个谱线间距。
library;

import 'dart:math' as math;

import '../domain/models/enums.dart';
import '../domain/models/sight_score.dart';
import 'staff_geometry.dart';

/// 视奏谱面最小列宽（11 §6.2：列宽不足时横向滚动，不缩符头）。
const double kMinSightSlotWidth = 30;

/// 双手两谱底线间距（单位：谱线间距）。10 个间距 = 上谱底线到下谱底线，
/// 中间留出上谱下加线（最多 2ss）与下谱上加线（最多 5ss）后仍有空隙。
const double kGrandStaffGapSpaces = 10;

/// 单个符头的几何。
class GrandStaffNoteGeometry {
  final int column;
  final int diatonicIndex;
  final SightVoice voice;
  final double x;
  final double y;

  /// 该符头需要绘制的所有加线 y 坐标（可能为空）。
  final List<double> ledgerYs;

  /// 已答对（渲染淡化）。
  final bool done;

  /// 连错提示中（渲染音名）。
  final bool hinted;

  const GrandStaffNoteGeometry({
    required this.column,
    required this.diatonicIndex,
    required this.voice,
    required this.x,
    required this.y,
    required this.ledgerYs,
    required this.done,
    required this.hinted,
  });

  @override
  String toString() =>
      'Note(c=$column, v=${voice.name}, idx=$diatonicIndex, x=${x.toStringAsFixed(1)}, '
      'y=${y.toStringAsFixed(1)}, ledgers=${ledgerYs.length})';
}

/// 光标框几何。
class GrandStaffCursorGeometry {
  final SightVoice voice;
  final int column;
  final double x;
  final double y;

  const GrandStaffCursorGeometry({
    required this.voice,
    required this.column,
    required this.x,
    required this.y,
  });
}

/// 一条谱线的几何（供测试与绘制共用）。
class GrandStaffLineGeometry {
  final double y;
  final double x1;
  final double x2;

  const GrandStaffLineGeometry(this.y, this.x1, this.x2);
}

/// 整张视奏谱面的几何结果。
class GrandStaffGeometry {
  final double staffSpace;
  final double noteheadDiameter;

  /// 上谱底线 y；单手低音模式为 null。
  final double? bottomLineUpper;

  /// 下谱底线 y；单手高音模式为 null。
  final double? bottomLineLower;

  final double braceTop;
  final double braceBottom;
  final double braceX;

  final double notesLeft;
  final double columnWidth;
  final double contentWidth;
  final double contentHeight;

  final List<GrandStaffLineGeometry> upperLines;
  final List<GrandStaffLineGeometry> lowerLines;
  final List<GrandStaffNoteGeometry> notes;
  final List<GrandStaffCursorGeometry> cursors;

  const GrandStaffGeometry({
    required this.staffSpace,
    required this.noteheadDiameter,
    required this.bottomLineUpper,
    required this.bottomLineLower,
    required this.braceTop,
    required this.braceBottom,
    required this.braceX,
    required this.notesLeft,
    required this.columnWidth,
    required this.contentWidth,
    required this.contentHeight,
    required this.upperLines,
    required this.lowerLines,
    required this.notes,
    required this.cursors,
  });

  /// 列中心 x。
  double columnX(int column) => notesLeft + columnWidth * (column + 0.5);

  /// 某声部某列的音；不存在时返回 null。
  GrandStaffNoteGeometry? noteAt(SightVoice voice, int column) {
    for (final n in notes) {
      if (n.voice == voice && n.column == column) return n;
    }
    return null;
  }

  static GrandStaffGeometry compute({
    required SightMode mode,
    required List<SightColumn> columns,
    required int? upperCursorColumn,
    required int? lowerCursorColumn,
    required Set<int> upperDoneColumns,
    required Set<int> lowerDoneColumns,
    required Set<int> upperHintColumns,
    required Set<int> lowerHintColumns,
    required double availableWidth,
    required double availableHeight,
    required double staffSpace,
    required double noteheadDiameter,
  }) {
    final ss = staffSpace;
    final d = noteheadDiameter;
    final hasUpper = mode.hasUpper;
    final hasLower = mode.hasLower;
    final both = hasUpper && hasLower;

    // ---- 水平：左侧留给大括号 + 谱号，其余均分列宽，不足则横向滚动。
    final leftPad = ss * 0.8;
    final clefWidth = both ? ss * 5.0 : ss * 3.6;
    final rightPad = ss * 0.8;
    final minContent =
        leftPad + clefWidth + columns.length * kMinSightSlotWidth + rightPad;
    final contentWidth = math.max(availableWidth, minContent);
    final notesLeft = leftPad + clefWidth;
    final notesRight = contentWidth - rightPad;
    final columnWidth =
        columns.isEmpty ? 0.0 : (notesRight - notesLeft) / columns.length;

    // ---- 垂直：先求各谱表相对底线的 staffPos 包络（含加线）。
    var maxU = 8, minU = 0, maxL = 8, minL = 0;
    for (final c in columns) {
      final u = c.upper;
      if (u != null && hasUpper) {
        final p = staffPos(u, Clef.treble);
        maxU = math.max(maxU, p);
        minU = math.min(minU, p);
        for (final l in ledgerLinesFor(u, Clef.treble)) {
          maxU = math.max(maxU, l);
          minU = math.min(minU, l);
        }
      }
      final l = c.lower;
      if (l != null && hasLower) {
        final p = staffPos(l, Clef.bass);
        maxL = math.max(maxL, p);
        minL = math.min(minL, p);
        for (final led in ledgerLinesFor(l, Clef.bass)) {
          maxL = math.max(maxL, led);
          minL = math.min(minL, led);
        }
      }
    }

    final pad = d / 2 + ss;
    final gap = both ? kGrandStaffGapSpaces * ss : 0.0;
    final yTop = hasUpper ? -maxU * ss / 2 - pad : gap - maxL * ss / 2 - pad;
    final yBottomUpper = hasUpper ? -minU * ss / 2 + d / 2 : 0.0;
    final yBottom = hasLower ? gap - minL * ss / 2 + pad : yBottomUpper;
    final contentHeight = yBottom - yTop;
    final shift = math.max(0.0, (availableHeight - contentHeight) / 2) - yTop;

    final bottomLineUpper = hasUpper ? shift : null;
    final bottomLineLower = hasLower ? shift + gap : null;

    // ---- 五线。
    List<GrandStaffLineGeometry> lines(double? bottomLineY) {
      if (bottomLineY == null) return const [];
      return [
        for (var p = 0; p <= 8; p += 2)
          GrandStaffLineGeometry(
              bottomLineY - p * ss / 2, notesLeft - ss * 0.2, notesRight + ss * 0.2),
      ];
    }

    // ---- 音符。
    final notes = <GrandStaffNoteGeometry>[];
    for (var i = 0; i < columns.length; i++) {
      final c = columns[i];
      final x = notesLeft + columnWidth * (i + 0.5);
      final u = c.upper;
      if (u != null && bottomLineUpper != null) {
        notes.add(GrandStaffNoteGeometry(
          column: i,
          diatonicIndex: u,
          voice: SightVoice.upper,
          x: x,
          y: noteY(u, Clef.treble, ss, bottomLineUpper),
          ledgerYs: ledgerLineYs(u, Clef.treble, ss, bottomLineUpper),
          done: upperDoneColumns.contains(i),
          hinted: upperHintColumns.contains(i),
        ));
      }
      final l = c.lower;
      if (l != null && bottomLineLower != null) {
        notes.add(GrandStaffNoteGeometry(
          column: i,
          diatonicIndex: l,
          voice: SightVoice.lower,
          x: x,
          y: noteY(l, Clef.bass, ss, bottomLineLower),
          ledgerYs: ledgerLineYs(l, Clef.bass, ss, bottomLineLower),
          done: lowerDoneColumns.contains(i),
          hinted: lowerHintColumns.contains(i),
        ));
      }
    }

    // ---- 光标：只画在"该声部当前待答音"所在列。
    // 列号越界（含 -1 这类"暂无光标"的旧约定）一律当无光标处理，不得抛 RangeError。
    final cursors = <GrandStaffCursorGeometry>[];
    final upperCol = upperCursorColumn;
    if (bottomLineUpper != null &&
        upperCol != null &&
        upperCol >= 0 &&
        upperCol < columns.length) {
      final idx = columns[upperCol].upper;
      if (idx != null) {
        cursors.add(GrandStaffCursorGeometry(
          voice: SightVoice.upper,
          column: upperCol,
          x: notesLeft + columnWidth * (upperCol + 0.5),
          y: noteY(idx, Clef.treble, ss, bottomLineUpper),
        ));
      }
    }
    final lowerCol = lowerCursorColumn;
    if (bottomLineLower != null &&
        lowerCol != null &&
        lowerCol >= 0 &&
        lowerCol < columns.length) {
      final idx = columns[lowerCol].lower;
      if (idx != null) {
        cursors.add(GrandStaffCursorGeometry(
          voice: SightVoice.lower,
          column: lowerCol,
          x: notesLeft + columnWidth * (lowerCol + 0.5),
          y: noteY(idx, Clef.bass, ss, bottomLineLower),
        ));
      }
    }

    return GrandStaffGeometry(
      staffSpace: ss,
      noteheadDiameter: d,
      bottomLineUpper: bottomLineUpper,
      bottomLineLower: bottomLineLower,
      braceTop: bottomLineUpper == null ? 0 : bottomLineUpper - 4 * ss,
      braceBottom: bottomLineLower ?? 0,
      braceX: leftPad + ss * 0.5,
      notesLeft: notesLeft,
      columnWidth: columnWidth,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      upperLines: lines(bottomLineUpper),
      lowerLines: lines(bottomLineLower),
      notes: notes,
      cursors: cursors,
    );
  }
}
