// 键盘模式计时宽限（手机）：按下不计时；滑动抬手/八度跳转才开始倒计时
// （上限 keyLimitGraceMs 强制启动）；平板全宽键盘不等待。
// RT 口径：呈现起算，扣除导航（滑动/跳转）耗时；宽限期显示实时正计时。
// 复用 e2e 的 FakeAudio/FakeDelayer 口径（本地复制，避免跨文件私有依赖）。
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
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart'
    show Delayer;
import 'package:sight_reading/features/session/session_page.dart';
import 'package:sight_reading/ui/virtual_keyboard.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async {}
  @override
  Future<void> playComparison(
      {required int answerMidi,
      required int correctMidi,
      Duration gap = const Duration(milliseconds: 400)}) async {}
  @override
  Future<void> playSequence(List<int> midis,
      {Duration interval = const Duration(milliseconds: 500)}) async {}
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

const _keyboardConfig = Config(inputMode: InputMode.virtualKey);

/// 手机视口：键盘需滚动，宽限逻辑才生效（默认 800x600 是平板）。
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 推进假时钟 + 帧（RT/导航计时与 Timer 同步前进）。
Future<void> _elapse(WidgetTester tester, FakeClock clock, int ms) async {
  clock.advance(Duration(milliseconds: ms));
  await tester.pump(Duration(milliseconds: ms));
}

Future<(dynamic, SessionBundle)> _setup(
    WidgetTester tester, FakeClock clock) async {
  late final dynamic db;
  late final SessionBundle bundle;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    final appState = AppStateRepo(db);
    await appState.set('active_anchors', '[0,4]');
    await appState.set('course_stage', '1');
    await appState.set('diagnosis_done', '1');
    bundle = await SessionSetup.build(
      db: db,
      config: _keyboardConfig,
      clock: clock,
      rng: rng(1),
      dailyCount: 20,
    );
  });
  return (db, bundle);
}

Future<void> _pump(WidgetTester tester, dynamic db, SessionBundle bundle,
    FakeDelayer delayer, FakeClock clock) async {
  // 预热 config：SessionPage.initState 即记 onset，若 configProvider 尚未
  // 完成加载会回退默认（音名模式），宽限逻辑不生效。真实 App 中首页早已加载。
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWith((ref) async => db),
    configProvider.overrideWith((ref) async => _keyboardConfig),
    audioServiceProvider.overrideWithValue(FakeAudio()),
    clockProvider.overrideWithValue(clock),
  ]);
  addTearDown(container.dispose);
  await container.read(configProvider.future);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: SessionPage(bundle: bundle, delayer: delayer),
    ),
  ));
  await tester.pump(); // 构建
  await tester.pump(); // post-frame onset
}

/// 收尾：落库 flush + 卸载页面（dispose 取消宽限/倒计时 Timer，避免测试不变量失败）。
Future<void> _teardown(WidgetTester tester, SessionBundle bundle) async {
  await tester.runAsync(() => bundle.flush());
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('首题视口定位到目标八度：C4 在左侧，B3/G4 可见', (tester) async {
    _phone(tester);
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    expect(bundle.engine.current!.item.targetIndices.last, 0); // 首题 C4

    // 初始视口从 B3 起（C4 八度左移一键），不再停在 C3。
    final c4 = tester.getTopLeft(find.byKey(const ValueKey('key_60')));
    expect(c4.dx, closeTo(VirtualKeyboard.minKeyWidth, 0.01));
    final b3 = tester.getTopLeft(find.byKey(const ValueKey('key_59')));
    expect(b3.dx, greaterThanOrEqualTo(0));
    final g4 = tester.getTopLeft(find.byKey(const ValueKey('key_67')));
    expect(g4.dx, greaterThan(0));
    expect(g4.dx, lessThan(390));
    await _teardown(tester, bundle);
  });

  testWidgets('按住不动不计时；滑动抬手才开始倒计时，超时判罚照常', (tester) async {
    _phone(tester);
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    final engine = bundle.engine;
    expect(engine.current!.item.type, ItemType.anchor); // 热身锚点=闪现题

    // 未触碰：2s 不超时，提示与正计时可见。
    expect(find.byKey(const Key('limit_grace_hint')), findsOneWidget);
    await _elapse(tester, clock, 2000);
    expect(engine.doneCount, 0);
    expect(find.text('2.0s'), findsOneWidget); // 实时 RT 正计时

    // 按住琴键不动 1s：仍不计时（总 3s < 5s 上限）。
    final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('key_60'))));
    await _elapse(tester, clock, 1000);
    expect(find.byKey(const Key('limit_grace_hint')), findsOneWidget);

    // 转为滑动：过程中仍不判超时，抬手（定位完成）才启动倒计时。
    await g.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(find.byKey(const Key('limit_grace_hint')), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(find.byKey(const Key('limit_grace_hint')), findsNothing);
    expect(engine.doneCount, 0); // 滑动不提交

    // 锚点默认档 3s 后超时。
    await _elapse(tester, clock, 3100);
    expect(engine.doneCount, 1);
    expect(engine.lastTrial!.correct, isFalse);
    await _teardown(tester, bundle);
  });

  testWidgets('一直不触碰：5s 上限后倒计时强制启动并超时', (tester) async {
    _phone(tester);
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    final engine = bundle.engine;

    await _elapse(tester, clock, 5000); // 宽限上限到
    expect(find.byKey(const Key('limit_grace_hint')), findsNothing);
    expect(engine.doneCount, 0); // 倒计时刚启动，还未超时

    await _elapse(tester, clock, 3100);
    expect(engine.doneCount, 1);
    expect(engine.lastTrial!.correct, isFalse);
    await _teardown(tester, bundle);
  });

  testWidgets('八度跳转后点键作答：正常判对', (tester) async {
    _phone(tester);
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    final engine = bundle.engine;
    final target = engine.current!.item.targetIndices.last;

    await _elapse(tester, clock, 2000); // 找音 2s，仍在宽限
    expect(find.byKey(const Key('limit_grace_hint')), findsOneWidget);
    // 跳转 C4 区：目标 C4/G4 均落入视口；跳转即开始倒计时。
    await tester.tap(find.byKey(const ValueKey('octave_jump_C4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('limit_grace_hint')), findsNothing);
    await tester.tap(find.byKey(ValueKey('key_${midiOf(target)}')));
    await tester.pump();
    expect(engine.doneCount, 1);
    expect(engine.lastTrial!.correct, isTrue);
    await _teardown(tester, bundle);
  });

  testWidgets('滑动耗时不计 RT；反馈与空屏间隙显示反应时', (tester) async {
    _phone(tester);
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    final engine = bundle.engine;
    expect(engine.current!.item.targetIndices.last, 0); // 热身首题 C4

    await _elapse(tester, clock, 1000); // 思考 1s，计入 RT
    final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('key_60'))));
    await _elapse(tester, clock, 500); // 按住不动：不算导航
    await g.moveBy(const Offset(-60, 0)); // 判定滑动
    await tester.pump();
    await _elapse(tester, clock, 800); // 滑动 800ms，扣除
    // 滑动中实时 RT 冻结在 1.5s（1.0 思考 + 0.5 按住）。
    expect(find.text('1.5s'), findsOneWidget);
    await g.up(); // 导航结算 800ms，倒计时启动
    await tester.pump();
    await _elapse(tester, clock, 300);
    await tester.tap(find.byKey(const ValueKey('key_60')));
    await tester.pump();
    expect(engine.doneCount, 1);
    expect(engine.lastTrial!.correct, isTrue);
    expect(engine.lastTrial!.rtMs, 1800); // 2600 经过 - 800 导航

    // 反馈标记期显示 RT。
    expect(find.byKey(const Key('feedback_rt')), findsOneWidget);
    expect(find.text('反应 1.8s'), findsOneWidget);
    // 空屏间隙继续显示（延时续段在帧后执行，需再 pump 一帧渲染）。
    delayer.elapse(600);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('blank_rt')), findsOneWidget);
    expect(find.text('反应 1.8s'), findsOneWidget);
    await _teardown(tester, bundle);
  });

  testWidgets('平板全宽键盘：不进入宽限，立即正常倒计时', (tester) async {
    // 默认 800x600 视口 = 平板，键盘无需滚动。
    final clock = FakeClock();
    final (db, bundle) = await _setup(tester, clock);
    final delayer = FakeDelayer();
    await _pump(tester, db, bundle, delayer, clock);
    final engine = bundle.engine;

    expect(find.byKey(const Key('limit_grace_hint')), findsNothing);
    await _elapse(tester, clock, 3100);
    expect(engine.doneCount, 1);
    expect(engine.lastTrial!.correct, isFalse);
    await _teardown(tester, bundle);
  });
}