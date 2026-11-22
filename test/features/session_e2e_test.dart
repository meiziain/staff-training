// 规格: 09 M3 退出标准 —— 诊断→锚点训练端到端可玩；08 §3 集成清单（会话落库一致）。
// 端到端：SessionSetup 建队列 → S3 作答 → 试次落库 → 退出保存 doneCount。
@Tags(['widget'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/data/db.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/session_service.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart'
    show Delayer;
import 'package:sight_reading/features/session/session_page.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  final List<int> notes = [];
  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async => notes.add(midi);
  @override
  Future<void> playComparison(
      {required int answerMidi,
      required int correctMidi,
      Duration gap = const Duration(milliseconds: 400)}) async {
    notes.add(answerMidi);
    notes.add(correctMidi);
  }

  @override
  Future<void> playSequence(List<int> midis,
      {Duration interval = const Duration(milliseconds: 500)}) async {
    notes.addAll(midis);
  }

  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

class FakeDelayer implements Delayer {
  final List<(int, Completer<void>)> _pending = [];
  int _now = 0;
  @override
  Future<void> delay(Duration d) {
    final c = Completer<void>();
    _pending.add((_now + d.inMilliseconds, c));
    return c.future;
  }

  void elapse(int ms) {
    _now += ms;
    final due = _pending.where((p) => p.$1 <= _now).toList();
    _pending.removeWhere((p) => p.$1 <= _now);
    for (final p in due) {
      p.$2.complete();
    }
  }
}

void main() {
  testWidgets('端到端：作答两题落库，退出保存 doneCount', (tester) async {
    late final dynamic db;
    late final SessionBundle bundle;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      final appState = AppStateRepo(db);
      await appState.set('active_anchors', '[0,4]');
      await appState.set('course_stage', '1'); // 阶段1 有关系条目，队列充足
      await appState.set('diagnosis_done', '1');
      bundle = await SessionSetup.build(
        db: db,
        config: Config.defaults,
        clock: FakeClock(),
        rng: rng(1),
        dailyCount: 20,
      );
    });

    final audio = FakeAudio();
    final delayer = FakeDelayer();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        configProvider.overrideWith((ref) async => Config.defaults),
        audioServiceProvider.overrideWithValue(audio),
        clockProvider.overrideWithValue(FakeClock()),
      ],
      child: MaterialApp(
        home: SessionPage(bundle: bundle, delayer: delayer),
      ),
    ));
    await tester.pump(); // 构建
    await tester.pump(); // post-frame onset

    expect(bundle.engine.queueLength, greaterThanOrEqualTo(2));

    // 答第 1 题（热身锚点）：按目标音名作答。
    final t1 = bundle.engine.current!.item.targetIndices.last;
    await tester.tap(find.text(pitchClassOf(t1)));
    await tester.pump();
    expect(bundle.engine.doneCount, 1);
    expect(audio.notes, contains(midiOf(t1))); // 答对播音
    delayer.elapse(600); // 反馈标记
    await tester.pump();
    delayer.elapse(800); // 空屏
    await tester.pump();
    await tester.pump(); // 下一题 onset

    // 答第 2 题。
    final t2 = bundle.engine.current!.item.targetIndices.last;
    await tester.tap(find.text(pitchClassOf(t2)));
    await tester.pump();
    expect(bundle.engine.doneCount, 2);
    delayer.elapse(600);
    await tester.pump();
    delayer.elapse(800);
    await tester.pump();
    await tester.pump();

    // 落库校验（真实异步 I/O 走 runAsync）。
    await tester.runAsync(() async {
      await bundle.flush();
      final trials = await db.query('trial_log');
      expect(trials.length, 2);
      expect(trials.every((r) => r['correct'] == 1), isTrue);
    });

    // 退出：确认弹窗 → doneCount 保存。
    await tester.tap(find.byKey(const Key('session_exit')));
    await tester.pump();
    expect(find.textContaining('已保存'), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pump();
    await tester.runAsync(() async {
      await bundle.flush();
      final s = await db.query('session');
      expect(s.single['done_count'], 2);
    });
  });
}