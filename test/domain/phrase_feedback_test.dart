// 规格: 02 §5.2 第 5 条（错误音位反馈给 DIRECT/关系条目）/ §5.5 双向联动。
// 裁决（02 未定义反馈强度，实现侧记录）：
// 1) DIRECT 只做一次 lapse（lapses+1、intervalDays=0、due 拉回会话末），
//    不改 state、不动 ease —— 回退仍由 checkRelapse 的连续 3 题错判定。
// 2) 关系条目只把学习中/复习中的提示级抬回脚手架；已自动化与更高提示级不动。
// 3) 同句重复音位去重；正确音位不做正反馈。
library;

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
  final List<PhraseRecord> phrases = [];
  @override
  void record(Trial trial, Mastery mastery, (int, int)? seedPair) {}
  @override
  void recordPhrase(PhraseRecord record) => phrases.add(record);
}

class FeedbackSource implements SessionDataSource {
  final Map<int, Mastery> masteries = {};
  final Map<int, Mastery> directByIndex = {};
  final Map<int, List<int>> relationIds = {};

  @override
  Mastery masteryOf(int itemId) =>
      masteries[itemId] ?? Mastery(itemId: itemId, state: ItemState.learning);
  @override
  List<TrialResult> recentResults(int itemId, int limit) =>
      masteries[itemId]?.lastResults ?? const [];
  @override
  List<TrialResult> relationHistoryFor(int targetIndex) => const [];
  @override
  Mastery? directMasteryOf(int diatonicIndex) => directByIndex[diatonicIndex];
  @override
  List<int> relationItemIdsFor(int diatonicIndex) =>
      relationIds[diatonicIndex] ?? const [];
  @override
  void saveMastery(Mastery m) => masteries[m.itemId] = m;
}

QueueEntry phraseEntry({List<int> seq = const [0, 1, 2]}) => QueueEntry(
      item: Item(
        id: 1,
        type: ItemType.phrase,
        payload: PhrasePayload(
          noteSequence: seq,
          clefSequence: List.filled(seq.length, Clef.treble),
        ),
        createdAt: 0,
      ),
      mastery: const Mastery(
          itemId: 1, state: ItemState.learning, hintLevel: 0),
      context: const ContextSnapshot(clef: Clef.treble, jitterSeed: 7),
      segment: QueueSegment.phrase,
    );

AnswerEvent answer(String pc) => AnswerEvent(
      itemId: 1,
      pitchClass: pc,
      rtMs: 800,
      source: InputSource.nameButton,
      hintUsed: 0,
      timestamp: 0,
    );

/// 三音短句 C4 D4 E4：逐音作答（每音前 onPresented 重记 onset）。
void playPhrase(SessionEngine e, List<String> answers) {
  e.start();
  for (var i = 0; i < answers.length; i++) {
    e.onPresented();
    e.submitAnswer(answer(answers[i]));
  }
}

void main() {
  test('错误音位：DIRECT 记 lapse 且 state 不变；关系条目提示级抬回 3', () {
    const direct0 = Mastery(
      itemId: 100,
      state: ItemState.automated,
      intervalDays: 7,
      ease: 2.3,
      hintLevel: 0,
    );
    final src = FeedbackSource()
      ..directByIndex[1] = direct0
      ..masteries[100] = direct0
      ..relationIds[1] = [5, 7]
      ..masteries[5] = const Mastery(
          itemId: 5, state: ItemState.learning, hintLevel: 0)
      ..masteries[7] = const Mastery(
          itemId: 7, state: ItemState.learning, hintLevel: 5);
    final e = SessionEngine(
      config: Config.defaults,
      clock: FakeClock(),
      rng: rng(1),
      recorder: FakeRecorder(),
      source: src,
      sessionId: 1,
      stage: 4,
      mode: InputMode.nameButtons,
      queue: [phraseEntry()],
      sessionEndTs: 9999999,
    );
    playPhrase(e, ['C', 'C', 'E']); // 第 2 音目标 D4 答错

    final direct = src.masteries[100]!;
    expect(direct.lapses, 1);
    expect(direct.intervalDays, 0);
    expect(direct.dueAt, 9999999);
    expect(direct.state, ItemState.automated); // 单次错误不改状态
    expect(direct.ease, 2.3); // 不动 ease

    final rel = src.masteries[5]!;
    expect(rel.hintLevel, 3); // 抬回脚手架
    expect(rel.state, ItemState.learning);
    expect(src.masteries[7]!.hintLevel, 5); // 已更高提示级不降级
  });

  test('正确音位不做正反馈；已自动化关系条目不被抬级', () {
    final src = FeedbackSource()
      ..directByIndex[2] = const Mastery(
        itemId: 102,
        state: ItemState.reviewing,
        intervalDays: 3,
        lapses: 2,
        hintLevel: 0,
      )
      ..masteries[102] = const Mastery(
        itemId: 102,
        state: ItemState.reviewing,
        intervalDays: 3,
        lapses: 2,
        hintLevel: 0,
      )
      ..relationIds[2] = [6]
      ..masteries[6] = const Mastery(
        itemId: 6,
        state: ItemState.automated,
        intervalDays: 14,
        hintLevel: 0,
      );
    final e = SessionEngine(
      config: Config.defaults,
      clock: FakeClock(),
      rng: rng(1),
      recorder: FakeRecorder(),
      source: src,
      sessionId: 1,
      stage: 4,
      mode: InputMode.nameButtons,
      queue: [phraseEntry()],
      sessionEndTs: 9999999,
    );
    playPhrase(e, ['C', 'D', 'E']); // 全对

    expect(src.masteries[102]!.lapses, 2); // 无副作用
    expect(src.masteries[102]!.intervalDays, 3);
    expect(src.masteries[6]!.hintLevel, 0); // automated 条目不动
    expect(src.masteries[6]!.state, ItemState.automated);
  });

  test('同一短句重复音位只反馈一次', () {
    final src = FeedbackSource()
      ..directByIndex[1] = const Mastery(
          itemId: 100, state: ItemState.learning, hintLevel: 0)
      ..masteries[100] = const Mastery(
          itemId: 100, state: ItemState.learning, hintLevel: 0);
    final e = SessionEngine(
      config: Config.defaults,
      clock: FakeClock(),
      rng: rng(1),
      recorder: FakeRecorder(),
      source: src,
      sessionId: 1,
      stage: 4,
      mode: InputMode.nameButtons,
      queue: [phraseEntry(seq: [1, 1, 1])], // D4 D4 D4
      sessionEndTs: 9999999,
    );
    playPhrase(e, ['C', 'C', 'C']); // 三音全错，同一音位

    expect(src.masteries[100]!.lapses, 1); // 去重后只 lapse 一次
  });
}
