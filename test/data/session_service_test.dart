// 规格: 05 §1 §3 §9 / 02 §6.4 §7 / 03 §4.3 —— 会话数据装配层测试（ffi 内存库）。
import 'dart:convert';

import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/repositories/confusion_seed_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/phrase_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/data/session_service.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';

import 'test_db.dart';

FakeClock makeClock() => FakeClock(
      utcMs: DateTime.utc(2026, 11, 19, 8).millisecondsSinceEpoch,
      localDate: DateTime(2026, 11, 19),
    );

Future<void> setProgress(Database db,
    {int stage = 0, List<int> anchors = const [0, 4]}) async {
  final s = AppStateRepo(db);
  await s.set('course_stage', '$stage');
  await s.set('active_anchors', jsonEncode(anchors));
  await s.set('diagnosis_done', '1');
}

Future<SessionBundle> buildBundle(
  Database db, {
  int? dailyCount,
  Config config = Config.defaults,
  FakeClock? clock,
}) =>
    SessionSetup.build(
      db: db,
      config: config,
      clock: clock ?? makeClock(),
      rng: SeededRng(42),
      dailyCount: dailyCount,
    );

Trial makeTrial(int sessionId, int itemId, int ts,
        {bool correct = true, int hint = 0}) =>
    Trial(
      sessionId: sessionId,
      itemId: itemId,
      presentedAt: ts,
      answeredAt: ts + 500,
      rtMs: 500,
      correct: correct,
      hintLevelUsed: hint,
      errorType: correct ? null : ErrorType.distance,
      answerPitchClass: correct ? 'G' : 'E',
      inputSource: InputSource.nameButton,
      contextSnapshot: ContextSnapshot(clef: Clef.treble, jitterSeed: ts),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  setUp(() async => db = await openTestDb());
  tearDown(() async => db.close());

  test('build 保障 22 DIRECT + 锚点 ANCHOR + 阶段1 RELATION', () async {
    await setProgress(db, stage: 1);
    await buildBundle(db, dailyCount: 5);
    final items = ItemRepo(db);
    final direct = await items.byType(ItemType.direct);
    expect(direct.length, 22);
    expect(
      direct.map((e) => (e.payload as DirectPayload).diatonicIndex).toSet(),
      pool.toSet(),
    );
    final anchors = await items.byType(ItemType.anchor);
    expect(
      anchors.map((e) => (e.payload as AnchorPayload).diatonicIndex).toSet(),
      {0, 4},
    );
    final rel = await items.byType(ItemType.relation);
    // 锚点 0/4 ±二度且目标∈trebleRange：0+1=1、4+1=5、4-1=3（0-1=-1 出局）。
    expect(
      rel.map((e) => (e.payload as RelationPayload).targetIndex).toSet(),
      {1, 3, 5},
    );
  });

  test('队列长度=配置题量（候选充足）且 session 行已建', () async {
    await setProgress(db, stage: 1);
    final clock = makeClock();
    final b = await buildBundle(db, dailyCount: 5, clock: clock);
    expect(b.plan.entries.length, 5);
    expect(b.engine.queueLength, 5);
    expect(b.engine.sessionId, b.sessionId);
    final s = await SessionRepo(db).byId(b.sessionId);
    expect(s, isNotNull);
    expect(s!.date, '2026-11-19');
    expect(s.startedAt, clock.nowUtcMs());
    expect(s.plannedCount, 5);
    expect(s.doneCount, 0);
  });

  test('dailyCount 缺省取 config.dailyCount', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, config: const Config(dailyCount: 5));
    expect(b.plan.entries.length, 5);
  });

  test('占位 id 替换：条目 id 非 0 且 mastery.item_id 与 item.id 一致', () async {
    await setProgress(db, stage: 1);
    await buildBundle(db, dailyCount: 5);
    final items = await ItemRepo(db).all();
    expect(items, isNotEmpty);
    expect(items.every((it) => it.id > 0), isTrue);
    final ms = await MasteryRepo(db).all();
    expect(ms.length, items.length);
    final ids = items.map((e) => e.id).toSet();
    expect(ms.every((m) => m.itemId > 0 && ids.contains(m.itemId)), isTrue);
  });

  test('DbTrialRecorder.record：trial+mastery+confusion 同事务落库', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final entry = b.plan.entries.first;
    final target = entry.item.targetIndices.last;
    b.recorder.record(
      makeTrial(b.sessionId, entry.item.id, 1000, correct: false),
      entry.mastery.copyWith(reps: 1, lapses: 1),
      (target, 2),
    );
    await b.flush();
    expect(await TrialRepo(db).count(), 1);
    final m = await MasteryRepo(db).byItemId(entry.item.id);
    expect(m!.reps, 1);
    expect(m.lapses, 1);
    final pairs = await ConfusionSeedRepo(db).all();
    expect(pairs.length, 1);
    expect(pairs.first['count'], 1);
    expect(pairs.first['pair_a'], lessThan(pairs.first['pair_b'] as int));
  });

  test('DbTrialRecorder.recordPhrase → phrase 表', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final pid = await ItemRepo(db).insert(Item(
      id: 0,
      type: ItemType.phrase,
      payload: const PhrasePayload(
        noteSequence: [0, 1, 2],
        clefSequence: [Clef.treble, Clef.treble, Clef.treble],
      ),
      createdAt: 100,
    ));
    b.recorder.recordPhrase(PhraseRecord(
      itemId: pid,
      noteSequence: const [0, 1, 2],
      perNoteRt: const [700, 800, 900],
      overallCorrect: 1.0,
      createdAt: 2000,
    ));
    await b.flush();
    final rows = await PhraseRepo(db).byItem(pid);
    expect(rows.length, 1);
    expect(rows.first.overallCorrect, 1.0);
    expect(rows.first.perNoteRt, [700, 800, 900]);
  });

  test('写队列错误在 flush surfaced（事务回滚不污染 trial_log）', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final entry = b.plan.entries.first;
    b.recorder.record(
      makeTrial(b.sessionId, entry.item.id, 1000),
      const Mastery(itemId: 99999), // FK 违约
      null,
    );
    await expectLater(b.flush(), throwsA(anything));
    expect(await TrialRepo(db).count(), 0);
  });

  test('relationHistoryFor 按目标音位过滤且时间升序', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final rel = await ItemRepo(db).byType(ItemType.relation);
    final r1 =
        rel.firstWhere((e) => (e.payload as RelationPayload).targetIndex == 1);
    final r3 =
        rel.firstWhere((e) => (e.payload as RelationPayload).targetIndex == 3);
    b.recorder.record(
        makeTrial(b.sessionId, r1.id, 3000), b.source.masteryOf(r1.id), null);
    b.recorder.record(makeTrial(b.sessionId, r3.id, 1000, correct: false),
        b.source.masteryOf(r3.id), null);
    b.recorder.record(makeTrial(b.sessionId, r1.id, 2000, correct: false),
        b.source.masteryOf(r1.id), null);
    final h = b.source.relationHistoryFor(1);
    expect(h.map((r) => r.ts).toList(), [2500, 3500]);
    expect(h.map((r) => r.correct).toList(), [false, true]);
    expect(b.source.relationHistoryFor(5), isEmpty);
    await b.flush();
    final reloaded = await DbSessionDataSource.load(db);
    expect(reloaded.relationHistoryFor(1).map((r) => r.ts).toList(),
        [2500, 3500]);
    expect(reloaded.relationHistoryFor(3).length, 1);
  });

  test('recentResults 取最近 limit 条并映射 TrialResult', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final anchor = (await ItemRepo(db).byType(ItemType.anchor)).first;
    for (final ts in [1000, 2000, 3000]) {
      b.recorder.record(makeTrial(b.sessionId, anchor.id, ts, hint: 3),
          b.source.masteryOf(anchor.id), null);
    }
    final r = b.source.recentResults(anchor.id, 2);
    expect(r.length, 2);
    expect(r.map((e) => e.ts).toList(), [2500, 3500]);
    expect(r.every((e) => e.rtMs == 500 && e.hintLevel == 3 && e.correct),
        isTrue);
    await b.flush();
    final reloaded = await DbSessionDataSource.load(db);
    expect(reloaded.recentResults(anchor.id, 20).length, 3);
  });

  test('directMasteryOf 命中 DIRECT 条目', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    expect(b.source.directMasteryOf(4)!.state, ItemState.learning);
    expect(b.source.directMasteryOf(0)!.state, ItemState.learning);
    expect(b.source.directMasteryOf(1)!.state, ItemState.inactive);
    expect(b.source.directMasteryOf(99), isNull);
  });

  test('relationItemIdsFor 含目标音位与链中间音', () async {
    final id = await ItemRepo(db).insert(Item(
      id: 0,
      type: ItemType.relation,
      payload: const RelationPayload.chain([
        RelationStep(anchorIndex: 4, direction: 1, steps: 2), // 中间音 5
        RelationStep(anchorIndex: 5, direction: 1, steps: 2), // 目标 6
      ]),
      createdAt: 0,
    ));
    await MasteryRepo(db).upsert(Mastery(itemId: id, state: ItemState.learning));
    final src = await DbSessionDataSource.load(db);
    expect(src.relationItemIdsFor(6), [id]);
    expect(src.relationItemIdsFor(5), [id]);
    expect(src.relationItemIdsFor(4), isEmpty);
  });

  test('saveMastery 同步可读、flush 后落库', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    final id = b.plan.entries.first.item.id;
    b.source.saveMastery(
        b.source.masteryOf(id).copyWith(state: ItemState.reviewing));
    expect(b.source.masteryOf(id).state, ItemState.reviewing);
    await b.flush();
    expect((await MasteryRepo(db).byItemId(id))!.state, ItemState.reviewing);
  });

  test('无到期复习时 noDueReview 透传', () async {
    await setProgress(db, stage: 1);
    final b = await buildBundle(db, dailyCount: 5);
    expect(b.noDueReview, isFalse); // 新建锚点 dueAt=now 入到期
    final future = makeClock().localEndOfDayUtcMs(DateTime(2026, 11, 20)) + 1;
    for (final a in await ItemRepo(db).byType(ItemType.anchor)) {
      final m = await MasteryRepo(db).byItemId(a.id);
      await MasteryRepo(db).upsert(m!.copyWith(dueAt: () => future));
    }
    final b2 = await buildBundle(db, dailyCount: 5);
    expect(b2.noDueReview, isTrue);
    expect(b2.plan.noDueReview, isTrue);
  });

  test('阶段0 锚点未自动化不推进；全自动化后推进到 1 并标记微课', () async {
    await setProgress(db, stage: 0);
    final b0 = await buildBundle(db, dailyCount: 5);
    expect(b0.advance.canAdvance, isFalse);
    expect(await AppStateRepo(db).get('course_stage'), '0');
    expect(
        await AppStateRepo(db).get('micro_lesson_next_session') ?? '0', '0');

    for (final a in await ItemRepo(db).byType(ItemType.anchor)) {
      final m = await MasteryRepo(db).byItemId(a.id);
      await MasteryRepo(db).upsert(m!.copyWith(state: ItemState.automated));
    }
    final b1 = await buildBundle(db, dailyCount: 5);
    expect(b1.advance.canAdvance, isTrue);
    expect(b1.stage, 0, reason: '本次会话仍按读取阶段执行');
    expect(await AppStateRepo(db).get('course_stage'), '1');
    expect(await AppStateRepo(db).get('micro_lesson_next_session'), '1');

    final b2 = await buildBundle(db, dailyCount: 8);
    expect(b2.stage, 1);
    expect(b2.plan.entries.any((e) => e.microLesson), isTrue);
    expect(await AppStateRepo(db).get('micro_lesson_next_session'), '0');
    expect(await AppStateRepo(db).get('course_stage'), '1',
        reason: '阶段1 新 RELATION 未稳定，不继续推进');
  });

  test('阶段>=4 生成 inactive 短句变体备胎，不进常规短句桶（02 §5.4）', () async {
    await setProgress(db, stage: 5);
    // 首次 build 建条目；再把 DIRECT/锚点激活，模拟真实阶段5库（候选充足）。
    await buildBundle(db, dailyCount: 5);
    final now = makeClock().nowUtcMs();
    for (final it in await ItemRepo(db).byType(ItemType.direct)) {
      final m = await MasteryRepo(db).byItemId(it.id);
      await MasteryRepo(db)
          .upsert(m!.copyWith(state: ItemState.learning, dueAt: () => now));
    }
    for (final it in await ItemRepo(db).byType(ItemType.anchor)) {
      final m = await MasteryRepo(db).byItemId(it.id);
      await MasteryRepo(db).upsert(m!.copyWith(state: ItemState.automated));
    }

    final b = await buildBundle(db, dailyCount: 40);
    final phrases = await ItemRepo(db).byType(ItemType.phrase);
    final ms = {for (final m in await MasteryRepo(db).all()) m.itemId: m};
    final inactive = [
      for (final it in phrases)
        if (ms[it.id]?.state == ItemState.inactive) it,
    ];
    final active = [
      for (final it in phrases)
        if (ms[it.id]?.state != ItemState.inactive) it,
    ];
    expect(inactive, isNotEmpty, reason: '本次队列含短句 → 必生成变体备胎');

    // 变体只在错误率超阈值时由 ReexposureScheduler 取用，不进常规短句桶。
    final queueIds = {for (final e in b.plan.entries) e.item.id};
    expect(inactive.any((it) => queueIds.contains(it.id)), isFalse);

    // 变体保持音程型（整体移调）或镜像（音程反向），符合 02 §5.4 换音区口径。
    List<int> diffs(List<int> s) =>
        [for (var i = 1; i < s.length; i++) s[i] - s[i - 1]];
    for (final v in inactive) {
      final vs = (v.payload as PhrasePayload).noteSequence;
      final matched = active.any((a) {
        final aseq = (a.payload as PhrasePayload).noteSequence;
        if (aseq.length != vs.length) return false;
        final da = diffs(aseq);
        final dv = diffs(vs);
        final same = [
          for (var i = 0; i < da.length; i++) dv[i] == da[i],
        ].every((x) => x);
        final mirror = [
          for (var i = 0; i < da.length; i++) dv[i] == -da[i],
        ].every((x) => x);
        return same || mirror;
      });
      expect(matched, isTrue, reason: '变体应是某原句的移调/镜像');
    }
  });

  test('加练模式：未到期条目也进复习桶（「再练一组」不空）', () async {
    await setProgress(db, stage: 1);
    await buildBundle(db, dailyCount: 5); // 建条目（锚点 + ±二度关系）
    final future = makeClock().localEndOfDayUtcMs(DateTime(2026, 11, 20)) + 1;
    // 关系条目：已学过（reps>0）且今天未到期。
    for (final it in await ItemRepo(db).byType(ItemType.relation)) {
      final m = await MasteryRepo(db).byItemId(it.id);
      await MasteryRepo(db).upsert(
          m!.copyWith(reps: 3, state: ItemState.reviewing, dueAt: () => future));
    }
    final normal = await buildBundle(db, dailyCount: 10);
    final extra = await SessionSetup.build(
      db: db,
      config: Config.defaults,
      clock: makeClock(),
      rng: SeededRng(42),
      dailyCount: 10,
      extraPractice: true,
    );
    int reviewCount(SessionBundle b) =>
        b.plan.entries.where((e) => e.segment == QueueSegment.review).length;
    expect(reviewCount(extra), greaterThan(0),
        reason: '加练应把未到期的已学条目纳入复习桶');
    expect(reviewCount(extra), greaterThanOrEqualTo(reviewCount(normal)));
  });
}