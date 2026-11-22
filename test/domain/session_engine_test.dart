// 规格: 08 T13 会话状态机（状态机逻辑部分）/ 05 §9。
// 退后台未答题不落库、恢复重呈同题；已答题落库不受退出影响；退出后队列丢弃。
import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/answer_event.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';
import 'package:sight_reading/domain/session_engine.dart';

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
  @override
  Mastery masteryOf(int itemId) =>
      masteries[itemId] ?? Mastery(itemId: itemId, state: ItemState.learning);
  @override
  List<TrialResult> recentResults(int itemId, int limit) =>
      masteries[itemId]?.lastResults ?? const [];
  @override
  List<TrialResult> relationHistoryFor(int targetIndex) => const [];
  @override
  Mastery? directMasteryOf(int diatonicIndex) => null;
  @override
  List<int> relationItemIdsFor(int diatonicIndex) => const [];
  @override
  void saveMastery(Mastery m) => masteries[m.itemId] = m;
}

QueueEntry entry(int id, int index, {ItemType type = ItemType.direct}) {
  final payload = switch (type) {
    ItemType.direct => DirectPayload(diatonicIndex: index),
    ItemType.anchor => AnchorPayload(diatonicIndex: index),
    ItemType.relation =>
      RelationPayload.single(anchorIndex: 0, direction: 1, steps: 2),
    ItemType.phrase => const PhrasePayload(
        noteSequence: [0, 1, 2],
        clefSequence: [Clef.treble, Clef.treble, Clef.treble]),
  };
  return QueueEntry(
    item: Item(id: id, type: type, payload: payload, createdAt: 0),
    mastery: Mastery(itemId: id, state: ItemState.learning),
    context: ContextSnapshot(clef: Clef.treble, jitterSeed: id * 7 + 1),
    segment: QueueSegment.direct,
  );
}

SessionEngine makeEngine(List<QueueEntry> queue,
    {FakeRecorder? rec, FakeSource? src, FakeClock? clock}) {
  return SessionEngine(
    config: Config.defaults,
    clock: clock ?? FakeClock(),
    rng: rng(42),
    recorder: rec ?? FakeRecorder(),
    source: src ?? FakeSource(),
    sessionId: 1,
    stage: 3,
    mode: InputMode.nameButtons,
    queue: queue,
    sessionEndTs: 9999999,
  );
}

AnswerEvent answer(int itemId, String pc, {int rt = 800, int hint = 0}) =>
    AnswerEvent(
      itemId: itemId,
      pitchClass: pc,
      rtMs: rt,
      source: InputSource.nameButton,
      hintUsed: hint,
      timestamp: 0,
    );

void main() {
  test('导航耗时从 RT 扣除；presentedAt 仍按真实经过时间；逐题重置', () {
    final rec = FakeRecorder();
    final clock = FakeClock();
    final e = makeEngine([entry(1, 4), entry(2, 5)], rec: rec, clock: clock);
    e.start();
    e.onPresented(); // onset: mono 0 / utc 0
    clock.advance(const Duration(milliseconds: 1000)); // 思考，计入 RT
    e.addNavigationMs(800); // 滑动找音，扣除
    clock.advance(const Duration(milliseconds: 1300));
    e.submitAnswer(answer(1, 'G'));
    expect(rec.trials.single.rtMs, 1500); // 2300 - 800
    expect(rec.trials.single.presentedAt, 0); // utc 2300 - 经过 2300
    e.addNavigationMs(500); // 反馈期导航不计
    expect(e.navigationMs, 800);
    e.next();
    e.onPresented();
    expect(e.navigationMs, 0); // 逐题重置
    clock.advance(const Duration(milliseconds: 600));
    e.submitAnswer(answer(2, 'C'));
    expect(rec.trials.last.rtMs, 600);
  });

  test('导航扣除下限 0（导航超过经过时间不产生负 RT）', () {
    final rec = FakeRecorder();
    final clock = FakeClock();
    final e = makeEngine([entry(1, 4)], rec: rec, clock: clock);
    e.start();
    e.onPresented();
    clock.advance(const Duration(milliseconds: 300));
    e.addNavigationMs(5000);
    e.submitAnswer(answer(1, 'G'));
    expect(rec.trials.single.rtMs, 0);
  });

  test('T13 退后台：未答题试次不落库，恢复重呈同题（不计次）', () {
    final rec = FakeRecorder();
    final clock = FakeClock();
    final e = makeEngine([entry(1, 4), entry(2, 5)], rec: rec, clock: clock);
    e.start();
    expect(e.phase, SessionPhase.presenting);
    expect(e.current!.item.id, 1);
    e.onPresented();
    clock.monoMs += 500;
    e.onBackground();
    expect(e.phase, SessionPhase.paused);
    expect(rec.trials, isEmpty); // 未答题不落库
    e.onResume();
    expect(e.current!.item.id, 1); // 重呈同题
    expect(e.doneCount, 0); // 不计次
    expect(e.phase, SessionPhase.presenting);
    e.onPresented();
    clock.monoMs += 900;
    e.submitAnswer(answer(1, 'G'));
    expect(rec.trials.length, 1);
    expect(rec.trials.single.rtMs, 900); // onset 取 post-frame 单调钟
    expect(e.doneCount, 1);
  });

  test('T13 已答题落库不受退出影响；退出丢弃未做队列', () {
    final rec = FakeRecorder();
    final e = makeEngine([entry(1, 4), entry(2, 5), entry(3, 6)], rec: rec);
    e.start();
    e.onPresented();
    e.submitAnswer(answer(1, 'G')); // 对
    e.next();
    e.onPresented();
    e.submitAnswer(answer(2, 'C')); // 错（目标 A4）
    e.next();
    expect(rec.trials.length, 2);
    e.exit();
    expect(e.phase, SessionPhase.idle);
    expect(e.queueLength, 0); // 未做队列丢弃
    expect(rec.trials.length, 2); // 已落库不变
    // 下次会话重新 buildQueue（新引擎新队列，不续用旧队列）。
    final e2 = makeEngine([entry(9, 7)], rec: rec);
    e2.start();
    expect(e2.current!.item.id, 9);
  });

  test('T13 presenting 阶段退后台同样作废', () {
    final rec = FakeRecorder();
    final e = makeEngine([entry(1, 4)], rec: rec);
    e.start();
    e.onBackground(); // 尚未 onPresented
    expect(rec.trials, isEmpty);
    e.onResume();
    expect(e.current!.item.id, 1);
  });

  test('超时记 TIMEOUT 试次并落库', () {
    final rec = FakeRecorder();
    final e = makeEngine([entry(1, 4)], rec: rec);
    e.start();
    e.onPresented();
    e.timeout();
    expect(rec.trials.length, 1);
    expect(rec.trials.single.timeout, isTrue);
    expect(rec.trials.single.correct, isFalse);
    expect(rec.trials.single.errorType, ErrorType.timeout);
    expect(e.phase, SessionPhase.feedback);
  });

  test('答错触发换上下文复现（2–4 题后，上下文至少一维不同）', () {
    final rec = FakeRecorder();
    final e = makeEngine(
        [entry(1, 4), entry(2, 5), entry(3, 6), entry(4, 7), entry(5, 8)],
        rec: rec);
    e.start();
    e.onPresented();
    e.submitAnswer(answer(1, 'C')); // 目标 G4，答 C → 错
    final originalCtx = e.current!.context;
    e.next();
    // 复现题应插入在 pos 2..4 之间
    var found = false;
    while (e.phase != SessionPhase.summary) {
      final cur = e.current!;
      if (cur.reexposure) {
        found = true;
        expect(cur.item.id, 1);
        expect(cur.context.differsFrom(originalCtx), isTrue);
        expect(e.position, greaterThanOrEqualTo(2));
        expect(e.position, lessThanOrEqualTo(4));
        break;
      }
      e.onPresented();
      e.submitAnswer(answer(cur.item.id, 'C'));
      e.next();
    }
    expect(found, isTrue);
  });

  test('提示级5完成记错（correct=0）', () {
    final rec = FakeRecorder();
    final e = makeEngine([entry(1, 4, type: ItemType.relation)], rec: rec);
    e.start();
    e.onPresented();
    e.submitAnswer(answer(1, 'D', hint: 5)); // 目标 D4，但级5给答案记错
    expect(rec.trials.single.correct, isFalse);
  });

  test('PHRASE 逐音作答：整句完成落 PhraseRecord，逐音试次落库', () {
    final rec = FakeRecorder();
    final src = FakeSource();
    final e = makeEngine([entry(1, 0, type: ItemType.phrase)],
        rec: rec, src: src);
    e.start();
    e.onPresented();
    e.submitAnswer(answer(1, 'C')); // C4
    expect(e.phraseSlot, 1);
    e.onPresented();
    e.submitAnswer(answer(1, 'D')); // D4
    e.onPresented();
    e.submitAnswer(answer(1, 'E')); // E4
    expect(rec.trials.length, 3);
    expect(rec.phrases.length, 1);
    expect(rec.phrases.single.overallCorrect, 1.0);
    expect(rec.phrases.single.perNoteRt!.length, 3);
    expect(e.phase, SessionPhase.feedback);
  });

  test('PHRASE 复位计数', () {
    final rec = FakeRecorder();
    final e = makeEngine([entry(1, 0, type: ItemType.phrase)], rec: rec);
    e.start();
    e.onPresented();
    e.requestPhraseReset();
    e.requestPhraseReset();
    e.submitAnswer(answer(1, 'C'));
    e.onPresented();
    e.submitAnswer(answer(1, 'D'));
    e.onPresented();
    e.submitAnswer(answer(1, 'E'));
    expect(rec.phrases.single.resetCount, 2);
  });

  test('空队列直接进入 summary', () {
    final e = makeEngine([]);
    e.start();
    expect(e.phase, SessionPhase.summary);
  });
}