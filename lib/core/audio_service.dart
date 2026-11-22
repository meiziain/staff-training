// 规格: 03 §3 §4.1 / 02 §1.4 —— 音频服务接口（data 层 soloud 实现）。
// 启动预加载 22 采样入内存；播放不做磁盘 IO；触发→出声 ≤30ms。
library;

/// 音频服务接口。UI 与规则层只依赖本接口。
abstract interface class AudioService {
  /// 初始化并预加载全部 22 个采样（`assets/audio/note_<midi>.ogg`）。
  Future<void> init();

  /// 播放单音（midi：C4=60）。静音时静默返回。
  Future<void> playNote(int midi);

  /// 拍网格 click（T02）。accent=true 为强拍，音色更高；静音时静默返回。
  /// 采样由内存 PCM 生成并缓存复用，不依赖任何新增 asset。
  Future<void> playClick({required bool accent});

  /// 答错对比音：用户答案音 → gap(默认400ms) → 正确答案音（02 §1.4）。
  /// 用调度好的延迟播放，不阻塞 UI。
  Future<void> playComparison({
    required int answerMidi,
    required int correctMidi,
    Duration gap = const Duration(milliseconds: 400),
  });

  /// 短句连播：每音 interval(默认500ms) 间隔（02 §5.2）。
  Future<void> playSequence(
    List<int> midis, {
    Duration interval = const Duration(milliseconds: 500),
  });

  /// 立即停止所有播放与已调度序列（退后台立即 stop，03 §4.1）。
  void stop();

  /// 全局静音开关（静音时视觉反馈不受影响，02 §1.4）。
  bool get muted;
  set muted(bool value);

  Future<void> dispose();
}