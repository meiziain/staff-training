// 规格: 02 §5.4 答错处理（整句错误率 > 40% 不原题重做，换音区变体 2–4 题后复现）
//       / 05 §3 C3（复现上下文至少一维不同）。
// 契约：phraseVariantBuilder 必须返回 (变体条目, 变体掌握度)，变体条目自带真实 id，
// 不得沿用原句 mastery（否则 trial_log / mastery 的 item_id 错配）。
library;

import 'package:test/test.dart';

import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';

Item phraseItem(int id, List<int> seq) => Item(
      id: id,
      type: ItemType.phrase,
      payload: PhrasePayload(
        noteSequence: seq,
        clefSequence: List.filled(seq.length, Clef.treble),
      ),
      createdAt: 0,
    );

Trial wrongPhraseTrial(int itemId) => Trial(
      sessionId: 1,
      itemId: itemId,
      presentedAt: 1000,
      answeredAt: 1600,
      rtMs: 600,
      correct: false,
      inputSource: InputSource.nameButton,
      contextSnapshot:
          const ContextSnapshot(clef: Clef.treble, jitterSeed: 11),
    );

void main() {
  test('整句错误率超阈值：复现的是变体条目，且掌握度 itemId 指向变体', () {
    final orig = phraseItem(1, [4, 5, 6]);
    final variant = phraseItem(99, [5, 6, 7]); // 整体上移二度（换音区）
    final variantMastery =
        const Mastery(itemId: 99, state: ItemState.learning, hintLevel: 0);
    final s = ReexposureScheduler(
      config: Config.defaults,
      rng: rng(7),
      phraseVariantBuilder: (o) => o.id == 1 ? (variant, variantMastery) : null,
    );
    final entry = s.onWrong(
      item: orig,
      mastery: const Mastery(itemId: 1, state: ItemState.learning),
      trial: wrongPhraseTrial(1),
      currentIndex: 0,
      sessionLength: 10,
      phraseWrongRate: 0.6,
    );
    expect(entry, isNotNull);
    expect(entry!.item.id, 99);
    expect(entry.mastery.itemId, 99);
    expect((entry.item.payload as PhrasePayload).noteSequence, [5, 6, 7]);
    expect(entry.segment, QueueSegment.reexposure);
    // 换上下文：至少一维不同（jitterSeed 必换）。
    expect(entry.context.differsFrom(wrongPhraseTrial(1).contextSnapshot), isTrue);
  });

  test('错误率未超阈值：复现原句，不进变体分支', () {
    var called = 0;
    final orig = phraseItem(1, [4, 5, 6]);
    final s = ReexposureScheduler(
      config: Config.defaults,
      rng: rng(7),
      phraseVariantBuilder: (o) {
        called++;
        return null;
      },
    );
    final entry = s.onWrong(
      item: orig,
      mastery: const Mastery(itemId: 1, state: ItemState.learning),
      trial: wrongPhraseTrial(1),
      currentIndex: 0,
      sessionLength: 10,
      phraseWrongRate: 0.2,
    );
    expect(called, 0);
    expect(entry!.item.id, 1);
    expect(entry.mastery.itemId, 1);
  });

  test('未接变体生成器：超阈值时放弃复现（退化为间隔阶梯）', () {
    final s = ReexposureScheduler(config: Config.defaults, rng: rng(7));
    final entry = s.onWrong(
      item: phraseItem(1, [4, 5, 6]),
      mastery: const Mastery(itemId: 1, state: ItemState.learning),
      trial: wrongPhraseTrial(1),
      currentIndex: 0,
      sessionLength: 10,
      phraseWrongRate: 0.8,
    );
    expect(entry, isNull);
    expect(s.pendingCount, 0);
  });
}
