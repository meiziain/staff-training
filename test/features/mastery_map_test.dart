// 规格: 06 §2 S5 / 02 §7.4 —— 掌握地图 widget 测试。
// 种子：22 个 DIRECT 条目 + 五状态示例 + 两周 trial_log + confusion_seed。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/repositories/confusion_seed_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/features/progress/mastery_map_page.dart';

import '../data/test_db.dart';

class _Seed {
  final Database db;
  final int g4ItemId;

  const _Seed(this.db, this.g4ItemId);
}

Future<_Seed> _seed(WidgetTester tester) async {
  late _Seed seed;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    final db = await openTestDb();
    // 同一 isolate 内 ffi :memory: 复用单例连接，先清业务表保证用例隔离。
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
    final items = ItemRepo(db);
    final ids = <int, int>{};
    for (final i in pool) {
      ids[i] = await items.insert(
        Item(
          id: 0,
          type: ItemType.direct,
          payload: DirectPayload(diatonicIndex: i),
          createdAt: 1000 + i,
        ),
      );
    }
    final mastery = MasteryRepo(db);
    await mastery.upsert(
      Mastery(
        itemId: ids[0]!,
        state: ItemState.learning,
        ease: 2.5,
        intervalDays: 1,
        reps: 3,
        hintLevel: 2,
        hintDependency: 0.4,
        rtMedian: 900,
      ),
    );
    await mastery.upsert(
      Mastery(
        itemId: ids[4]!,
        state: ItemState.automated,
        intervalDays: 7,
        reps: 9,
        lapses: 1,
        hintLevel: 0,
        hintDependency: 0.2,
        rtMedian: 820,
      ),
    );
    await mastery.upsert(
      Mastery(
        itemId: ids[5]!,
        state: ItemState.reviewing,
        intervalDays: 4,
        reps: 5,
      ),
    );
    await mastery.upsert(
      Mastery(
        itemId: ids[7]!,
        state: ItemState.relapsed,
        intervalDays: 0,
        reps: 6,
        lapses: 2,
      ),
    );

    final sessionId = await SessionRepo(db).insert(
      Session(
        date: '2026-11-19',
        startedAt: DateTime(2026, 11, 9).millisecondsSinceEpoch,
        plannedCount: 40,
      ),
    );
    // 两周数据：第1周 [correct 无提示, wrong 提示2]，第2周 [correct 无提示]。
    final trials = TrialRepo(db);
    Future<void> add(DateTime at, {required bool correct, required int hint}) =>
        trials.insert(
          Trial(
            sessionId: sessionId,
            itemId: ids[4]!,
            presentedAt: at.millisecondsSinceEpoch,
            answeredAt: at.millisecondsSinceEpoch + 500,
            rtMs: correct ? 820 : 1800,
            correct: correct,
            hintLevelUsed: hint,
            inputSource: InputSource.nameButton,
            contextSnapshot: const ContextSnapshot(
              clef: Clef.treble,
              jitterSeed: 3,
            ),
          ),
        );
    await add(DateTime(2026, 11, 9, 10), correct: true, hint: 0);
    await add(DateTime(2026, 11, 9, 11), correct: false, hint: 2);
    await add(DateTime(2026, 11, 16, 9), correct: true, hint: 0);

    final confusion = ConfusionSeedRepo(db);
    await confusion.bumpPair(0, 3, 1000); // C4 ↔ F4
    await confusion.bumpPair(0, 3, 2000);
    await confusion.bumpPair(4, 7, 3000); // G4 ↔ C5

    seed = _Seed(db, ids[4]!);
  });
  return seed;
}

Future<void> _pump(WidgetTester tester, _Seed seed) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWith((ref) async => seed.db)],
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: const MasteryMapPage(),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump();
}

void main() {
  testWidgets('两行格网：高音 15 格 / 低音 8 格，C4 双标，五状态图例', (tester) async {
    final seed = await _seed(tester);
    await _pump(tester, seed);

    expect(find.byKey(const Key('row_treble')), findsOneWidget);
    expect(find.byKey(const Key('row_bass')), findsOneWidget);
    expect(find.byKey(const Key('cell_treble_0')), findsOneWidget);
    expect(find.byKey(const Key('cell_treble_14')), findsOneWidget);
    expect(find.byKey(const Key('cell_bass_-7')), findsOneWidget);
    expect(find.byKey(const Key('cell_bass_0')), findsOneWidget);
    // C4 两行都出现（双标）。
    expect(find.byKey(const Key('cell_label_treble_0')), findsOneWidget);
    expect(find.byKey(const Key('cell_label_bass_0')), findsOneWidget);
    expect(find.text('C4'), findsNWidgets(2));

    for (final state in ItemState.values) {
      expect(find.byKey(Key('legend_${state.name}')), findsOneWidget);
    }
    expect(find.text('未激活'), findsOneWidget);
    expect(find.text('已自动化'), findsOneWidget);
    expect(find.text('已回退'), findsOneWidget);
  });

  testWidgets('点音位格：展开最近 10 次详情与 mastery 指标', (tester) async {
    final seed = await _seed(tester);
    await _pump(tester, seed);

    await tester.tap(find.byKey(const Key('cell_treble_4')));
    await _settle(tester);

    expect(find.text('G4 详情'), findsOneWidget);
    expect(find.text('820 ms'), findsOneWidget);
    expect(find.text('0.20'), findsOneWidget);
    expect(find.text('7 天'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // lapses
    expect(find.text('最近 10 次作答'), findsOneWidget);
    // 3 条种子试次，正序展示（最新在上）。
    expect(find.byKey(const Key('detail_trial_0')), findsOneWidget);
    expect(find.byKey(const Key('detail_trial_2')), findsOneWidget);
    expect(find.textContaining('✓ · 820 ms'), findsNWidgets(2));
    expect(find.textContaining('✗ · 1800 ms'), findsOneWidget);
    expect(find.textContaining('提示2'), findsOneWidget);
  });

  testWidgets('三条周趋势与易混对列表（count 降序）', (tester) async {
    final seed = await _seed(tester);
    await _pump(tester, seed);

    expect(find.byKey(const Key('trend_hint_dep')), findsOneWidget);
    expect(find.byKey(const Key('trend_retention')), findsOneWidget);
    expect(find.text('提示依赖度'), findsOneWidget);
    expect(find.text('间隔后保持率'), findsOneWidget);
    // 第2周提示依赖 0，保持率 100%。
    expect(find.text('最近一周 0.00（≤0.3 为稳定）'), findsOneWidget);
    expect(find.text('最近一周 100%（无提示正确占比）'), findsOneWidget);

    // ListView 惰性构建：下方卡片需滚动后才进入树。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    expect(find.byKey(const Key('trend_automated')), findsOneWidget);
    expect(find.text('直认自动化数'), findsOneWidget);
    expect(find.text('当前 1/22 · 水平参考线（无历史快照）'), findsOneWidget);

    expect(find.text('C4 ↔ F4'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
    expect(find.text('G4 ↔ C5'), findsOneWidget);
  });
}
