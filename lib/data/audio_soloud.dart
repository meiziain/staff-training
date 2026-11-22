// 规格: 03 §4.1 / 02 §1.4 / 07 §1 —— AudioService 的 soloud 调度实现。
// 纯 Dart（零 Flutter 依赖）：后端与调度器均注入，dart test 用
// FakeBackend + FakeScheduler 验证时序。生产装配：
//   SoloudAudioService(backend: SoloudBackend())  // soloud_backend.dart
// 裁决：构造器不设默认 SoloudBackend——默认值会把 flutter_soloud（Flutter）
// 拖进本文件，破坏 dart test 零 Flutter 依赖口径（dart_test.yaml）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/audio_service.dart';
import 'audio_backend.dart';

/// MVP 采样池：C3–C6 全部自然音，22 个 MIDI（07 §1）。
const List<int> kNotePoolMidis = [
  48, 50, 52, 53, 55, 57, 59, //
  60, 62, 64, 65, 67, 69, 71, //
  72, 74, 76, 77, 79, 81, 83, 84,
];

/// 采样 asset 路径（07 §1：`assets/audio/note_<midi>.ogg`）。
String noteAssetPath(int midi) => 'assets/audio/note_$midi.ogg';

class SoloudAudioService implements AudioService {
  SoloudAudioService({
    required this.backend,
    this.scheduler = const TimerScheduler(),
  });

  final AudioBackend backend;
  final AudioScheduler scheduler;
  final Map<int, LoadedSound> _sounds = {};
  final List<ScheduledTask> _pending = [];
  LoadedSound? _clickStrong;
  LoadedSound? _clickWeak;
  bool _muted = false;
  bool _disposed = false;

  @override
  Future<void> init() async {
    await backend.init();
    for (final midi in kNotePoolMidis) {
      _sounds[midi] = await backend.loadAsset(noteAssetPath(midi));
    }
    // click 采样一次性由内存 PCM 生成并缓存，播放期零加载。
    await _ensureClicks();
  }

  @override
  Future<void> playNote(int midi) async {
    if (_muted || _disposed) return;
    final sound = _sounds[midi];
    if (sound == null) return; // 池外 midi 静默忽略（MVP 无变音记号）。
    await backend.play(sound);
  }

  @override
  Future<void> playClick({required bool accent}) async {
    if (_muted || _disposed) return;
    var sound = accent ? _clickStrong : _clickWeak;
    if (sound == null) {
      // init() 已预加载；此处仅作未 init 时的兜底，之后全部命中缓存。
      await _ensureClicks();
      sound = accent ? _clickStrong : _clickWeak;
    }
    if (sound == null) return;
    // 发声指令异步发出即可，不等待播放完成（不阻塞 UI / 拍判定）。
    unawaited(backend.play(sound));
  }

  /// 生成并缓存强/弱两拍 click。强拍频率更高。
  Future<void> _ensureClicks() async {
    if (_clickStrong != null && _clickWeak != null) return;
    final strong = await backend.loadBytes(_buildClickPcm(frequencyHz: 1760));
    final weak = await backend.loadBytes(_buildClickPcm(frequencyHz: 1245));
    _clickStrong = strong;
    _clickWeak = weak;
  }

  @override
  Future<void> playComparison({
    required int answerMidi,
    required int correctMidi,
    Duration gap = const Duration(milliseconds: 400),
  }) async {
    stop(); // 新反馈打断旧序列，避免叠音。
    await playNote(answerMidi);
    _schedule(gap, () => playNote(correctMidi));
  }

  @override
  Future<void> playSequence(
    List<int> midis, {
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    stop();
    if (midis.isEmpty) return;
    await playNote(midis.first);
    // 一次性排程全部时间点（非 Timer 链），stop() 可整体取消。
    for (var i = 1; i < midis.length; i++) {
      final midi = midis[i];
      _schedule(interval * i, () => playNote(midi));
    }
  }

  @override
  void stop() {
    for (final task in _pending) {
      task.cancel();
    }
    _pending.clear();
    backend.stopAll();
  }

  @override
  bool get muted => _muted;

  @override
  set muted(bool value) => _muted = value;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    stop();
    _disposed = true;
    _sounds.clear();
    _clickStrong = null;
    _clickWeak = null;
    await backend.dispose();
  }

  void _schedule(Duration delay, void Function() callback) {
    late final ScheduledTask task;
    task = scheduler.schedule(delay, () {
      _pending.removeWhere((t) => t == task);
      callback();
    });
    _pending.add(task);
  }
}

/// 生成 1024 帧 16-bit 单声道小端 tick：短促衰减正弦，强拍频率更高。
Uint8List _buildClickPcm({
  required int frequencyHz,
  int frames = 1024,
  int sampleRate = 44100,
}) {
  final pcm = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    final envelope = 1 - i / frames;
    final sample =
        math.sin(2 * math.pi * frequencyHz * i / sampleRate) * envelope * 0.45;
    pcm.setInt16(i * 2, (sample * 32767).round(), Endian.little);
  }
  return pcm.buffer.asUint8List();
}