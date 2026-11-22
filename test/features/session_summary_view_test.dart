// 规格: 06 §2 S4 会话总结 —— 页面渲染与按钮回调。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/data/session_summary.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/features/session/session_summary_view.dart';

void main() {
  testWidgets('S4 渲染：稳定条目 / 直认变化 / 错误分布 / 明日到期 / 按钮回调',
      (tester) async {
    var home = 0;
    var map = 0;
    await tester.pumpWidget(MaterialApp(
      home: SessionSummaryView(
        data: const SessionSummaryData(
          doneCount: 40,
          trialCount: 46,
          correctCount: 37,
          timeoutCount: 2,
          stable: [SummaryStableItem('直认 G4', ItemType.direct, 14)],
          promoted: [4],
          relapsed: [7],
          errors: [
            SummaryErrorStat(ErrorType.distance, 5),
            SummaryErrorStat(ErrorType.lineSpace, 2),
          ],
          dueTomorrow: 12,
        ),
        onHome: () => home++,
        onMasteryMap: () => map++,
      ),
    ));

    expect(find.text('完成 40 题 · 音级正确率 80%'), findsOneWidget);
    expect(find.text('今天稳定'), findsOneWidget);
    expect(find.text('直认 G4'), findsOneWidget);
    expect(find.text('间隔 14 天'), findsOneWidget);
    expect(find.text('激活 G4'), findsOneWidget);
    expect(find.text('回退 C5'), findsOneWidget);
    expect(find.text('距离错'), findsOneWidget);
    expect(find.text('明日到期 12 条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('summary_home')));
    await tester.tap(find.byKey(const Key('summary_map')));
    expect(home, 1);
    expect(map, 1);
  });

  testWidgets('S4 空态：无稳定条目 / 无错误 / 无明日到期', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SessionSummaryView(
        data: const SessionSummaryData(
          doneCount: 0,
          trialCount: 0,
          correctCount: 0,
          timeoutCount: 0,
          stable: [],
          promoted: [],
          relapsed: [],
          errors: [],
          dueTomorrow: 0,
        ),
        onHome: () {},
      ),
    ));
    expect(find.textContaining('本次暂无新稳定条目'), findsOneWidget);
    expect(find.text('本次没有错误'), findsOneWidget);
    expect(find.text('明日暂无到期复习'), findsOneWidget);
    // 无掌握地图回调时按钮禁用但存在于树中。
    expect(find.byKey(const Key('summary_map')), findsOneWidget);
  });
}
