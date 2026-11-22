// 规格: 02 §2.1 / 05 §8 / 06 §2（S0/S1/S1R）—— 诊断流程 widget 测试。
// 时序全部经 FakeDelayer 手动推进；RT 用 FakeClock；无真实 ffi I/O。
@Tags(['widget'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/domain/diagnosis.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_pages.dart';
import 'package:sight_reading/ui/staff_view.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  final List<int> notes = [];
  final List<(int, int)> comparisons = [];
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
    comparisons.add((answerMidi, correctMidi));
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

class FakeSink implements DiagnosisSink {
  final List<DiagnosisResult> results = [];
  @override
  Future<void> save(DiagnosisResult result) async => results.add(result);
}

/// 手动推进的延时器：elapse 按到期顺序完成 pending future。
class FakeDelayer implements Delayer {
  int _now = 0;
  final List<(int, Completer<void>)> _pending = [];

  @override
  Future<void> delay(Duration d) {
    final c = Completer<void>();
    _pending.add((_now + d.inMilliseconds, c));
    return c.future;
  }

  void elapse(Duration d) {
    _now += d.inMilliseconds;
    _pending.sort((a, b) => a.$1.compareTo(b.$1));
    while (_pending.isNotEmpty && _pending.first.$1 <= _now) {
      _pending.removeAt(0).$2.complete();
    }
  }
}

class Harness {
  final sink = FakeSink();
  final delayer = FakeDelayer();
  final clock = FakeClock();
  final audio = FakeAudio();
  DiagnosisResult? doneResult;
  bool aborted = false;
  late DiagnosisController controller;
}

Future<Harness> pumpFlow(WidgetTester tester, {int seed = 7}) async {
  final h = Harness();
  final key = GlobalKey<DiagnosisFlowState>();
  final container = ProviderContainer(overrides: [
    configProvider.overrideWith((ref) async => Config.defaults),
    audioServiceProvider.overrideWithValue(h.audio),
    clockProvider.overrideWithValue(h.clock),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: DiagnosisFlow(
        key: key,
        sink: h.sink,
        delayer: h.delayer,
        seed: seed,
        onDone: (r) => h.doneResult = r,
        onAborted: () => h.aborted = true,
      ),
    ),
  ));
  await tester.pump(); // configProvider future 完成
  await tester.pump();
  h.controller = key.currentState!.controller!;
  return h;
}

Future<void> elapse(
    WidgetTester tester, Harness h, int ms) async {
  h.delayer.elapse(Duration(milliseconds: ms));
  h.clock.advance(Duration(milliseconds: ms));
  // pump1 仅 flush 微任务（无已调度帧）→ presenting；
  // pump2 构建呈现帧 + post-frame onset；pump3 渲染可作答态。
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> startDiagnosis(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('start_diagnosis')));
  await tester.pump();
  await tester.pump(); // post-frame onset → 可作答
}

/// 答当前块A/B 题（默认答对），推进 800ms 空屏到下一题。
Future<void> answerCurrent(WidgetTester tester, Harness h,
    {String? pc, bool checkBlank = false}) async {
  final c = h.controller;
  expect(c.phase, DiagPhase.awaitingAnswer,
      reason: 'trial ${c.trialIndex} 按钮应已可用');
  h.clock.advance(const Duration(milliseconds: 400));
  final note = c.currentNote!;
  await tester
      .tap(find.byKey(ValueKey('name_button_${pc ?? pitchClassOf(note)}')));
  await tester.pump();
  if (checkBlank) {
    expect(find.byKey(const ValueKey('diag_blank')), findsOneWidget);
    expect(find.byType(StaffView), findsNothing);
  }
  await elapse(tester, h, Config.defaults.interTrialBlankMs);
}

Future<void> runBlockA(WidgetTester tester, Harness h) async {
  for (var i = 0; i < 30; i++) {
    expect(h.controller.block, DiagBlock.anchor);
    await answerCurrent(tester, h, checkBlank: i == 0);
  }
  expect(h.controller.block, DiagBlock.strategy);
}

/// 块C 单题：推进 1000/500/1000 呈现时序 → 作答 → 800ms 空屏。
Future<void> answerConfusion(
    WidgetTester tester, Harness h, bool answer) async {
  await elapse(tester, h, 1000);
  expect(h.controller.confusionStage, ConfusionStage.gap);
  await elapse(tester, h, 500);
  expect(h.controller.confusionStage, ConfusionStage.second);
  await elapse(tester, h, 1000);
  expect(h.controller.phase, DiagPhase.awaitingAnswer);
  await tester.tap(find.byKey(
      ValueKey(answer ? 'same_button' : 'different_button')));
  await tester.pump();
  await elapse(tester, h, Config.defaults.interTrialBlankMs);
}

void main() {
  testWidgets('S0：渲染两按钮；跳过 → sink 收到默认结果 + toast', (tester) async {
    final h = await pumpFlow(tester);
    expect(find.text('锚点关系读谱训练'), findsOneWidget);
    expect(find.textContaining('约 6 分钟'), findsOneWidget);
    expect(find.text('开始诊断'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('skip_diagnosis')));
    await tester.pump();
    await tester.pump();
    expect(find.text('将从锚点建立开始，可随时在设置重置'), findsOneWidget);
    expect(h.sink.results, hasLength(1));
    final r = h.sink.results.single;
    expect(r.anchors, [0, 4]);
    expect(r.startStage, 0);
    expect(h.doneResult, isNotNull);
    expect(h.doneResult!.anchors, [0, 4]);
  });

  testWidgets('块A：30 题无反馈音、题间空屏 → 进入块B', (tester) async {
    final h = await pumpFlow(tester);
    await startDiagnosis(tester);
    final c = h.controller;
    expect(c.block, DiagBlock.anchor);
    expect(c.blockTotal, 30);
    expect(find.textContaining('锚点再认'), findsOneWidget);
    expect(c.phase, DiagPhase.awaitingAnswer);

    await runBlockA(tester, h);

    expect(h.audio.notes, isEmpty);
    expect(h.audio.comparisons, isEmpty);
    expect(find.textContaining('推导策略'), findsOneWidget);
    expect(find.textContaining('1/6'), findsOneWidget);
    final staff = tester.widget<StaffView>(find.byType(StaffView));
    expect(staff.anchorOverlay, isNotNull); // 块B 锚点常亮标注
    expect(c.anchorIndex, isIn([4, 7])); // 候选中高音区
    expect(h.sink.results, isEmpty); // 未完成不落结果
  });

  testWidgets('块B：请求提示两级计数；块C 正确作答 → 阶段 1（提示超限）',
      (tester) async {
    final h = await pumpFlow(tester);
    await startDiagnosis(tester);
    await runBlockA(tester, h);
    final c = h.controller;

    // 第一题请求两级提示。
    await tester.tap(find.byKey(const ValueKey('request_hint')));
    await tester.pump();
    expect(c.hintLevel, 1);
    expect(find.textContaining('目标在锚点'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('request_hint')));
    await tester.pump();
    expect(c.hintLevel, 2);
    expect(c.hintRequests, 2);
    expect(find.textContaining('距离锚点'), findsOneWidget);
    final hintBtn = tester.widget<TextButton>(
        find.byKey(const ValueKey('request_hint')));
    expect(hintBtn.onPressed, isNull); // 两级封顶

    for (var i = 0; i < 6; i++) {
      expect(c.block, DiagBlock.strategy);
      await answerCurrent(tester, h);
    }
    expect(c.block, DiagBlock.confusion);
    expect(c.blockTotal, 8);

    for (var i = 0; i < 8; i++) {
      await answerConfusion(tester, h, c.probe!.same);
    }

    expect(h.sink.results, hasLength(1));
    final r = h.sink.results.single;
    expect(r.blockB!.hintRequests, 2);
    expect(r.blockB!.acc, 1.0);
    expect(r.startStage, 1); // acc 达标但提示 > 1
    expect(r.seeds, isEmpty); // 块C 全对
  });

  testWidgets('完整流程：无提示全对 → 阶段 2；块C 全答相同 → seeds；S1R → 开始训练',
      (tester) async {
    final h = await pumpFlow(tester);
    await startDiagnosis(tester);
    await runBlockA(tester, h);
    for (var i = 0; i < 6; i++) {
      await answerCurrent(tester, h);
    }
    final c = h.controller;
    for (var i = 0; i < 8; i++) {
      await answerConfusion(tester, h, true); // 全答"相同"
    }

    expect(c.phase, DiagPhase.done);
    expect(h.sink.results, hasLength(1));
    final r = h.sink.results.single;
    expect(r.anchors, isNotEmpty);
    expect(r.anchors, contains(0)); // C4 必入
    expect(r.startStage, 2);
    expect(r.seeds, isNotEmpty); // 八度/跨谱表对判错 → 种子
    expect(h.audio.notes, isEmpty);
    expect(h.audio.comparisons, isEmpty);

    // S1R 渲染。
    expect(find.text('诊断报告'), findsOneWidget);
    expect(find.text('开始训练'), findsOneWidget);
    expect(h.doneResult, isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('start_training')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('start_training')));
    await tester.pump();
    expect(h.doneResult, same(r));
  });

  testWidgets('S1R：报告要素渲染（条形/初始锚点高亮/策略/种子/阶段）', (tester) async {
    final result = scoreDiagnosis(
      blockATrials: {
        0: List.generate(6, (_) => const DiagTrial(correct: true, rtMs: 600)),
        4: List.generate(6, (_) => const DiagTrial(correct: true, rtMs: 800)),
        -4: [
          for (var i = 0; i < 6; i++)
            DiagTrial(correct: i < 3, rtMs: 1500),
        ],
        7: List.generate(6, (_) => const DiagTrial(correct: true, rtMs: 1000)),
        -7: List.generate(6, (_) => const DiagTrial(correct: false, rtMs: 2000)),
      },
      blockBTrials:
          List.generate(6, (_) => const DiagTrial(correct: true, rtMs: 1800)),
      hintRequests: 0,
      seeds: [SeedPair.sorted(0, 7), SeedPair.sorted(4, -3)],
    );
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: DiagnosisReportPage(result: result, onDone: () => done = true),
    ));
    await tester.pump();

    expect(find.text('诊断报告'), findsOneWidget);
    for (final name in ['C4', 'G4', 'F3', 'C5', 'C3']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(result.anchors, [0, 4, 7]);
    expect(find.text('初始锚点'), findsNWidgets(3));
    expect(find.text('100%'), findsNWidgets(3));
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('600ms'), findsOneWidget);
    expect(find.textContaining('已能从锚点推导'), findsOneWidget);
    expect(find.text('C4 ↔ C5'), findsOneWidget);
    expect(find.text('G3 ↔ G4'), findsOneWidget);
    expect(find.text('起始阶段：阶段 2'), findsOneWidget);
    expect(find.textContaining('锚点建立（阶段 0）'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('start_training')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('start_training')));
    await tester.pump();
    expect(done, isTrue);
  });

  testWidgets('中途退出：诊断作废，sink 未收到结果', (tester) async {
    final h = await pumpFlow(tester);
    await startDiagnosis(tester);
    await answerCurrent(tester, h);
    await answerCurrent(tester, h);
    expect(h.controller.trialIndex, 2);

    await tester.tap(find.byKey(const ValueKey('exit_diagnosis')));
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, DiagPhase.aborted);
    expect(h.controller.result, isNull);
    expect(h.aborted, isTrue);

    // 残留延时到期也不得推进状态或落结果。
    await elapse(tester, h, 5000);
    expect(h.sink.results, isEmpty);
    expect(h.doneResult, isNull);
    expect(h.controller.phase, DiagPhase.aborted);
  });
}