// 规格: 06 §3 平板适配 —— 横屏（≥600dp 且宽>高）双栏：左 55% 谱表 / 右 45% 作答；
// 竖屏与窄分屏（<600dp）单列。断言以控件实际几何位置判定，不看 widget 树结构。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/data/repositories/phrase_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/data/session_service.dart';
import 'package:sight_reading/domain/course.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';
import 'package:sight_reading/domain/session_engine.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart'
    show Delayer;
import 'package:sight_reading/features/session/session_page.dart';
import 'package:sight_reading/ui/name_buttons.dart';
import 'package:sight_reading/ui/staff_view.dart';

import '../data/test_db.dart';

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

class NoopDelayer implements Delayer {
  @override
  Future<void> delay(Duration d) => Future<void>.value();
}

class FakeRecorder implements TrialRecorder {
  @override
  void record(Trial trial, Mastery mastery, (int, int)? seedPair) {}
  @override
  void recordPhrase(PhraseRecord record) {}
}

class FakeSource implements SessionDataSource {
  @override
  Mastery masteryOf(int itemId) =>
      Mastery(itemId: itemId, state: ItemState.learning);
  @override
  List<TrialResult> recentResults(int itemId, int limit) => const [];
  @override
  List<TrialResult> relationHistoryFor(int targetIndex) => const [];
  @override
  Mastery? directMasteryOf(int diatonicIndex) => null;
  @override
  List<int> relationItemIdsFor(int diatonicIndex) => const [];
  @override
  void saveMastery(Mastery m) {}
}

QueueEntry directEntry(int id, int index) => QueueEntry(
      item: Item(
        id: id,
        type: ItemType.direct,
        payload: DirectPayload(diatonicIndex: index),
        createdAt: 0,
      ),
      mastery: Mastery(itemId: id, state: ItemState.learning),
      context: const ContextSnapshot(clef: Clef.treble, jitterSeed: 3),
      segment: QueueSegment.direct,
    );

Future<Database> pumpPage(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late Database db;
  late SessionBundle bundle;
  final clock = FakeClock();
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openTestDb();
    final sessionId = await SessionRepo(db).insert(Session(
      date: '2026-11-19',
      startedAt: 0,
      plannedCount: 2,
    ));
    final source = await DbSessionDataSource.load(db);
    final queue = [directEntry(1, 4), directEntry(2, 5)];
    final engine = SessionEngine(
      config: Config.defaults,
      clock: clock,
      rng: rng(1),
      recorder: FakeRecorder(),
      source: source,
      sessionId: sessionId,
      stage: 3,
      mode: InputMode.nameButtons,
      queue: queue,
      sessionEndTs: 9999999,
    );
    bundle = SessionBundle(
      engine: engine,
      plan: QueuePlan(
        entries: queue,
        noDueReview: false,
        carryoverIds: const {},
        c2Relaxed: false,
      ),
      sessionId: sessionId,
      stage: 3,
      activeAnchors: const {0, 4},
      diagnosisDone: true,
      source: source,
      recorder: DbTrialRecorder(
        trialRepo: TrialRepo(db),
        phraseRepo: PhraseRepo(db),
        source: source,
      ),
      advance: const AdvanceDecision(
        currentStage: 3,
        ratio: 0,
        canAdvance: false,
        nextStage: 3,
        microLessonNextSession: false,
      ),
    );
  });

  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      configProvider.overrideWith((ref) async => Config.defaults),
      audioServiceProvider.overrideWithValue(FakeAudio()),
      clockProvider.overrideWithValue(clock),
    ],
    child: MaterialApp(
      home: SessionPage(bundle: bundle, delayer: NoopDelayer()),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return db;
}

void main() {
  testWidgets('横屏 1024x768：左谱表 / 右作答（双栏）', (tester) async {
    await pumpPage(tester, size: const Size(1024, 768));
    final staff = tester.getRect(find.byType(StaffView));
    final keys = tester.getRect(find.byType(NameButtons));
    // 左右分栏：作答区整体在谱表区右侧，且两者有纵向重叠。
    expect(keys.left, greaterThanOrEqualTo(staff.right - 1));
    expect(keys.top, lessThan(staff.bottom));
    // 左栏约占 55%：谱表区宽度应超过总宽的一半。
    expect(staff.width, greaterThan(1024 * 0.5));
  });

  testWidgets('竖屏 390x844：单列（作答在谱表下方）', (tester) async {
    await pumpPage(tester, size: const Size(390, 844));
    final staff = tester.getRect(find.byType(StaffView));
    final keys = tester.getRect(find.byType(NameButtons));
    expect(keys.top, greaterThanOrEqualTo(staff.bottom - 1));
    expect(keys.left, lessThan(staff.right));
  });

  testWidgets('窄分屏 560x900（<600dp）：走单列，不双栏', (tester) async {
    await pumpPage(tester, size: const Size(560, 900));
    final staff = tester.getRect(find.byType(StaffView));
    final keys = tester.getRect(find.byType(NameButtons));
    expect(keys.top, greaterThanOrEqualTo(staff.bottom - 1));
  });
}
