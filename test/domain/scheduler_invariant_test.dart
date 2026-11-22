// 规格: 08 §2 P3 —— 调度不变量（纯调度部分），固定种子任意作答序列 1000 次。
// trial_log 只增 / mastery 同事务由数据层负责，不在本文件范围。
import 'package:test/test.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';

const cfg = Config.defaults;

void main() {
  test('P3 调度不变量 ×1000（固定种子，任意作答序列）', () {
    for (var it = 0; it < 1000; it++) {
      final r = rng(700000 + it);
      final clock = FakeClock(
        utcMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        localDate: DateTime(2026, 1, 1),
      );
      var m = Mastery(
        itemId: 1,
        state: ItemState.learning,
        ease: r.chance(0.5) ? cfg.easeInit : cfg.easeMin + r.nextDouble(),
      );
      var prevLapses = m.lapses;
      var prevReps = m.reps;
      final reason = 'iter=$it';

      for (var step = 0; step < 60; step++) {
        // 任意作答：随机正确/超时/提示/RT，经 quality 映射；偶尔直接取 q。
        final correct = r.chance(0.75);
        final timeout = !correct && r.chance(0.3);
        final hint = r.chance(0.3) ? r.randInt(1, 5) : 0;
        final trial = Trial(
          sessionId: 1,
          itemId: 1,
          presentedAt: clock.nowUtcMs(),
          rtMs: r.randInt(300, 5000),
          correct: correct,
          timeout: timeout,
          hintLevelUsed: hint,
          inputSource: InputSource.nameButton,
          contextSnapshot:
              ContextSnapshot(clef: Clef.treble, jitterSeed: r.nextInt(1 << 20)),
        );
        final type = r.pick(ItemType.values);
        final q = r.chance(0.8)
            ? quality(trial, type, cfg)
            : r.pick([1, 3, 4, 5]);
        final sessionEnd = r.chance(0.2)
            ? null
            : clock.localEndOfDayUtcMs(clock.localDate());

        m = advance(m, q, sessionEnd, clock, cfg);

        expect(m.ease, inInclusiveRange(cfg.easeMin, cfg.easeMax),
            reason: reason);
        expect(m.intervalDays, greaterThanOrEqualTo(0), reason: reason);
        expect(m.lapses, greaterThanOrEqualTo(prevLapses), reason: reason);
        expect(m.reps, prevReps + 1, reason: reason);
        expect(m.dueAt, isNotNull, reason: reason);
        prevLapses = m.lapses;
        prevReps = m.reps;

        if (r.chance(0.1)) {
          final d = clock.localDate();
          clock.setDate(DateTime(d.year, d.month, d.day + 1));
          clock.advance(const Duration(days: 1));
        }
      }
    }
  });
}