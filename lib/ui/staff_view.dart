// 规格: 06 §4 StaffView 行 / 02 §2.2 §9 / 03 §4.2 —— 谱表纯渲染组件。
// 五线/符头/加线自绘；谱号用 Bravura SMuFL 字形（高音 U+E050 / 低音 U+E062）。
// 固定浅底（纸面隐喻），深色模式下不变暗。
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../domain/models/enums.dart';
import 'staff_geometry.dart';

/// 锚点常亮 + 音名标注（06 §2 S3 关系推导/锚点重建立）。
class StaffAnchorOverlay {
  final int index;
  final String label;

  /// 直认前置参照（02 §4.2）：空心灰描边，刻意区别于关系题/重建立的常亮锚点。
  final bool ghost;

  const StaffAnchorOverlay({
    required this.index,
    required this.label,
    this.ghost = false,
  });
}

class StaffView extends StatelessWidget {
  const StaffView({
    super.key,
    required this.clef,
    required this.positions,
    required this.jitterSeed,
    this.highlightIndex,
    this.anchorOverlay,
    this.noteheadDiameter,
  });

  final Clef clef;

  /// diatonicIndex 列表，按序等距横排；单音居中。
  final List<int> positions;

  /// 确定性抖动种子（02 §2.2）。
  final int jitterSeed;

  /// 当前作答音在 positions 中的下标（06 §2 S3 短句高亮框）。
  final int? highlightIndex;

  final StaffAnchorOverlay? anchorOverlay;

  /// 符头直径覆盖值（仍受 ≥12dp 下限约束）。
  final double? noteheadDiameter;

  /// 固定浅底（06 §2 S3：深色模式下也浅底）。
  static const Color paperColor = Color(0xFFFAFAF8);
  static const Color inkColor = Color(0xFF3C3C3C);
  static const Color accentColor = Color(0xFF2F6FED);

  /// 前置参照锚点：灰色空心，表示"这不是本题的作答对象"。
  static const Color ghostColor = Color(0xFF9B9B96);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.hasBoundedWidth ? constraints.maxWidth : 320.0;
        final height =
            constraints.hasBoundedHeight ? constraints.maxHeight : 240.0;
        final metrics =
            staffMetrics(width, noteheadDiameter: noteheadDiameter);
        return ColoredBox(
          color: paperColor,
          child: SizedBox(
            width: width,
            height: height,
            child: CustomPaint(
              painter: StaffPainter(
                clef: clef,
                positions: positions,
                jitterSeed: jitterSeed,
                staffSpace: metrics.staffSpace,
                noteheadDiameter: metrics.noteheadDiameter,
                highlightIndex: highlightIndex,
                anchorOverlay: anchorOverlay,
              ),
            ),
          ),
        );
      },
    );
  }
}

class StaffPainter extends CustomPainter {
  StaffPainter({
    required this.clef,
    required this.positions,
    required this.jitterSeed,
    required this.staffSpace,
    required this.noteheadDiameter,
    this.highlightIndex,
    this.anchorOverlay,
  });

  final Clef clef;
  final List<int> positions;
  final int jitterSeed;
  final double staffSpace;
  final double noteheadDiameter;
  final int? highlightIndex;
  final StaffAnchorOverlay? anchorOverlay;

  /// 符头宽高比与倾角：标准记谱的斜椭圆（大约 1.3–1.4 : 1，逆时针约 20°）。
  static const double _headWidthRatio = 1.35;
  static const double _headTiltRad = -20 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final ss = staffSpace;
    final d = noteheadDiameter;
    final anchor = anchorOverlay;

    var maxPos = 8;
    var minPos = 0;
    for (final i in [if (anchor != null) anchor.index, ...positions]) {
      final p = staffPos(i, clef);
      maxPos = math.max(maxPos, p);
      minPos = math.min(minPos, p);
      for (final l in ledgerLinesFor(i, clef)) {
        maxPos = math.max(maxPos, l);
        minPos = math.min(minPos, l);
      }
    }

    final topPad = d / 2 + ss;
    final bottomPad = d / 2 + ss + (anchor != null ? ss * 1.8 : 0);
    final contentH = (maxPos - minPos) * ss / 2 + topPad + bottomPad;
    final offsetY = math.max(0.0, (size.height - contentH) / 2);
    final bottomLineY = offsetY + topPad + maxPos * ss / 2;

    final left = ss * 0.8;
    final right = size.width - ss * 0.8;
    final linePaint = Paint()
      ..color = StaffView.inkColor
      ..strokeWidth = math.max(1.0, ss * 0.1);

    for (var p = 0; p <= 8; p += 2) {
      final y = bottomLineY - p * ss / 2;
      canvas.drawLine(Offset(left, y), Offset(right, y), linePaint);
    }

    _paintClef(canvas, bottomLineY, left);

    final notesLeft = left + ss * 4.2;
    final notesRight = right - ss * 0.5;
    final totalSlots = positions.length + (anchor != null ? 1 : 0);
    if (totalSlots == 0 || notesRight <= notesLeft) return;
    final slotW = (notesRight - notesLeft) / totalSlots;
    double slotX(int slot) => notesLeft + slotW * (slot + 0.5);

    var slot = 0;
    if (anchor != null) {
      final x = slotX(slot);
      final y = noteY(anchor.index, clef, ss, bottomLineY);
      final color = anchor.ghost ? StaffView.ghostColor : StaffView.accentColor;
      _paintLedgers(canvas, anchor.index, x, y, bottomLineY, linePaint);
      _paintHead(canvas, x, y, color, hollow: anchor.ghost);
      _paintLabel(canvas, anchor.label, x, y + d / 2 + ss * 0.5, color);
      slot++;
    }

    for (var i = 0; i < positions.length; i++) {
      final index = positions[i];
      final j = jitterOffset(jitterSeed, index, ss);
      final x = slotX(slot + i) + j.dx;
      final y = noteY(index, clef, ss, bottomLineY) + j.dy;
      _paintLedgers(canvas, index, x, y, bottomLineY, linePaint);
      _paintHead(canvas, x, y, StaffView.inkColor);
      if (highlightIndex == i) {
        final rect = Rect.fromCenter(
          center: Offset(x, y),
          width: d * _headWidthRatio + ss * 0.9,
          height: d + ss * 0.9,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()
            ..color = StaffView.accentColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  void _paintClef(Canvas canvas, double bottomLineY, double left) {
    final ss = staffSpace;
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
    tp.paint(canvas, Offset(left + ss * 0.3, lineY - baseline));
  }

  void _paintLedgers(Canvas canvas, int index, double x, double y,
      double bottomLineY, Paint linePaint) {
    final ss = staffSpace;
    final halfW = noteheadDiameter * _headWidthRatio / 2 + ss * 0.35;
    final dy = y - noteY(index, clef, ss, bottomLineY);
    for (final ly in ledgerLineYs(index, clef, ss, bottomLineY)) {
      canvas.drawLine(
        Offset(x - halfW, ly + dy),
        Offset(x + halfW, ly + dy),
        linePaint,
      );
    }
  }

  void _paintHead(Canvas canvas, double x, double y, Color color,
      {bool hollow = false}) {
    final d = noteheadDiameter;
    final rect = Rect.fromCenter(
        center: Offset.zero, width: d * _headWidthRatio, height: d);
    final paint = Paint()..color = color;
    if (hollow) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, d * 0.14);
    }
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(_headTiltRad);
    canvas.drawOval(rect, paint);
    canvas.restore();
  }

  void _paintLabel(Canvas canvas, String label, double x, double topY,
      Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: staffSpace * 1.2,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, topY));
  }

  @override
  bool shouldRepaint(covariant StaffPainter oldDelegate) =>
      oldDelegate.clef != clef ||
      !listEquals(oldDelegate.positions, positions) ||
      oldDelegate.jitterSeed != jitterSeed ||
      oldDelegate.staffSpace != staffSpace ||
      oldDelegate.noteheadDiameter != noteheadDiameter ||
      oldDelegate.highlightIndex != highlightIndex ||
      oldDelegate.anchorOverlay?.index != anchorOverlay?.index ||
      oldDelegate.anchorOverlay?.label != anchorOverlay?.label ||
      oldDelegate.anchorOverlay?.ghost != anchorOverlay?.ghost;
}