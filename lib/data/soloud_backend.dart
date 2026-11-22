// 规格: 03 §4.1 —— flutter_soloud 薄包装（生产后端）。
// 本文件依赖 Flutter（flutter_soloud），只允许在生产装配处 import；
// dart test（零 Flutter 依赖）走 audio_backend.dart 抽象 + FakeBackend。
//
// 平台音频焦点/会话限制（03 §4.1 要求，flutter_soloud 3.5.4 未暴露对应 API）：
// - Android：引擎经 miniaudio 走 AAudio/OpenSL ES 默认媒体流，不申请
//   AudioFocus（transient focus 需原生侧 AudioFocusRequest，后续平台通道补齐）。
// - iOS：AVAudioSession category/混音选项由 miniaudio 默认接管，Dart 侧无法
//   设置 playback + mixWithOthers；如需不打断用户背景音乐，需原生侧配置。
// 以上列入报告，真机验收（08 §5 延迟测量）待做。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_backend.dart';

/// AudioBackend 的 flutter_soloud 实现。保持薄包装：
/// 只做引擎生命周期、asset 加载与发声实例管理，不含业务调度。
class SoloudBackend implements AudioBackend {
  final SoLoud _soloud = SoLoud.instance;
  final Set<SoundHandle> _activeHandles = {};

  @override
  Future<void> init() async {
    if (_soloud.isInitialized) return;
    // flutter_soloud 的 Loader 用 path_provider.getTemporaryDirectory() 建缓存目录，
    // 拿不到目录时 loadAsset 会抛 SoLoudTemporaryFolderFailedException。
    // 先自行确保临时目录可用（失败只记录，交由上层降级为无声）。
    try {
      final tmp = await getTemporaryDirectory();
      await Directory(tmp.path).create(recursive: true);
      debugPrint('SOLOUD: tmp ok ${tmp.path}');
    } catch (e) {
      debugPrint('SOLOUD: tmp failed $e');
    }
    // bufferSize 512 @44.1kHz ≈ 11.6ms 缓冲，为 ≤30ms 触发→出声留余量
    // （默认 2048 ≈ 46ms 超标）。若低端机出现 underrun 再回调大，08 §5 实测裁决。
    // automaticCleanup：启动时清掉上次残留的临时音频文件。
    await _soloud.init(
      sampleRate: 44100,
      bufferSize: 512,
      automaticCleanup: true,
    );
    debugPrint('SOLOUD: init done, initialized=${_soloud.isInitialized}');
  }

  @override
  Future<LoadedSound> loadAsset(String assetPath) =>
      _soloud.loadAsset(assetPath, mode: LoadMode.memory);

  @override
  Future<LoadedSound> loadBytes(Uint8List pcm, {int sampleRate = 44100}) {
    // flutter_soloud 3.5.4 提供 loadMem（内存中的完整音频文件），没有直接
    // 接受裸 PCM 的 API。这里在内存里补 44 字节 WAV 头后走 loadMem：
    // 既复用官方内存加载通道，又不新增任何 asset 文件。
    final wav = _wrapPcmAsWav(pcm, sampleRate: sampleRate);
    final key = 'memory_click_${_memoryKey++}.$sampleRate.wav';
    return _soloud.loadMem(key, wav, mode: LoadMode.memory);
  }

  int _memoryKey = 0;

  @override
  Future<void> play(LoadedSound sound) async {
    final handle = await _soloud.play(sound as AudioSource);
    _activeHandles.add(handle);
  }

  @override
  void stopAll() {
    if (!_soloud.isInitialized) return;
    final handles = _activeHandles.toList();
    _activeHandles.clear();
    for (final handle in handles) {
      // SoLoud.stop 对已自然结束的 handle 会立即完成，安全。
      // 原生停止指令同步发出；异步收尾不阻塞调用方（stop() 须同步生效）。
      unawaited(_soloud.stop(handle).catchError((Object _) {}));
    }
  }

  @override
  Future<void> dispose() async {
    stopAll();
    if (_soloud.isInitialized) {
      _soloud.deinit(); // 释放全部采样与引擎（disposeAllSound + deinit）。
    }
  }
}

/// 给 16-bit 单声道小端 PCM 补标准 44 字节 WAV 头。
Uint8List _wrapPcmAsWav(Uint8List pcm, {required int sampleRate}) {
  if (sampleRate <= 0) {
    throw ArgumentError.value(sampleRate, 'sampleRate', '采样率必须大于 0');
  }
  final header = ByteData(44);

  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // fmt chunk 长度
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // 单声道
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  header.setUint16(32, 2, Endian.little); // block align
  header.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);

  final wav = Uint8List(44 + pcm.length);
  wav.setRange(0, 44, header.buffer.asUint8List());
  wav.setRange(44, wav.length, pcm);
  return wav;
}