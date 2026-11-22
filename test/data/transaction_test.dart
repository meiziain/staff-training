// 规格: 08 P3 数据部分 / 03 §4.3 —— mastery 与 trial 同事务（崩溃一致性）；
// trial_log 只增不改。
import 'package:test/test.dart';

import 'package:sight_reading/data/repositories/confusion_seed_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';

import 'test_db.dart';

Trial makeTrial(int sessionId, int itemId, int ts, {bool correct = false}) =>
    Trial(
      sessionId: sessionId,
      itemId: itemId,
      presentedAt: ts,
      answeredAt: ts + 800,
      rtMs: 800,
      correct: correct,
      errorType: correct ? null : ErrorType.distance,
      answerPitchClass: correct ? 'G' : 'E',
      inputSource: InputSource.nameButton,
      contextSnapshot: ContextSnapshot(clef: Clef.treble, jitterSeed: ts),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late int sessionId;
  late int itemId;
  late TrialRepo trials;
  late MasteryRepo masteries;
  late ConfusionSeedRepo confusion;

  setUp(() async {
    db = await openTestDb();
    sessionId = await SessionRepo(db).insert(const Session(
      date: '2026-11-19',
      startedAt: 1000,
      plannedCount: 40,
    ));
    itemId = await ItemRepo(db).insert(Item(
      id: 0,
      type: ItemType.anchor,
      payload: const AnchorPayload(diatonicIndex: 4),
      createdAt: 500,
    ));
    trials = TrialRepo(db);
    masteries = MasteryRepo(db);
    confusion = ConfusionSeedRepo(db);
    await masteries.upsert(Mastery(itemId: itemId, state: ItemState.learning));
  });
  tearDown(() async => db.close());

  test('recordTrial 成功：trial+mastery+confusion 同时落库', () async {
    final id = await trials.recordTrial(
      trial: makeTrial(sessionId, itemId, 2000),
      mastery: Mastery(
          itemId: itemId, state: ItemState.learning, reps: 1, lapses: 1),
      seedPair: (4, 2),
    );
    expect(id, greaterThan(0));
    expect(await trials.count(), 1);
    final m = await masteries.byItemId(itemId);
    expect(m!.reps, 1);
    expect(m.lapses, 1);
    final pairs = await confusion.all();
    expect(pairs.length, 1);
    expect(pairs.first['pair_a'], 2, reason: 'pair_a < pair_b 规范化');
    expect(pairs.first['pair_b'], 4);
    expect(pairs.first['count'], 1);
    expect(pairs.first['last_seen'], 2800);
  });

  test('confusion UPSERT：同对（含乱序）count+1', () async {
    await trials.recordTrial(
      trial: makeTrial(sessionId, itemId, 2000),
      mastery: Mastery(itemId: itemId, reps: 1),
      seedPair: (4, 2),
    );
    await trials.recordTrial(
      trial: makeTrial(sessionId, itemId, 4000),
      mastery: Mastery(itemId: itemId, reps: 2),
      seedPair: (2, 4),
    );
    final pairs = await confusion.all();
    expect(pairs.length, 1);
    expect(pairs.first['count'], 2);
    expect(pairs.first['last_seen'], 4800);
    expect(await trials.count(), 2);
  });

  test('P3: 事务中途失败（mastery FK 违约）→ trial/mastery/confusion 均未写入',
      () async {
    final before = await masteries.byItemId(itemId);
    await expectLater(
      trials.recordTrial(
        trial: makeTrial(sessionId, itemId, 2000),
        mastery: const Mastery(itemId: 99999, reps: 1), // 不存在的 item
        seedPair: (4, 2),
      ),
      throwsA(anything),
    );
    expect(await trials.count(), 0, reason: 'trial 已插入但必须随事务回滚');
    final after = await masteries.byItemId(itemId);
    expect(after!.toRow(), before!.toRow());
    expect(await masteries.byItemId(99999), isNull);
    expect(await confusion.all(), isEmpty);
  });

  test('P3: 事务内显式抛异常（模拟崩溃）→ 全部回滚', () async {
    await expectLater(
      db.transaction((txn) async {
        await insertTrial(txn, makeTrial(sessionId, itemId, 2000));
        await upsertMastery(txn, Mastery(itemId: itemId, reps: 42));
        throw StateError('模拟中途崩溃');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await trials.count(), 0);
    expect((await masteries.byItemId(itemId))!.reps, 0);
  });

  test('P3: trial_log 只增——count 单调递增且历史行不变', () async {
    final counts = <int>[];
    for (var i = 0; i < 5; i++) {
      await trials.insert(makeTrial(sessionId, itemId, 2000 + i * 1000,
          correct: i.isEven));
      counts.add(await trials.count());
    }
    expect(counts, [1, 2, 3, 4, 5]);

    final all = await trials.byItem(itemId);
    expect(all.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(all[i].presentedAt, 2000 + i * 1000);
      expect(all[i].correct, i.isEven);
    }

    final recent = await trials.recentByItem(itemId, 3);
    expect(recent.map((t) => t.presentedAt).toList(), [4000, 5000, 6000]);
    expect((await trials.bySession(sessionId)).length, 5);
  });
}