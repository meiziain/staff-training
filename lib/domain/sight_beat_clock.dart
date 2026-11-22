// 规格: 视奏训练改进 P0 / T02 —— 拍网格时钟（纯 Dart）。
//
// 判定基准一律为 onsetOf(beatIndex) 的绝对时刻，绝不用「上一拍 onset + 拍长」
// 逐拍累加，避免 60000/bpm 非整数时产生漂移。时间来源只有 Clock.monotonicMs()。
library;

import '../core/clock.dart';

/// 拍网格时钟：把「每分钟四分音符数」映射到绝对单调时刻。
///
/// 速度是 ♩=N 的统一标尺，与拍号无关；拍号分母只决定"一拍"是几分音符。
class SightBeatClock {
  final Clock clock;

  /// 每分钟四分音符数（♩=N）。不是"每分钟拍数"——后者会随拍号变。
  final int quartersPerMinute;

  final int beatsPerBar;

  /// 拍号分母：4=四分音符为一拍（基准），8=八分音符为一拍（时长减半）。
  final int denominator;

  int? _startMonoMs;
  int? _pausedElapsedMs;

  SightBeatClock({
    required this.clock,
    int? quartersPerMinute,
    @Deprecated('用 quartersPerMinute（每分钟四分音符数）') int? bpm,
    this.beatsPerBar = 4,
    this.denominator = 4,
  }) : quartersPerMinute = quartersPerMinute ?? bpm ?? 60 {
    if (quartersPerMinute != null &&
        bpm != null &&
        quartersPerMinute != bpm) {
      throw ArgumentError('quartersPerMinute 与已废弃的 bpm 不能同时给出不同值');
    }
    if (this.quartersPerMinute <= 0) {
      throw ArgumentError.value(
        this.quartersPerMinute,
        'quartersPerMinute',
        '每分钟四分音符数必须大于 0',
      );
    }
    if (denominator <= 0) {
      throw ArgumentError.value(denominator, 'denominator', '拍号分母必须大于 0');
    }
  }

  /// 兼容旧调用的只读别名；语义同样为每分钟四分音符数。
  @Deprecated('用 quartersPerMinute（每分钟四分音符数）')
  int get bpm => quartersPerMinute;

  /// 启动/重启网格：以 [atMonoMs] 作为第 0 拍 onset。
  void start(int atMonoMs) {
    _startMonoMs = atMonoMs;
    _pausedElapsedMs = null;
  }

  /// 第 [beatIndex] 拍的绝对 onset（ms）。
  ///
  /// 未 start 时抛 StateError；负数拍号表示起点之前，允许计算。
  int onsetOf(int beatIndex) {
    final start = _startMonoMs;
    if (start == null) {
      throw StateError('SightBeatClock 尚未 start，无法计算 onset');
    }
    // denominator=4 时与旧公式 (beatIndex * 60000 / quartersPerMinute).round()
    // 完全一致；分母 8 时一拍是八分音符，速度标尺（四分音符/分钟）不变。
    return start +
        (beatIndex * 60000.0 * 4 / (quartersPerMinute * denominator)).round();
  }

  /// [nowMonoMs] 是否已到达第 [beatIndex] 拍 onset。
  bool isDue(int beatIndex, int nowMonoMs) => nowMonoMs >= onsetOf(beatIndex);

  /// 暂停：记录已流逝时长；重复 pause 幂等。
  void pause(int atMonoMs) {
    final start = _startMonoMs;
    if (start == null) {
      throw StateError('SightBeatClock 尚未 start，无法 pause');
    }
    if (_pausedElapsedMs != null) return;
    _pausedElapsedMs = atMonoMs - start;
  }

  /// 恢复：平移起点，使暂停区间不计入拍网格。
  void resume(int atMonoMs) {
    final start = _startMonoMs;
    if (start == null) {
      throw StateError('SightBeatClock 尚未 start，无法 resume');
    }
    final elapsed = _pausedElapsedMs;
    if (elapsed == null) return;
    _startMonoMs = atMonoMs - elapsed;
    _pausedElapsedMs = null;
  }

  /// 停止并清空起点与暂停状态。
  void stop() {
    _startMonoMs = null;
    _pausedElapsedMs = null;
  }

  /// 当前注入时钟的单调毫秒（便捷读取，判定仍以显式传入的时刻为准）。
  int get nowMonoMs => clock.monotonicMs();

  bool get isRunning => _startMonoMs != null;
  bool get isPaused => _pausedElapsedMs != null;
  int? get startMonoMs => _startMonoMs;
}
