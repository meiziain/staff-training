// T06 验收：开场 3 秒倒计时（期间忽略输入）与拍号选择（时间维度）。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/models/sight_time_signature.dart';
import 'package:sight_reading/features/sight/sight_mode_page.dart';
import 'package:sight_reading/features/sight/sight_session_page.dart';
import 'package:sight_reading/ui/grand_staff_view.dart';
import 'package:sight_reading/ui/virtual_keyboard.dart';

import 'sight_session_page_test.dart' as base;

Future<void> pumpCountdownPage(
  WidgetTester tester, {
  required FakeClock clock,
  required base.ManualBeatScheduler scheduler,
  required int countdownSeconds,
  SightTimeSignature timeSignature = SightTimeSignature.common4_4,
  int quartersPerMinute = 50,
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioServiceProvider.overrideWithValue(base.FakeAudio()),
        clockProvider.overrideWithValue(clock),
      ],
      child: MaterialApp(
        home: SightSessionPage(
          score: base.trebleScore([0, 1]),
          beatScheduler: scheduler,
          countdownSeconds: countdownSeconds,
          timeSignature: timeSignature,
          quartersPerMinute: quartersPerMinute,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('开场倒计时', () {
    testWidgets('3→2→1 期间谱面与键盘可见但输入被忽略', (tester) async {
      final clock = FakeClock();
      final scheduler = base.ManualBeatScheduler();
      await pumpCountdownPage(
        tester,
        clock: clock,
        scheduler: scheduler,
        countdownSeconds: 3,
      );

      expect(find.byKey(const Key('sight_countdown')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.byType(GrandStaffView), findsOneWidget);
      expect(find.byType(VirtualKeyboard), findsOneWidget);
      expect(find.text('已完成 0/2'), findsOneWidget);

      // 倒计时期间点屏：不回放、不入槽、不推进。
      await base.tapNote(tester, 0);
      expect(find.text('已完成 0/2'), findsOneWidget);
      expect(base.staff(tester).upperCursorColumn, 0);

      // 三次 1 秒 task 后才开始排第一拍。
      scheduler.fireAll();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      scheduler.fireAll();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      scheduler.fireAll();
      await tester.pump();
      expect(find.byKey(const Key('sight_countdown')), findsNothing);
      expect(scheduler.nextDelayMs, 1200, reason: 'L1@50bpm 4/4 引导拍 1200ms');

      await base.answerBeat(tester, clock, scheduler, 0);
      await base.answerBeat(tester, clock, scheduler, 1);
      expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    });

    testWidgets('countdownSeconds=0 直接进入引导拍，无倒计时数字', (tester) async {
      final clock = FakeClock();
      final scheduler = base.ManualBeatScheduler();
      await pumpCountdownPage(
        tester,
        clock: clock,
        scheduler: scheduler,
        countdownSeconds: 0,
      );
      expect(find.byKey(const Key('sight_countdown')), findsNothing);
      expect(scheduler.nextDelayMs, 1200);
      await base.answerBeat(tester, clock, scheduler, 0);
      expect(base.staff(tester).upperCursorColumn, 1);
    });
  });

  group('拍号只影响时间', () {
    testWidgets('4/8 引导拍与每拍时长均为 4/4 的一半，音高序列不变', (tester) async {
      final clock = FakeClock();
      final scheduler = base.ManualBeatScheduler();
      await pumpCountdownPage(
        tester,
        clock: clock,
        scheduler: scheduler,
        countdownSeconds: 0,
        timeSignature: const SightTimeSignature(4, 8),
      );
      expect(scheduler.nextDelayMs, 600, reason: 'L1@50bpm 4/8 引导拍 600ms');
      final columns = base.staff(tester).columns;
      expect(columns.map((c) => c.upper).toList(), [0, 1]);

      await base.answerBeat(tester, clock, scheduler, 0);
      expect(scheduler.nextDelayMs, 600, reason: '下一拍同样减半');
      await base.answerBeat(tester, clock, scheduler, 1);
      expect(find.byKey(const Key('sight_summary')), findsOneWidget);
      expect(find.textContaining('4/8'), findsOneWidget);
    });
  });

  group('模式页拍号下拉', () {
    testWidgets('选择 4/8 后开始练习，SightSessionPage 收到该拍号', (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioServiceProvider.overrideWithValue(base.FakeAudio()),
            clockProvider.overrideWithValue(FakeClock(utcMs: 1000)),
          ],
          child: const MaterialApp(home: SightModePage()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('sight_timesig_selector')), findsOneWidget);
      expect(find.byKey(const Key('sight_timesig_hint')), findsOneWidget);
      expect(find.text('分子=每小节拍数，分母=以什么音符为一拍'), findsOneWidget);
      expect(find.text('分母 8 比 4/4 快一倍'), findsNothing);
      expect(find.byKey(const Key('sight_tempo_selector')), findsOneWidget);
      expect(find.byKey(const Key('sight_tempo_hint')), findsOneWidget);
      expect(find.text('速度以每分钟四分音符计，不随拍号变化'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sight_timesig_selector')));
      await tester.pump();
      await tester.tap(find.text('4/8').last);
      await tester.pump();
      expect(
        tester
            .widget<DropdownButton<SightTimeSignature>>(
              find.byKey(const Key('sight_timesig_selector')),
            )
            .value,
        const SightTimeSignature(4, 8),
      );

      await tester.tap(find.byKey(const Key('sight_start')));
      await tester.pumpAndSettle();
      final page = tester.widget<SightSessionPage>(find.byType(SightSessionPage));
      expect(page.timeSignature, const SightTimeSignature(4, 8));
      expect(page.quartersPerMinute, 60, reason: '未改速度时默认 ♩=60');
    });

    testWidgets('选择 ♩=96 后独立传给视奏页，不随拍号变化', (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioServiceProvider.overrideWithValue(base.FakeAudio()),
            clockProvider.overrideWithValue(FakeClock(utcMs: 1000)),
          ],
          child: const MaterialApp(home: SightModePage()),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('sight_tempo_selector')));
      await tester.pump();
      await tester.tap(find.text('♩ = 96').last);
      await tester.pump();
      expect(find.text('♩ = 96 每分钟四分音符'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sight_start')));
      await tester.pumpAndSettle();
      final page = tester.widget<SightSessionPage>(find.byType(SightSessionPage));
      expect(page.quartersPerMinute, 96);
      expect(page.timeSignature, SightTimeSignature.common4_4);
    });
  });

  group('完成页速度显示', () {
    testWidgets('副标题显示 ♩=96 与拍号', (tester) async {
      final clock = FakeClock();
      final scheduler = base.ManualBeatScheduler();
      await pumpCountdownPage(
        tester,
        clock: clock,
        scheduler: scheduler,
        countdownSeconds: 0,
        quartersPerMinute: 96,
      );
      await base.answerBeat(tester, clock, scheduler, 0);
      await base.answerBeat(tester, clock, scheduler, 1);
      expect(find.byKey(const Key('sight_summary')), findsOneWidget);
      expect(find.textContaining('♩=96'), findsOneWidget);
      expect(find.textContaining('4/4'), findsOneWidget);
    });
  });
}
