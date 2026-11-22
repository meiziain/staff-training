// 规格: 视奏训练改进 P0 / T06 —— 拍号模型（零 Flutter 依赖）。
//
// 音乐口径：分母 = 以什么音符为一拍（4=四分，8=八分，一拍时长减半→同 BPM 下
// 流速翻倍）；分子 = 每小节几拍，决定重音位置（第 0 拍 accent）。
// 拍号只影响时间维度，不改音高序列生成。
library;

/// 一个拍号，如 4/4、6/8。
class SightTimeSignature {
  /// 分子：每小节拍数。
  final int numerator;

  /// 分母：一拍的时值单位（P0 支持 4 与 8）。
  final int denominator;

  const SightTimeSignature(this.numerator, this.denominator);

  /// 通用 4/4（默认）。
  static const SightTimeSignature common4_4 = SightTimeSignature(4, 4);

  /// UI 下拉预设。
  static const List<SightTimeSignature> presets = [
    common4_4,
    SightTimeSignature(3, 4),
    SightTimeSignature(2, 4),
    SightTimeSignature(4, 8),
    SightTimeSignature(6, 8),
    SightTimeSignature(3, 8),
  ];

  String get wire => '$numerator/$denominator';

  String get displayName => wire;

  /// 把「每分钟四分音符数（♩=N）」换算成本拍号下「一拍」的毫秒数。
  ///
  /// 速度标尺与拍号无关：♩=60 时四分音符恒为 1000ms。分母 4 时一拍就是
  /// 四分音符（1000ms）；分母 8 时一拍是八分音符（500ms）。换拍号只改变
  /// "几拍一小节 / 哪一拍是重音 / 一拍多长"，不改变每分钟四分音符数。
  int beatMsAt(int quartersPerMinute) {
    if (quartersPerMinute <= 0) {
      throw ArgumentError.value(
        quartersPerMinute,
        'quartersPerMinute',
        '每分钟四分音符数必须大于 0',
      );
    }
    if (denominator <= 0) {
      throw ArgumentError.value(denominator, 'denominator', '拍号分母必须大于 0');
    }
    return (60000.0 * 4 / (quartersPerMinute * denominator)).round();
  }

  @override
  bool operator ==(Object other) =>
      other is SightTimeSignature &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => 'SightTimeSignature($wire)';
}
