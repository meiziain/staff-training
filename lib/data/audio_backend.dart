// 规格: 03 §4.1 / 02 §1.4 —— 音频后端与调度器抽象（纯 Dart，零 Flutter 依赖）。
// 生产实现 SoloudBackend 见 soloud_backend.dart（依赖 flutter_soloud，
// 只在生产装配处 import）；调度逻辑 SoloudAudioService 见 audio_soloud.dart，
// 测试注入 FakeBackend + FakeScheduler 验证时序（dart test 口径，dart_test.yaml）。
library;

import 'dart:async';
import 'dart:typed_data';

/// 已加载采样的不透明句柄。生产为 flutter_soloud 的 AudioSource，
/// 测试为任意可辨识对象。调度层只透传，不解析。
typedef LoadedSound = Object;

/// 音频后端最小面：初始化 / 预加载 / 播放 / 全停 / 释放。
abstract interface class AudioBackend {
  /// 初始化音频引擎（幂等）。
  Future<void> init();

  /// 从 asset 加载采样入内存（LoadMode.memory），播放期不做磁盘 IO。
  Future<LoadedSound> loadAsset(String assetPath);

  /// 从内存 PCM（16-bit 单声道小端）加载采样，不新增 asset 文件。
  /// 用于节拍 click 的极短 tick 波形。
  Future<LoadedSound> loadBytes(Uint8List pcm, {int sampleRate = 44100});

  /// 播放已加载采样（新建发声实例，可叠加）。
  Future<void> play(LoadedSound sound);

  /// 立即停止所有正在发声的实例（同步发出停止指令）。
  void stopAll();

  /// 停止并释放引擎与全部采样。
  Future<void> dispose();
}

/// 一次已排程的延迟任务，可取消。
abstract interface class ScheduledTask {
  void cancel();
}

/// 延迟调度器抽象：生产用 Timer，测试用手动推进的假时钟。
abstract interface class AudioScheduler {
  /// delay 后执行 callback（非阻塞，不占用 UI）。
  ScheduledTask schedule(Duration delay, void Function() callback);
}

/// 生产调度器：dart:async Timer（单任务单 Timer，无链式阻塞）。
class TimerScheduler implements AudioScheduler {
  const TimerScheduler();

  @override
  ScheduledTask schedule(Duration delay, void Function() callback) =>
      _TimerTask(Timer(delay, callback));
}

class _TimerTask implements ScheduledTask {
  _TimerTask(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}