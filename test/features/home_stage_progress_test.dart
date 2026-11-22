// 首页阶段进度卡 widget 测试：阶段0 逐锚点三条件展示 / 阶段1 稳定比例展示。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/features/home/home_page.dart';
import 'package:sight_reading/features/sight/sight_mode_page.dart';

import '../data/test_db.dart';

Future<Database> _seed(WidgetTester tester,
    {required int stage, bool extraUnstableRelation = false}) async {
  late Database db;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openTestDb();
    for (final table in const [
      'trial_log',
      'phrase',
      'mastery',
      'confusion_seed',
      'session',
      'item',
      'app_state',
    ]) {
      await db.delete(table);
    }
    final appState = AppStateRepo(db);
    await appState.set('course_stage', '$stage');
    await appState.set('diagnosis_done', '1');
    await appState.set('active_anchors', '[0,4]');

    final items = ItemRepo(db);
    final mastery = MasteryRepo(db);
    final c4 = await items.insert(Item(
        id: 0,
        type: ItemType.anchor,
        payload: AnchorPayload(diatonicIndex: 0),
        createdAt: 1000));
    final g4 = await items.insert(Item(
        id: 0,
        type: ItemType.anchor,
        payload: AnchorPayload(diatonicIndex: 4),
        createdAt: 1001));
    await mastery.upsert(Mastery(itemId: c4, state: ItemState.learning));
    await mastery.upsert(Mastery(itemId: g4, state: ItemState.learning));

    final sessionId = await SessionRepo(db).insert(Session(
        date: '2026-11-19',
        startedAt: DateTime(2026, 11, 19, 9).millisecondsSinceEpoch,
        plannedCount: 40));
    final trials = TrialRepo(db);
    Future<void> add(int itemId, int i,
            {bool correct = true, int rt = 900, int hint = 0}) =>
        trials.insert(Trial(
          sessionId: sessionId,
          itemId: itemId,
          presentedAt: 1000 + i * 1000,
          answeredAt: 1000 + i * 1000 + rt,
          rtMs: rt,
          correct: correct,
          hintLevelUsed: hint,
          inputSource: InputSource.nameButton,
          contextSnapshot:
              const ContextSnapshot(clef: Clef.treble, jitterSeed: 3),
        ));
    // C4：12 题全对够快零提示 → 窗口 12/20，未满不判达标。
    for (var i = 0; i < 12; i++) {
      await add(c4, i);
    }
    // G4：满窗 20 题，19 对（95%✓）、1 次提示（✗）、无提示中位 900ms（✓）。
    for (var i = 0; i < 18; i++) {
      await add(g4, i);
    }
    await add(g4, 18, correct: false, rt: 1800);
    await add(g4, 19, rt: 5000, hint: 2);

    if (stage >= 1) {
      final rel = await items.insert(Item(
          id: 0,
          type: ItemType.relation,
          payload: RelationPayload.single(
              anchorIndex: 0, direction: 1, steps: 2),
          createdAt: 1002));
      await mastery.upsert(Mastery(
        itemId: rel,
        state: ItemState.reviewing,
        intervalDays: 7,
        hintDependency: 0,
        lastResults: [
          for (var k = 0; k < 5; k++)
            TrialResult(correct: true, rtMs: 900, hintLevel: 0, ts: 2000 + k),
        ],
      ));
      if (extraUnstableRelation) {
        final rel2 = await items.insert(Item(
            id: 0,
            type: ItemType.relation,
            payload: RelationPayload.single(
                anchorIndex: 4, direction: -1, steps: 2),
            createdAt: 1003));
        await mastery.upsert(Mastery(
          itemId: rel2,
          state: ItemState.learning,
          intervalDays: 1,
          hintDependency: 0.4,
          lastResults: [
            for (var k = 0; k < 3; k++)
              TrialResult(correct: true, rtMs: 900, hintLevel: 0, ts: 3000 + k),
            TrialResult(correct: false, rtMs: 900, hintLevel: 0, ts: 3003),
          ],
        ));
      }
    }
  });
  return db;
}

Future<void> _pump(WidgetTester tester, Database db) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: const HomePage(),
    ),
  ));
  // 首页 db → config → _load 三层异步，需多轮 pump 让每层 FutureBuilder 重建。
  for (var k = 0; k < 5; k++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }
}

void main() {
  testWidgets('视奏训练入口：阶段0 带提示，点击进入模式选择页', (tester) async {
    final db = await _seed(tester, stage: 0);
    await _pump(tester, db);

    final entry = find.byKey(const Key('sight_mode_entry'));
    expect(entry, findsOneWidget);
    expect(find.text('视奏训练'), findsOneWidget);
    expect(find.text('无倒计时 · 点一个音走一步'), findsOneWidget);
    expect(find.text('建议先练熟更多音位再视奏'), findsOneWidget);

    await tester.ensureVisible(entry);
    await tester.pump();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(SightModePage), findsOneWidget);
    expect(find.text('生成练习'), findsOneWidget);
  });

  testWidgets('阶段0：徽章行默认收起，点按展开三条件明细', (tester) async {
    final db = await _seed(tester, stage: 0);
    await _pump(tester, db);

    expect(find.byKey(const Key('stage_progress_card')), findsOneWidget);
    expect(find.text('阶段 0 · 锚点建立'), findsOneWidget);
    expect(find.text('全部锚点自动化后，解锁阶段 1：锚点±二度推导'),
        findsOneWidget);
    expect(find.text('推进按达标判定，与练习天数无关'), findsOneWidget);

    // 图例 + 两行锚点徽章：C4 窗口 12/20 全对；G4 满窗 95% 但提示 1 次。
    expect(find.text('点按看明细'), findsOneWidget);
    expect(find.byKey(const Key('anchor_row_C4')), findsOneWidget);
    expect(find.byKey(const Key('anchor_row_G4')), findsOneWidget);
    expect(find.text('100%'), findsOneWidget); // C4 正确率
    expect(find.text('95%'), findsOneWidget); // G4 正确率
    expect(find.text('0.9s'), findsNWidgets(2)); // 两锚点 RT 中位
    expect(find.text('0次'), findsOneWidget); // C4 提示
    expect(find.text('1次'), findsOneWidget); // G4 提示
    expect(find.text('12'), findsOneWidget); // C4 圆环窗口数
    expect(find.text('20'), findsOneWidget); // G4 圆环窗口数
    // 明细默认收起。
    expect(find.textContaining('判定窗口'), findsNothing);

    // 点按 C4 行展开明细。
    await tester.tap(find.byKey(const Key('anchor_row_C4')));
    await tester.pump();
    expect(find.text('判定窗口 12/20 题 · 取最近 20 次作答，加练也计入'),
        findsOneWidget);
    expect(find.text('正确率 100%（需 ≥95%）'), findsOneWidget);
    expect(find.text('提示使用 0 次（需 0）'), findsOneWidget);
  });

  testWidgets('阶段1：稳定比例进度 + 达标提示', (tester) async {
    final db = await _seed(tester, stage: 1);
    await _pump(tester, db);

    expect(find.text('阶段 1 · 锚点±二度'), findsOneWidget);
    expect(find.text('二度关系条目稳定率 ≥80% 后，解锁阶段 2：锚点±三度'),
        findsOneWidget);
    expect(find.text('稳定条目 1/1（需 ≥80%）'), findsOneWidget);
    expect(find.text('已达标，完成会话后进入下一阶段'), findsOneWidget);
    // 阶段1 不再展示锚点三条件明细。
    expect(find.textContaining('判定窗口'), findsNothing);
    // 已稳定核心条目：标签 + 绿色「已稳定」，无徽章。
    expect(find.text('C4→D4'), findsOneWidget);
    expect(find.text('已稳定'), findsOneWidget);
  });

  testWidgets('阶段1：未稳定条目徽章行，点按展开四条件明细', (tester) async {
    final db = await _seed(tester, stage: 1, extraUnstableRelation: true);
    await _pump(tester, db);

    expect(find.text('稳定条目 1/2（需 ≥80%）'), findsOneWidget);
    // 未稳定条目 G4→F4：间隔 1 天✗ / 依赖 40%✗ / 连对 3/5✗。
    expect(find.text('G4→F4'), findsOneWidget);
    expect(find.text('1天'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('3/5'), findsOneWidget);
    expect(find.text('已稳定'), findsOneWidget); // 另一条 C4→D4
    // 明细默认收起。
    expect(find.text('复习间隔 1 天（需 ≥7 天）'), findsNothing);

    await tester.tap(find.text('G4→F4'));
    await tester.pump();
    expect(find.text('已进入间隔复习（当前：学习中）'), findsOneWidget);
    expect(find.text('复习间隔 1 天（需 ≥7 天）'), findsOneWidget);
    expect(find.text('提示依赖 40%（需 ≤30%）'), findsOneWidget);
    expect(find.text('最近 5 次全对（当前 3/5，已积累 4 次）'), findsOneWidget);
  });
}