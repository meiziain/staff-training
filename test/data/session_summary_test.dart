// 规格: 06 §2 S4 会话总结 / 02 §7.1 结束总结 —— 数据聚合断言。
library;

import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/data/session_summary.dart';
import 'package:sight_reading/domain/mastery.dart' show PromotionEvent;
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';

import 'test_db.dart';

FakeClock makeClock() => FakeClock(
      utcMs: DateTime.utc(2026, 11, 19, 8).millisecondsSinceEpoch,
      localDate: DateTime(2026, 11, 19),
    );

Trial mkTrial(
  int sessionId,
  int itemId,
  int ts, {
  bool correct = true,
  ErrorType? error,
  bool timeout = false,
}) =>
    Trial(
      sessionId: sessionId,
      itemId: itemId,
      presentedAt: ts,
      answeredAt: ts + 500,
      rtMs: 500,
      correct: correct,
      timeout: timeout,
      errorType: error,
      answerPitchClass: correct ? 'G' : 'E',
      inputSource: InputSource.nameButton,
      contextSnapshot: const ContextSnapshot(clef: Clef.treble, jitterSeed: 7),
    );

void main() {
  setUpAll(sqfliteFfiInit);
  late Database db;
  setUp(() async => db = await openTestDb());
  tearDown(() async => db.close());

  test('S4 聚合：稳定条目 / 错误分布 / 明日到期 / 事件透传', () async {
    final clock = makeClock();
    final itemRepo = ItemRepo(db);
    final masteryRepo = MasteryRepo(db);

    final directId = await itemRepo.insert(const Item(
      id: 0,
      type: ItemType.direct,
      payload: DirectPayload(diatonicIndex: 4), // G4
      createdAt: 0,
    ));
    final relId = await itemRepo.insert(Item(
      id: 0,
      type: ItemType.relation,
      payload: RelationPayload.single(anchorIndex: 0, direction: 1, steps: 3),
      createdAt: 0,
    ));

    final tomorrow = clock.localDate().add(const Duration(days: 1));
    final tomorrowNoon = clock.localMidnightUtcMs(tomorrow) + 12 * 3600 * 1000;
    await masteryRepo.upsert(Mastery(
      itemId: directId,
      state: ItemState.automated,
      intervalDays: 14,
      ease: 2.5,
      dueAt: tomorrowNoon,
    ));
    await masteryRepo.upsert(Mastery(
      itemId: relId,
      state: ItemState.learning,
      intervalDays: 1,
      ease: 2.5,
      dueAt: clock.nowUtcMs(),
    ));

    final sessionId = await SessionRepo(db).insert(Session(
      date: '2026-11-19',
      startedAt: clock.nowUtcMs(),
      plannedCount: 4,
    ));
    final trials = TrialRepo(db);
    await trials.insert(mkTrial(sessionId, directId, 1000));
    await trials.insert(mkTrial(sessionId, directId, 2000,
        correct: false, error: ErrorType.distance));
    await trials.insert(mkTrial(sessionId, relId, 3000,
        correct: false, error: ErrorType.timeout, timeout: true));
    await trials.insert(mkTrial(sessionId, relId, 4000));

    final data = await loadSessionSummary(
      db: db,
      sessionId: sessionId,
      config: Config.defaults,
      clock: clock,
      doneCount: 4,
      events: [PromotionEvent(diatonicIndex: 4, directItemId: directId)],
    );

    expect(data.doneCount, 4);
    expect(data.trialCount, 4);
    expect(data.correctCount, 2);
    expect(data.timeoutCount, 1);
    expect(data.accuracy, 0.5);

    // 稳定条目：自动化的直认 G4；learning 的关系条目不稳定。
    expect(data.stable.map((s) => s.label), contains('直认 G4'));
    expect(data.stable.map((s) => s.label), isNot(contains(startsWith('关系'))));

    // 错误分布：超时计入 TIMEOUT；SLOW_CORRECT 不算错误。
    expect(data.errors.length, 2);
    expect(
        data.errors.any((e) => e.type == ErrorType.distance && e.count == 1),
        isTrue);
    expect(
        data.errors.any((e) => e.type == ErrorType.timeout && e.count == 1),
        isTrue);

    expect(data.dueTomorrow, 1); // 只有 directId 明天到期
    expect(data.promoted, [4]);
    expect(data.relapsed, isEmpty);
  });

  test('S4 无试次/无到期：空口径不报错', () async {
    final clock = makeClock();
    final sessionId = await SessionRepo(db).insert(Session(
      date: '2026-11-19',
      startedAt: clock.nowUtcMs(),
      plannedCount: 0,
    ));
    final data = await loadSessionSummary(
      db: db,
      sessionId: sessionId,
      config: Config.defaults,
      clock: clock,
      doneCount: 0,
    );
    expect(data.trialCount, 0);
    expect(data.accuracy, 0);
    expect(data.stable, isEmpty);
    expect(data.errors, isEmpty);
    expect(data.dueTomorrow, 0);
    expect(data.promoted, isEmpty);
  });
}
