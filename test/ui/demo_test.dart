// 规格: 09 M2 退出标准 —— 演示页：呈现任意音位 → 两种模式作答 → 播音，事件字段完整。
// 测试直接 override configProvider（纯异步），避免 ffi 真实 I/O 在 fake async 区挂起。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/features/demo/demo_page.dart';

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

Future<void> pumpDemo(WidgetTester tester,
    {FakeAudio? audio, FakeClock? clock}) async {
  final container = ProviderContainer(overrides: [
    configProvider.overrideWith((ref) async => Config.defaults),
    audioServiceProvider.overrideWithValue(audio ?? FakeAudio()),
    clockProvider.overrideWithValue(clock ?? FakeClock()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: DemoPage()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('演示页：音名模式作答 → 事件字段完整 + 播音', (tester) async {
    final audio = FakeAudio();
    await pumpDemo(tester, audio: audio);
    // 默认目标 G4(4)。点 G → 答对 → playNote(67)。
    await tester.tap(find.text('G'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AnswerEvent'), findsOneWidget);
    expect(find.textContaining('"pitchClass": "G"'), findsOneWidget);
    expect(find.textContaining('"source": "NAME_BUTTON"'), findsOneWidget);
    expect(find.textContaining('"rtMs"'), findsOneWidget);
    expect(audio.notes, contains(67));
  });

  testWidgets('演示页：答错走对比音', (tester) async {
    final audio = FakeAudio();
    await pumpDemo(tester, audio: audio);
    await tester.tap(find.text('C')); // 目标 G4，答 C → 错
    await tester.pumpAndSettle();
    expect(audio.comparisons.length, 1);
    expect(audio.comparisons.single.$2, 67); // 正确音 G4
  });

  testWidgets('演示页：键盘模式作答含八度', (tester) async {
    final audio = FakeAudio();
    await pumpDemo(tester, audio: audio);
    await tester.tap(find.text('键盘'));
    await tester.pumpAndSettle();
    expect(find.text('C4'), findsWidgets);
    // 点击第一个 C 键（C3）→ 事件 octave=3。
    await tester.tap(find.text('C').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('"source": "VIRTUAL_KEY"'), findsOneWidget);
    expect(find.textContaining('"octave": 3'), findsOneWidget);
  });

  testWidgets('演示页：随机音位按钮切换目标', (tester) async {
    await pumpDemo(tester);
    expect(find.textContaining('目标：G4'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.shuffle));
    await tester.pumpAndSettle();
    expect(find.textContaining('目标：'), findsOneWidget);
  });
}