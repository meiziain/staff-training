// T04 验收：一条完整链路（入槽 → 按拍 tick → 四色 → 完成 → 新指标）widget 测试。
// 复用 sight_session_page_test.dart 中的手动拍调度器与点击辅助，避免重复实现。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/domain/models/sight_beat_result.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/ui/grand_staff_view.dart';

import 'sight_session_page_test.dart' as base;

SightScore fourBeatScore() => SightScore(
      mode: SightMode.trebleOnly,
      columns: const [
        SightColumn(upper: 2, onsetBeat: 0),
        SightColumn(upper: 4, onsetBeat: 1),
        SightColumn(upper: 6, onsetBeat: 2),
        SightColumn(upper: 8, onsetBeat: 3),
      ],
    );

void main() {
  group('四色常量', () {
    test('绿/蓝/琥珀/红映射固定，色值不漂移', () {
      expect(sightGradeColor(SightHitGrade.onBeat),
          const Color(0xFF3B8F5A));
      expect(sightGradeColor(SightHitGrade.early), const Color(0xFF2F6FED));
      expect(sightGradeColor(SightHitGrade.late), const Color(0xFFE8A33A));
      expect(sightGradeColor(SightHitGrade.miss), const Color(0xFFD64545));
    });
  });

  testWidgets('扫描 → submit → tick → 四色 → 完成页新指标', (tester) async {
    final clock = FakeClock();
    final scheduler = base.ManualBeatScheduler();
    await base.pumpPage(tester, fourBeatScore(),
        clock: clock, scheduler: scheduler);
    expect(find.byKey(const Key('sight_summary')), findsNothing);

    // 第 0 拍：准点（屏幕 tap 的 +30ms 补偿落在标准窗内）→ 绿。
    await base.reachBeat(tester, clock, scheduler);
    await base.tapNote(tester, 2);
    expect(base.staff(tester).upperCursorColumn, 0, reason: 'submit 不推进');
    await base.fireBeat(tester, scheduler);
    expect(base.staff(tester).upperCursorColumn, 1, reason: 'tick 后推进');

    // 第 1 拍：提前 170ms → 蓝（early）。
    final earlyDelay = scheduler.nextDelayMs - 200;
    if (earlyDelay > 0) clock.advance(Duration(milliseconds: earlyDelay));
    await tester.pump();
    await base.tapNote(tester, 4);
    await base.fireBeat(tester, scheduler);

    // 第 2 拍：晚 230ms → 琥珀（late）。
    final lateDelay = scheduler.nextDelayMs + 200;
    clock.advance(Duration(milliseconds: lateDelay));
    await tester.pump();
    await base.tapNote(tester, 6);
    await base.fireBeat(tester, scheduler);

    // 完成前读四色：完成后页面只显示统计卡，不再有谱表。
    expect(base.staff(tester).upperGrades, {
      0: SightHitGrade.onBeat,
      1: SightHitGrade.early,
      2: SightHitGrade.late,
    });

    // 第 3 拍：不输入 → 红（miss），仍推进并完成。
    await base.reachBeat(tester, clock, scheduler);
    await base.fireBeat(tester, scheduler);

    expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    // Δ = +30 / -170 / +230 → 均值 +30ms；3 次命中、1 次 miss；连续命中 3。
    expect(find.byKey(const Key('sight_stat_onbeat')), findsOneWidget);
    expect(find.byKey(const Key('sight_stat_bias')), findsOneWidget);
    expect(find.byKey(const Key('sight_stat_streak')), findsOneWidget);
    expect(find.text('33%'), findsOneWidget); // 1/3 准点
    expect(find.text('平均晚 30ms'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // longestHitStreak
    expect(find.text('75%'), findsOneWidget); // 3 命中 / 4 音

    // 四色分布色带四项齐全，键名与颜色常量一一对应。
    for (final grade in SightHitGrade.values) {
      expect(find.byKey(Key('sight_grade_${grade.name}')), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
