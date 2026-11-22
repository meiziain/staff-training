// 规格: 交付报告「实现偏差」#19 试玩模式 —— 内存库构建目标阶段会话，不触碰正式数据。
library;

import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/data/playground.dart';
import 'package:sight_reading/domain/models/enums.dart';

import 'test_db.dart';

FakeClock makeClock() => FakeClock(
      utcMs: DateTime.utc(2026, 11, 19, 8).millisecondsSinceEpoch,
      localDate: DateTime(2026, 11, 19),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  test('试玩阶段4：队列含短句，会话阶段=4，内存库可关闭', () async {
    final s = await buildPlaygroundSession(
      factory: databaseFactoryFfi,
      config: Config.defaults,
      clock: makeClock(),
      stage: 4,
      dailyCount: 12,
    );
    expect(s.bundle.stage, 4);
    final phrases = s.bundle.plan.entries
        .where((e) => e.item.type == ItemType.phrase)
        .toList();
    expect(phrases, isNotEmpty, reason: '试玩必须能看到短句');
    expect(s.bundle.plan.entries.every((e) => e.item.type == ItemType.phrase),
        isTrue, reason: '试玩只看短句，不能先来一堆锚点/关系热身题');
    for (final e in phrases) {
      final seq = e.item.targetIndices;
      expect(seq.length, 3, reason: '阶段4 短句 3 音');
    }
    expect(s.bundle.plan.entries.length, 12);
    await s.dispose();
  });

  test('试玩阶段5：短句 4–5 音', () async {
    final s = await buildPlaygroundSession(
      factory: databaseFactoryFfi,
      config: Config.defaults,
      clock: makeClock(),
      stage: 5,
      dailyCount: 12,
    );
    final phrases = s.bundle.plan.entries
        .where((e) => e.item.type == ItemType.phrase)
        .toList();
    expect(phrases, isNotEmpty);
    for (final e in phrases) {
      expect(e.item.targetIndices.length, inInclusiveRange(4, 5));
    }
    await s.dispose();
  });
}
