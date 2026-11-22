// 规格: 06 §4 StaffView / 02 §2.2 §9 / 03 §4.2 —— 谱表几何纯函数，零 Flutter 依赖。
// 裁决: 任务文本"低音 G3(-3)=第一线"与加线规则（C4 低音上加一线）、谱号对齐
// （F3=第四线）及共享 domain（note_position.ledgerBass: C4）矛盾。按标准记谱
// 取 G2(-10) 为低音第一线（pos=index+10），满足 F3=第四线、C4=上加一线。
library;

import 'dart:math';

import '../domain/models/enums.dart';

/// 手机上符头直径下限（02 §9 / 06 §4：≥12dp）。
const double minNoteheadDiameter = 12;

/// 谱表第一线（底线）对应的 diatonicIndex：高音 E4=2，低音 G2=-10（标准记谱）。
int staffReferenceIndex(Clef clef) => clef == Clef.treble ? 2 : -10;

/// 线/间序号：第一线=0，每 +1 上移半间距；五线范围 0..8。
int staffPos(int index, Clef clef) => index - staffReferenceIndex(clef);

/// 音位中心 y（bottomLineY 为底线 y，y 轴向下）。
double noteY(int index, Clef clef, double staffSpace, double bottomLineY) =>
    bottomLineY - staffPos(index, clef) * staffSpace / 2;

/// 需绘制的加线（返回线/间序号，均为偶数）。
/// 规则：从五线边界到符头之间所有"线位置"都画；间音画到其相邻线为止。
List<int> ledgerLinesFor(int index, Clef clef) {
  final p = staffPos(index, clef);
  final result = <int>[];
  if (p < 0) {
    final lowest = p.isEven ? p : p + 1;
    for (var l = -2; l >= lowest; l -= 2) {
      result.add(l);
    }
  } else if (p > 8) {
    final highest = p.isEven ? p : p - 1;
    for (var l = 10; l <= highest; l += 2) {
      result.add(l);
    }
  }
  return result;
}

/// 加线 y 坐标列表（ledgerLinesFor 的几何换算）。
List<double> ledgerLineYs(
        int index, Clef clef, double staffSpace, double bottomLineY) =>
    ledgerLinesFor(index, clef)
        .map((p) => bottomLineY - p * staffSpace / 2)
        .toList();

/// 确定性位置抖动（02 §2.2 / 03 §4.2）：同 seed 同 index 同偏移，重绘不跳动。
/// 只做水平抖动（±1×staffSpace）；垂直方向必须为 0 —— 音位靠 y 判断「线/间」，
/// 垂直偏移会让符头脱离线/间中心，读成"压线但不居中"（可读性优先，02 §2.2）。
({double dx, double dy}) jitterOffset(int seed, int index, double staffSpace) {
  final r = Random(seed + index * 0x9E3779B9);
  final dx = (r.nextDouble() * 2 - 1) * staffSpace;
  return (dx: dx, dy: 0);
}

/// 尺寸度量：线间距随可用宽度缩放；符头直径=staffSpace，但不小于 12dp
/// （宽度不足时缩小间距，符头保底 12；override 同样受下限约束）。
({double staffSpace, double noteheadDiameter}) staffMetrics(
  double availableWidth, {
  double? noteheadDiameter,
}) {
  final space = (availableWidth / 28).clamp(6.0, 14.0).toDouble();
  final head = (noteheadDiameter ?? space)
      .clamp(minNoteheadDiameter, double.infinity)
      .toDouble();
  return (staffSpace: space, noteheadDiameter: head);
}