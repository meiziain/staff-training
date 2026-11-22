// 规格: 11 §6.2 §6.3 —— 视奏谱表（单行 / 大谱表）渲染。
//
// 与 StaffView 的关系：几何口径复用 staff_geometry 的纯函数，但坐标模型不同
// （两行独立 y 轴 + 共用列 x 轴），故独立实现；不做位置抖动（11 §6.3 裁决 6）。
// 所有超出五线的音符必须画加线 —— 由 GrandStaffGeometry.ledgerYs 保证，
// 本层只负责逐条画出，不得自行省略。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../domain/models/enums.dart';
import '../domain/models/note_position.dart';
import '../domain/models/sight_beat_result.dart';
import '../domain/models/sight_score.dart';
import 'grand_staff_geometry.dart';
import 'staff_geometry.dart';
import 'staff_view.dart';

/// 下声部（左手）光标色，与上声部蓝色区分（11 §3.1）。
const Color sightLowerVoiceColor = Color(0xFFE8833A);

/// 已答音（符头与加线）颜色：绿色 + 55% 不透明度（11 §3.3「答对符头变绿」）。
const Color sightDoneNoteColor = Color(0xFF3B8F5A);

/// 四色判定色（T04）：绿=准点、蓝=早、琥珀=晚、红=漏/错。
/// 只改符头/加线颜色，不改谱面几何与其他视觉元素。
const Color sightGradeOnBeatColor = Color(0xFF3B8F5A);
const Color sightGradeEarlyColor = Color(0xFF2F6FED);
const Color sightGradeLateColor = Color(0xFFE8A33A);
const Color sightGradeMissColor = Color(0xFFD64545);

/// 档位到颜色的唯一映射，供完成页色带复用，避免两处色值漂移。
Color sightGradeColor(SightHitGrade grade) => switch (grade) {
      SightHitGrade.onBeat => sightGradeOnBeatColor,
      SightHitGrade.early => sightGradeEarlyColor,
      SightHitGrade.late => sightGradeLateColor,
      SightHitGrade.miss => sightGradeMissColor,
    };

/// 自动跟随滚动的动画时长。
const Duration kSightAutoScrollDuration = Duration(milliseconds: 250);

/// 自动跟随的防抖半径（dp）：目标位移小于它就不动，避免连答时来回抖。
const double kSightAutoScrollDeadZone = 24;

class GrandStaffView extends StatefulWidget {
  const GrandStaffView({
    super.key,
    required this.mode,
    required this.columns,
    this.upperCursorColumn,
    this.lowerCursorColumn,
    this.upperDoneColumns = const {},
    this.lowerDoneColumns = const {},
    this.upperHintColumns = const {},
    this.lowerHintColumns = const {},
    this.noteheadDiameter,
    this.controller,
    this.autoScrollToCursor = true,
    this.autoScrollAlignment = 0.35,
    this.upperGrades,
    this.lowerGrades,
  });

  final SightMode mode;
  final List<SightColumn> columns;
  final int? upperCursorColumn;
  final int? lowerCursorColumn;
  final Set<int> upperDoneColumns;
  final Set<int> lowerDoneColumns;

  /// 连错提示：这些列的符头上方显示音名（11 §3.3）。
  final Set<int> upperHintColumns;
  final Set<int> lowerHintColumns;

  final double? noteheadDiameter;
  final ScrollController? controller;

  /// 光标变化后是否自动把谱面滚到光标处（「弹一个音，谱跟着走」）。
  final bool autoScrollToCursor;

  /// 光标停在视口宽度的哪个比例处（0.35 = 左侧 35%，右侧留出更多待答音）。
  final double autoScrollAlignment;

  /// 已结算音的四色判定（key=列号）。null 时完全沿用原有「已答淡化」逻辑。
  final Map<int, SightHitGrade>? upperGrades;
  final Map<int, SightHitGrade>? lowerGrades;

  /// 单手最坏高度约 11 个谱线间距（含上下加线 + 留白）。
  static const double _singleHeightSpaces = 12;

  /// 双手最坏高度约 23 个间距（两谱各 4 + 间隔 10 + 上下加线 + 留白）。
  static const double _grandHeightSpaces = 23;

  @override
  State<GrandStaffView> createState() => _GrandStaffViewState();
}

class _GrandStaffViewState extends State<GrandStaffView> {
  /// 内容宽度超出视口多少才算"需要滚动"（亚像素误差不计）。
  static const double _overflowEpsilon = 0.5;

  /// 外部没传 controller 时自建一个（dispose 时只销毁自建的这个）。
  ScrollController? _ownedController;

  /// 最近一帧的几何与视口宽度：滚动目标按它们换算。
  GrandStaffGeometry? _geometry;
  double _viewportWidth = 0;

  /// 上次已处理的光标列；同一列不重复触发，避免连续重建时反复起动画。
  int? _handledColumn;

  /// 是否已做过进场对齐（首次直接跳到位，不做动画）。
  bool _initialAligned = false;

  ScrollController get _scrollController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void didUpdateWidget(covariant GrandStaffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换谱例（列数组换新）后光标列可能"看起来没变"，必须重新对齐。
    if (!identical(oldWidget.columns, widget.columns)) _handledColumn = null;
  }

  @override
  void dispose() {
    // 只销毁自建的；外部传入的 controller 归调用方管。
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;
    return LayoutBuilder(builder: (context, constraints) {
      final availW =
          constraints.hasBoundedWidth ? constraints.maxWidth : 360.0;
      final availH =
          constraints.hasBoundedHeight ? constraints.maxHeight : 260.0;
      final base =
          staffMetrics(availW, noteheadDiameter: widget.noteheadDiameter);
      // 高度也是硬约束：谱线间距过大会把加线挤出画布。
      final cap = availH /
          (mode == SightMode.grand
              ? GrandStaffView._grandHeightSpaces
              : GrandStaffView._singleHeightSpaces);
      final ss = math.min(base.staffSpace, cap).clamp(6.0, 14.0).toDouble();
      final d = (widget.noteheadDiameter ?? ss)
          .clamp(minNoteheadDiameter, double.infinity)
          .toDouble();
      final g = GrandStaffGeometry.compute(
        mode: mode,
        columns: widget.columns,
        upperCursorColumn: widget.upperCursorColumn,
        lowerCursorColumn: widget.lowerCursorColumn,
        upperDoneColumns: widget.upperDoneColumns,
        lowerDoneColumns: widget.lowerDoneColumns,
        upperHintColumns: widget.upperHintColumns,
        lowerHintColumns: widget.lowerHintColumns,
        availableWidth: availW,
        availableHeight: availH,
        staffSpace: ss,
        noteheadDiameter: d,
      );
      _geometry = g;
      _viewportWidth = availW;
      _scheduleAutoScroll();
      return ColoredBox(
        color: StaffView.paperColor,
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: g.contentWidth,
            height: availH,
            child: CustomPaint(
              painter: GrandStaffPainter(
                geometry: g,
                mode: mode,
                upperGrades: widget.upperGrades,
                lowerGrades: widget.lowerGrades,
              ),
            ),
          ),
        ),
      );
    });
  }

  // --------------------------------------------------------- 自动跟随滚动

  /// 光标列变化且谱面确实溢出时，安排一帧后把光标滚到 [GrandStaffView.autoScrollAlignment]。
  ///
  /// 放在 build 里是因为目标偏移依赖本帧几何（列中心 x、内容宽）；
  /// 真正的滚动放 post-frame，那时 ScrollPosition 已随布局就绪。
  void _scheduleAutoScroll() {
    if (!widget.autoScrollToCursor) return;
    final g = _geometry;
    if (g == null || _viewportWidth <= 0) return;
    // 谱面塞得下就不滚：短谱例 offset 恒为 0。
    if (g.contentWidth <= _viewportWidth + _overflowEpsilon) return;
    final column = _rightmostPendingCursorColumn();
    if (column == null || column == _handledColumn) return;
    _handledColumn = column;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCursor(column));
  }

  /// 最靠右的待答光标列（双手时取上/下光标中更靠右的一个）。
  int? _rightmostPendingCursorColumn() {
    final count = widget.columns.length;
    final upper = widget.upperCursorColumn;
    final lower = widget.lowerCursorColumn;
    final columns = <int>[
      if (upper != null && upper >= 0 && upper < count) upper,
      if (lower != null && lower >= 0 && lower < count) lower,
    ];
    if (columns.isEmpty) return null;
    return columns.reduce(math.max);
  }

  void _scrollToCursor(int column) {
    if (!mounted) return;
    final g = _geometry;
    final controller = _scrollController;
    // 未挂载（本帧还没布局）时 position 不存在，放弃本次；等下一次重建再看。
    if (g == null || !controller.hasClients) {
      _handledColumn = null;
      return;
    }
    final position = controller.position;
    // 目标：列中心落在视口 35% 处；越界由 ScrollPosition 的区间 clamp。
    final target = (g.columnX(column) - _viewportWidth * widget.autoScrollAlignment)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    // 已经在目标附近：不动，避免连续作答时来回抖。
    if ((position.pixels - target).abs() <= kSightAutoScrollDeadZone) return;
    if (!_initialAligned) {
      // 进场直接定位：长谱例从当前光标开始，而不是从第一列滑过来。
      _initialAligned = true;
      controller.jumpTo(target);
      return;
    }
    controller.animateTo(
      target,
      duration: kSightAutoScrollDuration,
      curve: Curves.easeOut,
    );
  }
}

class GrandStaffPainter extends CustomPainter {
  GrandStaffPainter({
    required this.geometry,
    required this.mode,
    this.upperGrades,
    this.lowerGrades,
  });

  final GrandStaffGeometry geometry;
  final SightMode mode;
  final Map<int, SightHitGrade>? upperGrades;
  final Map<int, SightHitGrade>? lowerGrades;

  static const double _headWidthRatio = 1.35;
  static const double _headTiltRad = -20 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final ss = g.staffSpace;
    final ink = Paint()
      ..color = StaffView.inkColor
      ..strokeWidth = math.max(1.0, ss * 0.1);

    for (final line in g.upperLines) {
      canvas.drawLine(Offset(line.x1, line.y), Offset(line.x2, line.y), ink);
    }
    for (final line in g.lowerLines) {
      canvas.drawLine(Offset(line.x1, line.y), Offset(line.x2, line.y), ink);
    }

    if (mode == SightMode.grand &&
        g.bottomLineUpper != null &&
        g.bottomLineLower != null) {
      _paintBrace(canvas, g);
    }

    final clefX = mode == SightMode.grand
        ? g.braceX + ss * 1.0
        : g.notesLeft - ss * 3.3;
    if (g.bottomLineUpper != null) {
      _paintClef(canvas, Clef.treble, g.bottomLineUpper!, ss, clefX);
    }
    if (g.bottomLineLower != null) {
      _paintClef(canvas, Clef.bass, g.bottomLineLower!, ss, clefX);
    }

    for (final n in g.notes) {
      _paintNote(canvas, g, n);
    }
    for (final c in g.cursors) {
      _paintCursor(canvas, g, c);
    }
  }

  void _paintBrace(Canvas canvas, GrandStaffGeometry g) {
    final ss = g.staffSpace;
    final top = g.braceTop;
    final bottom = g.braceBottom;
    final mid = (top + bottom) / 2;
    final x = g.braceX;
    final w = ss * 0.75;
    final path = Path()
      ..moveTo(x + w, top)
      ..cubicTo(x - w * 0.1, top + ss * 0.4, x - w * 0.1, mid - ss * 0.5,
          x - w * 0.9, mid)
      ..cubicTo(x - w * 0.1, mid + ss * 0.5, x - w * 0.1, bottom - ss * 0.4,
          x + w, bottom);
    canvas.drawPath(
      path,
      Paint()
        ..color = StaffView.inkColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintClef(
      Canvas canvas, Clef clef, double bottomLineY, double ss, double x) {
    final glyph = clef == Clef.treble ? 0xE050 : 0xE062;
    // SMuFL 字形原点在基线：高音对准 G4 线（pos 2），低音对准 F3 线（pos 6）。
    final refPos = clef == Clef.treble ? 2 : 6;
    final lineY = bottomLineY - refPos * ss / 2;
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(glyph),
        style: TextStyle(
          fontFamily: 'Bravura',
          fontSize: 4 * ss,
          color: StaffView.inkColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline =
        tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    tp.paint(canvas, Offset(x, lineY - baseline));
  }

  void _paintNote(
      Canvas canvas, GrandStaffGeometry g, GrandStaffNoteGeometry n) {
    final ss = g.staffSpace;
    final d = g.noteheadDiameter;
    // 四色优先：本列有结算 grade 就用四色；否则沿用原「已答淡化」逻辑。
    final grades = n.voice == SightVoice.upper ? upperGrades : lowerGrades;
    final grade = grades == null ? null : grades[n.column];
    final color = grade != null
        ? sightGradeColor(grade)
        : (n.done
            ? sightDoneNoteColor.withValues(alpha: 0.55)
            : StaffView.inkColor);
    final ledgerPaint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.0, ss * 0.1);
    final halfW = d * _headWidthRatio / 2 + ss * 0.35;
    // 加线：geometry 给出几条就画几条，禁止在绘制层做任何删减。
    for (final ly in n.ledgerYs) {
      canvas.drawLine(
          Offset(n.x - halfW, ly), Offset(n.x + halfW, ly), ledgerPaint);
    }
    canvas.save();
    canvas.translate(n.x, n.y);
    canvas.rotate(_headTiltRad);
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset.zero, width: d * _headWidthRatio, height: d),
      Paint()..color = color,
    );
    canvas.restore();

    if (n.hinted) {
      _paintLabel(
        canvas,
        NotePosition.of(n.diatonicIndex).displayName,
        n.x,
        n.y - d / 2 - ss * 0.6,
        n.voice == SightVoice.upper
            ? StaffView.accentColor
            : sightLowerVoiceColor,
      );
    }
  }

  void _paintCursor(
      Canvas canvas, GrandStaffGeometry g, GrandStaffCursorGeometry c) {
    final ss = g.staffSpace;
    final d = g.noteheadDiameter;
    final color =
        c.voice == SightVoice.upper ? StaffView.accentColor : sightLowerVoiceColor;
    final rect = Rect.fromCenter(
      center: Offset(c.x, c.y),
      width: d * _headWidthRatio + ss * 0.95,
      height: d + ss * 0.95,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _paintLabel(
      Canvas canvas, String label, double x, double bottomY, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: geometry.staffSpace * 1.25,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, bottomY - tp.height));
  }

  @override
  bool shouldRepaint(covariant GrandStaffPainter oldDelegate) => true;
}
