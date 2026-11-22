// 规格: 视奏训练改进 P0 / T01 —— 难度阶梯模型。零 Flutter、零数据库依赖。
//
// 阶梯口径来自调研结论：L1–L4 为单手视读能力提升，L5–L7 为双谱（SR = sight reading）
// 训练。sharedCursor 表示双手共享一个进度光标（SR-P 并行），false 表示双轨独立。
library;

import 'sight_score.dart';

/// 单档难度的全部生成/呈现参数。
class SightLevelSpec {
  final SightMode mode;

  /// 档位推荐速度区间的下界/上界。字段名沿用历史 bpmMin/bpmMax，
  /// 语义按 T07 正名为「每分钟四分音符数（♩=N）」的推荐范围，与拍号无关。
  final int bpmMin;
  final int bpmMax;

  /// 音域闭区间（diatonicIndex，C4=0）。null 表示按声部默认音域。
  final int? pitchMin;
  final int? pitchMax;

  /// 允许的音符时值（拍数，四分=1）。
  final Set<int> allowedDurations;

  /// 每小节拍数。
  final int beatsPerBar;

  /// 视读提前量（拍）。0 表示不设视读窗。
  final int readAheadBeats;

  /// 预告时长（秒）。
  final int previewSeconds;

  /// 是否双手共享光标（SR-P）。
  final bool sharedCursor;

  const SightLevelSpec({
    required this.mode,
    required this.bpmMin,
    required this.bpmMax,
    this.pitchMin,
    this.pitchMax,
    required this.allowedDurations,
    this.beatsPerBar = 4,
    this.readAheadBeats = 0,
    this.previewSeconds = 5,
    this.sharedCursor = false,
  });

  /// 档位代表速度（取区间下限）：每分钟四分音符数（♩=N），与拍号无关。
  int get bpm => bpmMin;
}

/// 视奏难度七档。
enum SightLevel {
  L1('L1'),
  L2('L2'),
  L3('L3'),
  L4('L4'),
  L5_SR_P('L5_SR_P'),
  L6_SR_A('L6_SR_A'),
  L7_SR_G('L7_SR_G');

  final String wire;

  const SightLevel(this.wire);

  static SightLevel fromWire(String s) =>
      SightLevel.values.firstWhere((e) => e.wire == s);

  /// 每档默认参数（P0 调研阶梯）。
  SightLevelSpec get spec => switch (this) {
        SightLevel.L1 => const SightLevelSpec(
            mode: SightMode.trebleOnly,
            bpmMin: 50,
            bpmMax: 60,
            pitchMin: 0,
            pitchMax: 4,
            allowedDurations: {1},
            beatsPerBar: 4,
            readAheadBeats: 0,
            previewSeconds: 5,
            sharedCursor: false,
          ),
        SightLevel.L2 => const SightLevelSpec(
            mode: SightMode.trebleOnly,
            bpmMin: 60,
            bpmMax: 70,
            pitchMin: 0,
            pitchMax: 7,
            allowedDurations: {1, 2},
            beatsPerBar: 4,
            readAheadBeats: 0,
            previewSeconds: 5,
            sharedCursor: false,
          ),
        SightLevel.L3 => const SightLevelSpec(
            mode: SightMode.trebleOnly,
            bpmMin: 60,
            bpmMax: 70,
            pitchMin: 0,
            pitchMax: 7,
            allowedDurations: {1, 2, 3},
            beatsPerBar: 4,
            readAheadBeats: 0,
            previewSeconds: 5,
            sharedCursor: false,
          ),
        SightLevel.L4 => const SightLevelSpec(
            mode: SightMode.trebleOnly,
            bpmMin: 60,
            bpmMax: 90,
            pitchMin: 0,
            pitchMax: sightTrebleMax,
            allowedDurations: {1, 2},
            beatsPerBar: 4,
            readAheadBeats: 3,
            previewSeconds: 5,
            sharedCursor: false,
          ),
        SightLevel.L5_SR_P => const SightLevelSpec(
            mode: SightMode.grand,
            bpmMin: 50,
            bpmMax: 70,
            pitchMin: -7,
            pitchMax: 7,
            allowedDurations: {1},
            beatsPerBar: 4,
            readAheadBeats: 0,
            previewSeconds: 5,
            sharedCursor: true,
          ),
        SightLevel.L6_SR_A => const SightLevelSpec(
            mode: SightMode.grand,
            bpmMin: 60,
            bpmMax: 80,
            pitchMin: sightBassMin,
            pitchMax: sightTrebleMax,
            allowedDurations: {1, 2},
            beatsPerBar: 4,
            readAheadBeats: 2,
            previewSeconds: 5,
            sharedCursor: true,
          ),
        SightLevel.L7_SR_G => const SightLevelSpec(
            mode: SightMode.grand,
            bpmMin: 60,
            bpmMax: 100,
            pitchMin: sightAllMin,
            pitchMax: sightAllMax,
            allowedDurations: {1, 2},
            beatsPerBar: 4,
            readAheadBeats: 0,
            previewSeconds: 3,
            sharedCursor: false,
          ),
      };
}
