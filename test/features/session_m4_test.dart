// 规格: 02 §4.2 直认前置锚点闪现 / §4.1 §4.3 掌握度事件横幅 /
//       §2.2 + 05 §4 锚点重建立微循环 / §5.3 阶段4 短句走向判断。
// M4 会话页 widget 测试：FakeRecorder/FakeSource/FakeDelayer/FakeAudio，
// 引擎与队列直接构造（不走 SessionSetup）；SessionBundle 的 data 层字段
// 用 ffi 内存库装配（仅 flush/退出路径使用），试次断言走 FakeRecorder。
// 坑：闪现倒计时 Timer.periodic(50ms) —— 禁用 pumpAndSettle，全部显式 pump。
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
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/data/repositories/phrase_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/data/session_service.dart';
import 'package:sight_reading/domain/course.dart';
import 'package:sight_reading/domain/mastery.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';
import 'package:sight_reading/domain/session_engine.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart'
    show Delayer;
import 'package:sight_reading/features/session/session_page.dart';
import 'package:sight_reading/ui/feedback_overlay.dart';
import 'package:sight_reading/ui/name_buttons.dart';
import 'package:sight_reading/ui/staff_view.dart';

import '../data/test_db.dart';

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

class FakeRecorder implements TrialRecorder {
  final List<Trial> trials = [];
  final List<Mastery> masteries = [];
  final List<PhraseRecord> phrases = [];
  @override
  void record(Trial trial, Mastery mastery, (int, int)? seedPair) {
    trials.add(trial);
    masteries.add(mastery);
  }

  @override
  void recordPhrase(PhraseRecord record) => phrases.add(record);
}

class FakeSource implements SessionDataSource {
  final Map<int, Mastery> masteries = {};
  final Map<int, List<TrialResult>> relationHistory = {};
  final Map<int, Mastery> directByIndex = {};
  final Map<int, List<int>> relationIdsByIndex = {};

  @override
  Mastery masteryOf(int itemId) =>
      masteries[itemId] ?? Mastery(itemId: itemId, state: ItemState.learning);
  @override
  List<TrialResult> recentResults(int itemId, int limit) =>
      masteries[itemId]?.lastResults ?? const [];
  @override
  List<TrialResult> relationHistoryFor(int targetIndex) =>
      relationHistory[targetIndex] ?? const [];
  @override
  Mastery? directMasteryOf(int diatonicIndex) => directByIndex[diatonicIndex];
  @override
  List<int> relationItemIdsFor(int diatonicIndex) =>
      relationIdsByIndex[diatonicIndex] ?? const [];
  @override
  void saveMastery(Mastery m) => masteries[m.itemId] = m;
}

QueueEntry makeEntry(
  int id,
  int index, {
  ItemType type = ItemType.direct,
  bool prelude = false,
  Mastery? mastery,
  List<int> phraseSeq = const [0, 1, 2],
}) {
  final payload = switch (type) {
    ItemType.direct => DirectPayload(diatonicIndex: index),
    ItemType.anchor => AnchorPayload(diatonicIndex: index),
    ItemType.relation =>
      RelationPayload.single(anchorIndex: 0, direction: 1, steps: 2),
    ItemType.phrase => PhrasePayload(
        noteSequence: phraseSeq,
        clefSequence: List.filled(phraseSeq.length, Clef.treble)),
  };
  return QueueEntry(
    item: Item(id: id, type: type, payload: payload, createdAt: 0),
    mastery: mastery ??
        Mastery(itemId: id, state: ItemState.learning, hintLevel: 0),
    context: ContextSnapshot(
        clef: Clef.treble, jitterSeed: id * 7 + 1, preludeAnchor: prelude),
    segment: QueueSegment.direct,
  );
}

const TrialResult _wrong =
    TrialResult(correct: false, rtMs: 900, hintLevel: 0, ts: 1);

class Harness {
  final SessionBundle bundle;
  final FakeRecorder rec;
  final FakeClock clock;
  final FakeAudio audio;
  final FakeDelayer delayer;
  final Database db;
  Harness(this.bundle, this.rec, this.clock, this.audio, this.delayer, this.db);

  SessionEngine get engine => bundle.engine;
}

Future<Harness> setup(
  WidgetTester tester, {
  required List<QueueEntry> queue,
  int stage = 3,
  FakeSource? src,
  Set<int> anchors = const {0, 4},
}) async {
  final rec = FakeRecorder();
  final clock = FakeClock();
  final audio = FakeAudio();
  final delayer = FakeDelayer();
  final source = src ?? FakeSource();
  late SessionBundle bundle;
  late Database db;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openTestDb();
    final sessionId = await SessionRepo(db).insert(Session(
      date: '2026-11-19',
      startedAt: 0,
      plannedCount: queue.length,
    ));
    final dbSource = await DbSessionDataSource.load(db);
    final dbRecorder = DbTrialRecorder(
      trialRepo: TrialRepo(db),
      phraseRepo: PhraseRepo(db),
      source: dbSource,
    );
    final engine = SessionEngine(
      config: Config.defaults,
      clock: clock,
      rng: rng(42),
      recorder: rec,
      source: source,
      sessionId: sessionId,
      stage: stage,
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
      stage: stage,
      activeAnchors: anchors,
      diagnosisDone: true,
      source: dbSource,
      recorder: dbRecorder,
      advance: AdvanceDecision(
        currentStage: stage,
        ratio: 0,
        canAdvance: false,
        nextStage: stage,
        microLessonNextSession: false,
      ),
    );
  });
  return Harness(bundle, rec, clock, audio, delayer, db);
}

Future<void> pumpPage(WidgetTester tester, Harness h,
    {Size size = const Size(390, 900)}) async {
  // 默认手机单列布局；平板双栏见 session_landscape_test。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => h.db),
      configProvider.overrideWith((ref) async => Config.defaults),
      audioServiceProvider.overrideWithValue(h.audio),
      clockProvider.overrideWithValue(h.clock),
    ],
    child: MaterialApp(
      home: SessionPage(bundle: h.bundle, delayer: h.delayer),
    ),
  ));
  await tester.pump(); // 构建
  await tester.pump(); // post-frame onset（前置闪现时不记 onset）
}

bool buttonsEnabled(WidgetTester tester) =>
    tester.widget<NameButtons>(find.byType(NameButtons)).enabled;

void main() {
  testWidgets('直认前置锚点：闪现期禁用，500ms 后可作答，onset 不含前置时间',
      (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 4, prelude: true),
      makeEntry(2, 5),
    ]);
    await pumpPage(tester, h);

    // 前置期：呈现锚点（activeAnchors.first=0）而非目标音，按钮禁用。
    expect(h.engine.phase, SessionPhase.presenting);
    expect(buttonsEnabled(tester), isFalse);
    final preludeStaff = tester.widget<StaffView>(find.byType(StaffView));
    expect(preludeStaff.anchorOverlay?.index, 0);
    expect(preludeStaff.anchorOverlay?.ghost, isTrue); // 空心参照，区别于题目
    expect(preludeStaff.positions, isEmpty);
    // 闪现期有说明文案，避免被误认为「二度题闪现变锚点题」的 bug。
    expect(find.byKey(const Key('prelude_caption')), findsOneWidget);
    await tester.tap(find.text('G'));
    await tester.pump();
    expect(h.rec.trials, isEmpty); // 前置期作答无效

    delayerElapse(h, 500);
    await tester.pump();
    await tester.pump(); // 目标音 post-frame onset
    await tester.pump();
    expect(h.engine.phase, SessionPhase.awaitingAnswer);
    expect(buttonsEnabled(tester), isTrue);
    final staff = tester.widget<StaffView>(find.byType(StaffView));
    expect(staff.positions, [4]);
    expect(staff.anchorOverlay, isNull);
    expect(find.byKey(const Key('prelude_caption')), findsNothing);

    h.clock.monoMs += 700;
    await tester.tap(find.text('G'));
    await tester.pump();
    expect(h.rec.trials.single.rtMs, 700); // RT 不含前置 500ms

    // 下一题 preludeAnchor=false：无前置，直接可作答。
    delayerElapse(h, 600);
    await tester.pump();
    delayerElapse(h, 800);
    await tester.pump();
    await tester.pump();
    expect(h.engine.current!.item.id, 2);
    expect(h.engine.phase, SessionPhase.awaitingAnswer);
    expect(buttonsEnabled(tester), isTrue);
    await exitSession(tester, h);
  });

  testWidgets('直认前置锚点：目标音已呈现后切后台恢复，不重放锚点', (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 4, prelude: true),
      makeEntry(2, 5),
    ]);
    await pumpPage(tester, h);
    delayerElapse(h, 500);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(h.engine.phase, SessionPhase.awaitingAnswer);
    expect(tester.widget<StaffView>(find.byType(StaffView)).positions, [4]);

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(h.engine.phase, SessionPhase.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final staff = tester.widget<StaffView>(find.byType(StaffView));
    expect(staff.anchorOverlay, isNull); // 不重放参照锚点
    expect(staff.positions, [4]);
    expect(find.byKey(const Key('prelude_caption')), findsNothing);
    expect(h.engine.phase, SessionPhase.awaitingAnswer);
    await exitSession(tester, h);
  });

  testWidgets('晋升事件横幅：直认激活 D4，2s 后消失', (tester) async {
    final src = FakeSource()
      ..directByIndex[1] = const Mastery(itemId: 99, state: ItemState.inactive)
      ..relationHistory[1] = const [
        TrialResult(correct: true, rtMs: 800, hintLevel: 0, ts: 1),
        TrialResult(correct: true, rtMs: 800, hintLevel: 0, ts: 2),
        TrialResult(correct: true, rtMs: 800, hintLevel: 0, ts: 3),
        TrialResult(correct: true, rtMs: 800, hintLevel: 0, ts: 4),
      ];
    final h = await setup(tester, queue: [
      makeEntry(1, 1, type: ItemType.relation),
      makeEntry(2, 5),
    ], src: src);
    await pumpPage(tester, h);

    h.clock.monoMs += 800;
    await tester.tap(find.text('D')); // 目标 D4，第 5 次全对零提示 → 晋升
    await tester.pump();
    expect(h.engine.events.whereType<PromotionEvent>(), isNotEmpty);
    expect(find.byKey(const Key('mastery_banner')), findsOneWidget);
    expect(find.text('直认激活：D4'), findsOneWidget);

    delayerElapse(h, 2000);
    await tester.pump();
    expect(find.byKey(const Key('mastery_banner')), findsNothing);
  });

  testWidgets('回退事件横幅：直认回退 G4，回到关系练习', (tester) async {
    final src = FakeSource()..relationIdsByIndex[4] = [5];
    final h = await setup(tester, queue: [
      makeEntry(1, 4,
          mastery: const Mastery(
            itemId: 1,
            state: ItemState.learning,
            hintLevel: 0,
            lastResults: [_wrong, _wrong],
          )),
      makeEntry(2, 5),
    ], src: src);
    await pumpPage(tester, h);

    await tester.tap(find.text('C')); // 目标 G4，第 3 连错 → 回退
    await tester.pump();
    expect(h.engine.events.whereType<RelapseEvent>(), isNotEmpty);
    expect(find.text('直认回退：G4，回到关系练习'), findsOneWidget);
    expect(src.masteries[5]?.hintLevel, 3); // 关系条目重置提示级
    expect(src.masteries[5]?.state, ItemState.learning);
  });

  testWidgets('锚点重建立：展示卡 3s → 5 题不限时慢练（不落库）→ 恢复队列',
      (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 4,
          type: ItemType.anchor,
          mastery: const Mastery(
            itemId: 1,
            state: ItemState.learning,
            hintLevel: 0,
            lastResults: [_wrong, _wrong],
          )),
      makeEntry(2, 5),
    ]);
    await pumpPage(tester, h);
    expect(find.byType(LinearProgressIndicator), findsOneWidget); // 限时条

    await tester.tap(find.text('C')); // 第 3 连错 → RebuildTriggerEvent
    await tester.pump();
    expect(h.engine.events.whereType<RebuildTriggerEvent>(), isNotEmpty);
    expect(find.text('锚点重建立：进入慢速练习'), findsOneWidget);

    delayerElapse(h, 600); // 反馈标记
    await tester.pump();
    delayerElapse(h, 800); // 空屏 → 展示卡
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('rebuild_card')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(buttonsEnabled(tester), isFalse);
    expect(h.audio.notes, contains(midiOf(4))); // 展示卡播音
    final cardStaff = tester.widget<StaffView>(find.byType(StaffView));
    expect(cardStaff.anchorOverlay?.index, 4); // 锚点常亮 + 音名标注
    expect(cardStaff.anchorOverlay?.label, 'G4');

    delayerElapse(h, 3000);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('rebuild_card')), findsNothing);
    expect(find.byKey(const Key('rebuild_practice')), findsOneWidget);
    expect(find.text('慢速练习 1/5（不限时）'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing); // 不限时
    expect(buttonsEnabled(tester), isTrue);

    // 5 题慢练：第 2 题答错验证对比音与 ✗ 反馈；全部不落库。
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text(i == 1 ? 'C' : 'G'));
      await tester.pump();
      expect(find.byType(FeedbackOverlay), findsOneWidget);
      expect(buttonsEnabled(tester), isFalse); // 本地反馈期禁用
      delayerElapse(h, 600);
      await tester.pump();
      await tester.pump();
    }
    await tester.pump(); // 恢复队列当前题 onset

    expect(h.engine.position, 1);
    expect(h.engine.current!.item.id, 2);
    expect(h.engine.phase, SessionPhase.awaitingAnswer);
    expect(h.rec.trials.length, 1); // 慢练 5 题不落库
    expect(h.audio.notes, contains(midiOf(7))); // 慢练答错对比音（C5）
    expect(buttonsEnabled(tester), isTrue);
    await exitSession(tester, h);
  });

  testWidgets('阶段4 短句：走向判断三按钮 → 判断对错展示 → 逐音命名',
      (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 0, type: ItemType.phrase), // C4 D4 E4 → 上行
      makeEntry(2, 5),
    ], stage: 4);
    await pumpPage(tester, h);

    expect(find.byKey(const Key('direction_up')), findsOneWidget);
    expect(find.byKey(const Key('direction_down')), findsOneWidget);
    expect(find.byKey(const Key('direction_mixed')), findsOneWidget);
    expect(buttonsEnabled(tester), isFalse); // 判断期不可逐音作答
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(h.rec.trials, isEmpty);

    h.clock.monoMs += 1000; // 走向判断耗时不计入首音 RT
    await tester.tap(find.byKey(const Key('direction_up')));
    await tester.pump();
    expect(find.text('走向判断：正确'), findsOneWidget);
    expect(buttonsEnabled(tester), isFalse);

    delayerElapse(h, 600);
    await tester.pump();
    await tester.pump(); // 重新 onset
    expect(find.byKey(const Key('direction_result')), findsNothing);
    expect(buttonsEnabled(tester), isTrue);

    h.clock.monoMs += 500;
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(h.rec.trials.single.rtMs, 500); // onset 已重置
    delayerElapse(h, 600);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('D'));
    await tester.pump();
    delayerElapse(h, 600);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('E'));
    await tester.pump();
    expect(h.rec.phrases.length, 1);
    delayerElapse(h, 2000); // 整句标记
    await tester.pump();
    await tester.pump();
    expect(h.engine.position, 1); // 短句完成进入下一题
    await exitSession(tester, h);
  });

  testWidgets('阶段4 走向判断错误：展示 ✗ 后进入逐音', (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 0, type: ItemType.phrase), // 上行
      makeEntry(2, 5),
    ], stage: 4);
    await pumpPage(tester, h);
    await tester.tap(find.byKey(const Key('direction_down')));
    await tester.pump();
    expect(find.text('走向判断：错误'), findsOneWidget);
    delayerElapse(h, 600);
    await tester.pump();
    await tester.pump();
    expect(buttonsEnabled(tester), isTrue);
    expect(h.rec.trials, isEmpty); // 走向判断不落库
  });

  testWidgets('阶段5 短句：不显示走向判断，直接逐音命名', (tester) async {
    final h = await setup(tester, queue: [
      makeEntry(1, 0, type: ItemType.phrase, phraseSeq: [0, 1, 2, 1]),
      makeEntry(2, 5),
    ], stage: 5);
    await pumpPage(tester, h);
    expect(find.byKey(const Key('direction_up')), findsNothing);
    expect(find.byKey(const Key('direction_down')), findsNothing);
    expect(find.byKey(const Key('direction_mixed')), findsNothing);
    expect(buttonsEnabled(tester), isTrue);
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(h.rec.trials.length, 1);
  });
}

void delayerElapse(Harness h, int ms) => h.delayer.elapse(ms);

/// 退出会话：取消闪现倒计时 Timer（避免测试结束时 pending timer）。
Future<void> exitSession(WidgetTester tester, Harness h) async {
  await tester.tap(find.byKey(const Key('session_exit')));
  await tester.pump();
  await tester.tap(find.text('退出'));
  await tester.pump();
  await tester.runAsync(() async {
    await h.bundle.flush();
  });
}