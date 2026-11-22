// 规格: 06 §4 StaffView / 02 §9 / 03 §4.2 —— widget 冒烟（flutter test -t widget）。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/ui/staff_geometry.dart';
import 'package:sight_reading/ui/staff_view.dart';

Widget _wrap(Widget child, {ThemeData? theme, double width = 360}) {
  return MaterialApp(
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, height: 300, child: child),
      ),
    ),
  );
}

StaffPainter _painter({
  Clef clef = Clef.treble,
  List<int> positions = const [4],
  int jitterSeed = 1,
  int? highlightIndex,
  StaffAnchorOverlay? anchorOverlay,
}) {
  return StaffPainter(
    clef: clef,
    positions: positions,
    jitterSeed: jitterSeed,
    staffSpace: 12,
    noteheadDiameter: 12,
    highlightIndex: highlightIndex,
    anchorOverlay: anchorOverlay,
  );
}

void main() {
  group('StaffView 可构建', () {
    testWidgets('高音单音', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.treble, positions: [4], jitterSeed: 1),
      ));
      expect(find.byType(StaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('低音单音', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.bass, positions: [-4], jitterSeed: 2),
      ));
      expect(find.byType(StaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('多音横排 + 高亮框', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(
          clef: Clef.treble,
          positions: [0, 2, 4, 7, 9],
          jitterSeed: 3,
          highlightIndex: 2,
        ),
      ));
      expect(find.byType(StaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加线音位（高音 C4/A5/C6，低音 C4/C3）', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(
          clef: Clef.treble,
          positions: [0, 12, 14],
          jitterSeed: 4,
        ),
      ));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.bass, positions: [0, -7], jitterSeed: 5),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('anchorOverlay 常亮 + 音名标注', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(
          clef: Clef.treble,
          positions: [7],
          jitterSeed: 6,
          anchorOverlay: StaffAnchorOverlay(index: 4, label: 'G4'),
        ),
      ));
      expect(find.byType(StaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空 positions 仅五线 + 谱号', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.bass, positions: [], jitterSeed: 7),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('符头最小尺寸', () {
    testWidgets('小宽度下符头 ≥12dp 且不溢出', (tester) async {
      expect(staffMetrics(100).noteheadDiameter,
          greaterThanOrEqualTo(minNoteheadDiameter));
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.treble, positions: [0, 14], jitterSeed: 8),
        width: 100,
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('noteheadDiameter 覆盖值低于 12 被钳制', (tester) async {
      expect(staffMetrics(360, noteheadDiameter: 4).noteheadDiameter,
          minNoteheadDiameter);
      await tester.pumpWidget(_wrap(
        const StaffView(
          clef: Clef.treble,
          positions: [4],
          jitterSeed: 9,
          noteheadDiameter: 4,
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('渲染确定性', () {
    test('同输入 shouldRepaint=false', () {
      final a = _painter(positions: const [0, 4, 7], highlightIndex: 1);
      final b = _painter(positions: const [0, 4, 7], highlightIndex: 1);
      expect(a.shouldRepaint(b), isFalse);
    });

    test('jitterSeed / positions / highlight / anchor 变化触发重绘', () {
      final base = _painter();
      expect(base.shouldRepaint(_painter(jitterSeed: 99)), isTrue);
      expect(base.shouldRepaint(_painter(positions: const [5])), isTrue);
      expect(base.shouldRepaint(_painter(highlightIndex: 0)), isTrue);
      expect(
        base.shouldRepaint(_painter(
            anchorOverlay: const StaffAnchorOverlay(index: 4, label: 'G4'))),
        isTrue,
      );
    });

    test('同 seed 重建几何偏移不变', () {
      final a = jitterOffset(123, 4, 12);
      final b = jitterOffset(123, 4, 12);
      expect(a.dx, b.dx);
      expect(a.dy, b.dy);
    });
  });

  group('固定浅底', () {
    testWidgets('浅色主题下浅底', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.treble, positions: [4], jitterSeed: 1),
      ));
      final boxes = tester.widgetList<ColoredBox>(find.descendant(
        of: find.byType(StaffView),
        matching: find.byType(ColoredBox),
      ));
      expect(boxes.any((b) => b.color == StaffView.paperColor), isTrue);
    });

    testWidgets('深色主题下仍浅底（不随 Theme 变暗）', (tester) async {
      await tester.pumpWidget(_wrap(
        const StaffView(clef: Clef.treble, positions: [4], jitterSeed: 1),
        theme: ThemeData.dark(useMaterial3: true),
      ));
      final boxes = tester.widgetList<ColoredBox>(find.descendant(
        of: find.byType(StaffView),
        matching: find.byType(ColoredBox),
      ));
      expect(boxes.any((b) => b.color == StaffView.paperColor), isTrue);
      expect(StaffView.paperColor.computeLuminance(), greaterThan(0.9));
    });
  });
}