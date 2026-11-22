// 规格: 11 §6.1 —— 视奏模式选择页（S7）widget 测试。
// 覆盖：三种模式切换、单手长度滑杆（4–32 音）、双手列数滑杆（4–12 列）、
// 开始生成、曲目列表进入、阶段 < 2 的提示。
@Tags(['widget'])
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/score_library.dart';
import 'package:sight_reading/features/sight/sight_mode_page.dart';
import 'package:sight_reading/features/sight/sight_session_page.dart';

import '../data/test_db.dart';

class _FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async {}
  @override
  Future<void> playComparison({
    required int answerMidi,
    required int correctMidi,
    Duration gap = const Duration(milliseconds: 400),
  }) async {}
  @override
  Future<void> playSequence(
    List<int> midis, {
    Duration interval = const Duration(milliseconds: 500),
  }) async {}
  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

Future<Database> _seed(WidgetTester tester, {int stage = 0}) async {
  late Database db;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openTestDb();
    await AppStateRepo(db).set('course_stage', '$stage');
  });
  return db;
}

/// 让真实异步（ffi 数据库查询 / asset 读取）落地，再重建 UI。
Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Future<void> _pump(WidgetTester tester, Database db) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // 先把曲目资源读进 rootBundle 缓存：widget 测试的假异步下，资源 IO 只在
  // runAsync 的真实 zone 里能完成；缓存后页面内的 loadString 走微任务即可。
  await tester.runAsync(() async {
    for (final path in builtinScoreAssetPaths) {
      await rootBundle.loadString(path);
    }
  });
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      audioServiceProvider.overrideWithValue(_FakeAudio()),
      clockProvider.overrideWithValue(FakeClock(utcMs: 1000)),
    ],
    child: MaterialApp(home: const SightModePage()),
  ));
  // 阶段 FutureBuilder 走真实 sqflite ffi 查询。
  await _settle(tester);
}

SightSessionPage _session(WidgetTester tester) =>
    tester.widget<SightSessionPage>(find.byType(SightSessionPage));

void main() {
  testWidgets('默认右手、长度 8 音；阶段 <2 显示提示', (tester) async {
    final db = await _seed(tester, stage: 1);
    await _pump(tester, db);

    expect(find.text('视奏训练'), findsOneWidget);
    expect(find.text('右手'), findsOneWidget);
    expect(find.text('左手'), findsOneWidget);
    expect(find.text('双手'), findsOneWidget);
    expect(find.byKey(const Key('sight_stage_hint')), findsOneWidget);
    expect(find.text('建议先练熟更多音位再视奏'), findsOneWidget);
    // 长度滑杆默认 8 音，范围提示为单手口径。
    expect(find.byKey(const Key('sight_length_slider')), findsOneWidget);
    expect(find.text('8 音'), findsOneWidget);
    expect(find.text('一屏约 8–12 音，更多可横向滚动'), findsOneWidget);
    expect(find.byKey(const Key('sight_start')), findsOneWidget);
  });

  testWidgets('阶段 ≥2 不显示提示', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);
    expect(find.byKey(const Key('sight_stage_hint')), findsNothing);
  });

  testWidgets('单手滑杆拖到最大 32 音：开始后生成 32 列', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);

    // 拖到滑杆右端外→值被夹到上限 32。
    await tester.drag(
        find.byKey(const Key('sight_length_slider')), const Offset(600, 0));
    await tester.pump();
    expect(find.text('32 音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sight_start')));
    await tester.pumpAndSettle();

    final page = _session(tester);
    expect(page.source, 'generated');
    expect(page.scoreRef, isNull);
    expect(page.score.mode, SightMode.trebleOnly);
    expect(page.score.columnCount, 32);
  });

  testWidgets('单手滑杆设为中间值 12 音：开始后生成 12 列', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);

    tester
        .widget<Slider>(find.byKey(const Key('sight_length_slider')))
        .onChanged!(12);
    await tester.pump();
    expect(find.text('12 音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sight_start')));
    await tester.pumpAndSettle();

    final page = _session(tester);
    expect(page.score.mode, SightMode.trebleOnly);
    expect(page.score.columnCount, 12);
  });

  testWidgets('双手：默认 8 列，开始后为 grand 8 列', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);

    await tester.tap(find.text('双手'));
    await tester.pump();
    expect(find.byKey(const Key('sight_length_slider')), findsOneWidget);
    expect(find.text('8 列'), findsOneWidget);
    expect(find.text('列数越多，单声部段落越多'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sight_start')));
    await tester.pumpAndSettle();

    final page = _session(tester);
    expect(page.score.mode, SightMode.grand);
    expect(page.score.columnCount, 8);
    expect(page.score.inRange, isTrue);
  });

  testWidgets('双手列数从 8 拖到 12：开始后生成 12 列', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);

    await tester.tap(find.text('双手'));
    await tester.pump();
    expect(find.text('8 列'), findsOneWidget);

    await tester.drag(
        find.byKey(const Key('sight_length_slider')), const Offset(400, 0));
    await tester.pump();
    expect(find.text('12 列'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sight_start')));
    await tester.pumpAndSettle();

    final page = _session(tester);
    expect(page.score.mode, SightMode.grand);
    expect(page.score.columnCount, 12);
    expect(page.score.inRange, isTrue);
    // 12 列下不允许出现整列空白。
    expect(page.score.columns.every((c) => !c.isEmpty), isTrue);
  });

  testWidgets('曲目 tab：6 条内置曲目，点第一条按 score 来源进入', (tester) async {
    final db = await _seed(tester, stage: 3);
    await _pump(tester, db);

    expect(find.byKey(const Key('sight_tab_scores')), findsOneWidget);
    await tester.tap(find.text('曲目'));
    // TabBar 切换动画需要推进假时钟，否则 TabBarView 不建第二页。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester); // rootBundle 读 6 个 JSON

    expect(find.byKey(const Key('sight_score_sr_treble_01')), findsOneWidget);
    expect(find.text('晨光小曲 · 右手 · 12 音'), findsOneWidget);
    expect(find.byKey(const Key('sight_score_sr_grand_02')), findsOneWidget);
    expect(find.text('落日和声 · 双手 · 11 音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sight_score_sr_treble_01')));
    await tester.pumpAndSettle();

    final page = _session(tester);
    expect(page.source, 'score');
    expect(page.scoreRef, 'sr_treble_01');
    expect(page.score.columnCount, 12);
  });
}
