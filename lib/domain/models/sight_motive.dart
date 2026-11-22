// 规格: 视奏训练改进 P0 / T01 —— 动机库（P0 五个，禁止四度以上跳进）。
// 动机是「音级差序列」，与绝对音高解耦；applyFrom 后整条音级序列含起始音。
library;

/// P0 动机种类。
enum SightMotiveKind {
  stepUp('stepUp'),
  stepDown('stepDown'),
  skipReturn('skipReturn'),
  repeat('repeat'),
  neighbor('neighbor');

  final String wire;

  const SightMotiveKind(this.wire);

  static SightMotiveKind fromWire(String s) =>
      SightMotiveKind.values.firstWhere((e) => e.wire == s);
}

/// 一个可拼接的旋律动机。
class SightMotive {
  final SightMotiveKind kind;

  /// 逐步音级差（+1 上行一级，+2 上行三度，0 同音）。
  final List<int> steps;

  /// 与 [steps] 等长；每步的时值（拍数），P0 全为 1。
  final List<int> durations;

  const SightMotive({
    required this.kind,
    required this.steps,
    required this.durations,
  });

  /// 动机签名用短标识；完整谱例签名见 sight_generator.sightMotiveSignature。
  String get wire => kind.wire;

  /// 从 [start] 起逐步累加，返回整条音级序列（含起始音）。
  List<int> applyFrom(int start) {
    final result = <int>[start];
    var current = start;
    for (final step in steps) {
      current += step;
      result.add(current);
    }
    return result;
  }

  /// 起点与每个落点都须落在闭区间 [lo, hi]。
  bool fits(int start, int lo, int hi) {
    if (start < lo || start > hi) return false;
    var current = start;
    for (final step in steps) {
      current += step;
      if (current < lo || current > hi) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is SightMotive && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'SightMotive($wire, steps=$steps)';
}

/// P0 五个动机（时长全 1 拍）。P0 不含四度以上跳进。
const SightMotive stepUpMotive = SightMotive(
  kind: SightMotiveKind.stepUp,
  steps: [1, 1],
  durations: [1, 1],
);

const SightMotive stepDownMotive = SightMotive(
  kind: SightMotiveKind.stepDown,
  steps: [-1, -1],
  durations: [1, 1],
);

const SightMotive skipReturnMotive = SightMotive(
  kind: SightMotiveKind.skipReturn,
  steps: [2, -1],
  durations: [1, 1],
);

const SightMotive repeatMotive = SightMotive(
  kind: SightMotiveKind.repeat,
  steps: [0, 0],
  durations: [1, 1],
);

const SightMotive neighborMotive = SightMotive(
  kind: SightMotiveKind.neighbor,
  steps: [1, -1],
  durations: [1, 1],
);

/// P0 动机库（生成器只从此处抽取）。
const List<SightMotive> kP0Motives = [
  stepUpMotive,
  stepDownMotive,
  skipReturnMotive,
  repeatMotive,
  neighborMotive,
];
