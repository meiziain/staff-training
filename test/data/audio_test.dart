// 规格: 03 §4.1 / 02 §1.4 / 07 §1 —— 音频调度逻辑单测。
// FakeBackend 记录调用；FakeScheduler 手动推进时钟验证时序（零 Flutter 依赖）。
// SoloudBackend 真实实现需真机验收（08 §5 延迟测量），不在本文件覆盖。
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:sight_reading/data/audio_backend.dart';
import 'package:sight_reading/data/audio_soloud.dart';

/// 记录型假后端：handle 用 'path' 字符串标识，便于断言查表正确。
class FakeBackend implements AudioBackend {
  @override
  Future<LoadedSound> loadBytes(Uint8List pcm, {int sampleRate = 44100}) async =>
      'bytes:${pcm.length}@$sampleRate';

  final List<String> loadedAssets = [];
  final List<LoadedSound> played = [];
  int initCount = 0;
  int stopAllCount = 0;
  bool disposed = false;

  @override
  Future<void> init() async => initCount++;

  @override
  Future<LoadedSound> loadAsset(String assetPath) async {
    loadedAssets.add(assetPath);
    return assetPath; // handle 即路径，可辨识。
  }

  @override
  Future<void> play(LoadedSound sound) async => played.add(sound);

  @override
  void stopAll() => stopAllCount++;

  @override
  Future<void> dispose() async => disposed = true;
}

class _FakeTask implements ScheduledTask {
  _FakeTask(this.dueMs, this.callback);

  final int dueMs;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

/// 手动推进的假时钟：advance 按到期时间顺序触发未取消任务。
class FakeScheduler implements AudioScheduler {
  int nowMs = 0;
  final List<_FakeTask> _tasks = [];

  int get pendingCount => _tasks.where((t) => !t.cancelled).length;

  @override
  ScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _FakeTask(nowMs + delay.inMilliseconds, callback);
    _tasks.add(task);
    return task;
  }

  void advance(int ms) {
    final target = nowMs + ms;
    while (true) {
      final due = _tasks
          .where((t) => !t.cancelled && t.dueMs <= target)
          .toList()
        ..sort((a, b) => a.dueMs.compareTo(b.dueMs));
      if (due.isEmpty) break;
      final next = due.first;
      _tasks.remove(next);
      nowMs = next.dueMs;
      next.callback(); // 回调可能再排程，循环处理。
    }
    nowMs = target;
  }
}

void main() {
  late FakeBackend backend;
  late FakeScheduler scheduler;
  late SoloudAudioService service;

  setUp(() async {
    backend = FakeBackend();
    scheduler = FakeScheduler();
    service = SoloudAudioService(backend: backend, scheduler: scheduler);
    await service.init();
  });

  group('init 预加载', () {
    test('22 个 asset 路径齐全，引擎只初始化一次', () {
      expect(backend.initCount, 1);
      expect(backend.loadedAssets.length, 22);
      const midis = [
        48, 50, 52, 53, 55, 57, 59, //
        60, 62, 64, 65, 67, 69, 71, //
        72, 74, 76, 77, 79, 81, 83, 84,
      ];
      expect(
        backend.loadedAssets,
        midis.map((m) => 'assets/audio/note_$m.ogg').toList(),
      );
      expect(backend.played, isEmpty, reason: '预加载不发声');
    });
  });

  group('playNote', () {
    test('查表正确：60 → note_60 handle', () async {
      await service.playNote(60);
      expect(backend.played, ['assets/audio/note_60.ogg']);
      await service.playNote(48);
      expect(backend.played.last, 'assets/audio/note_48.ogg');
    });

    test('muted 时静默返回', () async {
      service.muted = true;
      expect(service.muted, isTrue);
      await service.playNote(60);
      expect(backend.played, isEmpty);
      service.muted = false;
      await service.playNote(60);
      expect(backend.played, ['assets/audio/note_60.ogg']);
    });

    test('池外 midi 静默忽略（61/47/85 无采样）', () async {
      await service.playNote(61);
      await service.playNote(47);
      await service.playNote(85);
      expect(backend.played, isEmpty);
    });
  });

  group('playComparison', () {
    test('answer 立即播，correct 在默认 400ms gap 后播', () async {
      await service.playComparison(answerMidi: 62, correctMidi: 60);
      expect(backend.played, ['assets/audio/note_62.ogg']);

      scheduler.advance(399);
      expect(backend.played.length, 1, reason: 'gap 未到不播 correct');

      scheduler.advance(1);
      expect(backend.played, [
        'assets/audio/note_62.ogg',
        'assets/audio/note_60.ogg',
      ]);
    });

    test('自定义 gap 生效', () async {
      await service.playComparison(
        answerMidi: 60,
        correctMidi: 64,
        gap: const Duration(milliseconds: 800),
      );
      scheduler.advance(799);
      expect(backend.played.length, 1);
      scheduler.advance(1);
      expect(backend.played.last, 'assets/audio/note_64.ogg');
    });

    test('gap 期间 muted，correct 静默', () async {
      await service.playComparison(answerMidi: 62, correctMidi: 60);
      service.muted = true;
      scheduler.advance(400);
      expect(backend.played, ['assets/audio/note_62.ogg']);
    });
  });

  group('playSequence', () {
    test('5 音按 500ms 间隔一次性排程', () async {
      const midis = [60, 62, 64, 65, 67];
      await service.playSequence(midis);
      expect(backend.played, ['assets/audio/note_60.ogg']);
      expect(scheduler.pendingCount, 4, reason: '其余 4 音已排程');

      for (var i = 1; i < midis.length; i++) {
        scheduler.advance(499);
        expect(backend.played.length, i, reason: '第 $i 音未到点');
        scheduler.advance(1);
        expect(backend.played.length, i + 1);
        expect(backend.played.last, 'assets/audio/note_${midis[i]}.ogg');
      }
      expect(scheduler.pendingCount, 0);
    });

    test('自定义 interval 生效', () async {
      await service.playSequence(
        [60, 64],
        interval: const Duration(milliseconds: 300),
      );
      scheduler.advance(299);
      expect(backend.played.length, 1);
      scheduler.advance(1);
      expect(backend.played.last, 'assets/audio/note_64.ogg');
    });

    test('空序列不播不排程', () async {
      await service.playSequence([]);
      expect(backend.played, isEmpty);
      expect(scheduler.pendingCount, 0);
    });
  });

  group('stop 取消调度', () {
    test('comparison 中途 stop：correct 不再播', () async {
      await service.playComparison(answerMidi: 62, correctMidi: 60);
      final before = backend.stopAllCount;
      service.stop();
      expect(backend.stopAllCount, before + 1);
      expect(scheduler.pendingCount, 0);
      scheduler.advance(1000);
      expect(backend.played, ['assets/audio/note_62.ogg']);
    });

    test('sequence 中途 stop：后续音不再播', () async {
      await service.playSequence([60, 62, 64, 65, 67]);
      scheduler.advance(500); // 第 2 音已播。
      expect(backend.played.length, 2);
      service.stop();
      expect(scheduler.pendingCount, 0);
      scheduler.advance(5000);
      expect(backend.played.length, 2, reason: 'stop 后剩余 3 音全部取消');
    });

    test('stop 后新播放正常（退后台→回前台恢复）', () async {
      await service.playSequence([60, 62, 64]);
      service.stop();
      await service.playNote(67);
      expect(backend.played.last, 'assets/audio/note_67.ogg');
    });

    test('新 comparison 打断旧序列', () async {
      await service.playSequence([60, 62, 64]);
      await service.playComparison(answerMidi: 65, correctMidi: 67);
      scheduler.advance(5000);
      expect(backend.played, [
        'assets/audio/note_60.ogg',
        'assets/audio/note_65.ogg',
        'assets/audio/note_67.ogg',
      ]);
    });
  });

  group('dispose', () {
    test('释放后端并取消 pending，之后播放静默', () async {
      await service.playSequence([60, 62, 64]);
      await service.dispose();
      expect(backend.disposed, isTrue);
      expect(scheduler.pendingCount, 0);
      scheduler.advance(5000);
      await service.playNote(60);
      expect(backend.played, ['assets/audio/note_60.ogg']);
    });
  });
}