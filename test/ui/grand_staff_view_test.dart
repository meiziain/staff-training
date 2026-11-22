// 规格: 11 §6.2 §6.3 —— 视奏谱表 widget 冒烟（flutter test -t widget）。
//
// 只验"画得出来、不抛异常、画布与固定纸面底色在位"，几何正确性由
// grand_staff_geometry_test.dart 用纯 Dart 断言，避免像素耦合。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/ui/grand_staff_view.dart';
import 'package:sight_reading/ui/staff_view.dart';

Widget _wrap(
  Widget child, {
  double width = 360,
  double height = 320,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, height: height, child: child),
      ),
    ),
  );
}

/// 单手 8 列：高音 C4 起步的自然音级阶梯。
List<SightColumn> _trebleColumns() =>
    List<SightColumn>.generate(8, (i) => SightColumn(upper: i));

/// 单手低音 8 列：G3 起向下。
List<SightColumn> _bassColumns() =>
    List<SightColumn>.generate(8, (i) => SightColumn(lower: -3 - i));

/// 双手 8 列：上声部 4 起、下声部 -4 起。
List<SightColumn> _grandColumns() => List<SightColumn>.generate(
      8,
      (i) => SightColumn(upper: i + 2, lower: -4 - i),
    );

/// 长谱例：count 列自然音阶梯（只关心横向溢出，不关心音高语义）。
List<SightColumn> _longColumns(int count) =>
    List<SightColumn>.generate(count, (i) => SightColumn(upper: i % 12));

/// 取出 GrandStaffView 内部实际使用的 ScrollController。
ScrollController _scrollOf(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.descendant(
      of: find.byType(GrandStaffView),
      matching: find.byType(SingleChildScrollView),
    ))
    .controller!;

/// 32 列长谱例 + 指定光标列（宽 320：内容 ~1019dp，必然溢出）。
Widget _longStaff(
  int cursor, {
  bool auto = true,
  ScrollController? controller,
}) =>
    _wrap(
      GrandStaffView(
        mode: SightMode.trebleOnly,
        columns: _longColumns(32),
        upperCursorColumn: cursor,
        autoScrollToCursor: auto,
        controller: controller,
      ),
      width: 320,
      height: 320,
    );

void main() {
  group('三种模式冒烟', () {
    testWidgets('高音单手', (tester) async {
      await tester.pumpWidget(_wrap(GrandStaffView(
        mode: SightMode.trebleOnly,
        columns: _trebleColumns(),
        upperCursorColumn: 0,
      )));
      expect(find.byType(GrandStaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('低音单手', (tester) async {
      await tester.pumpWidget(_wrap(GrandStaffView(
        mode: SightMode.bassOnly,
        columns: _bassColumns(),
        lowerCursorColumn: 0,
      )));
      expect(find.byType(GrandStaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('双手大谱表（双光标）', (tester) async {
      await tester.pumpWidget(_wrap(GrandStaffView(
        mode: SightMode.grand,
        columns: _grandColumns(),
        upperCursorColumn: 0,
        lowerCursorColumn: 0,
      )));
      expect(find.byType(GrandStaffView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('画布存在', () {
    for (final mode in SightMode.values) {
      testWidgets('${mode.wire} 渲染出 GrandStaffPainter 画布', (tester) async {
        await tester.pumpWidget(_wrap(GrandStaffView(
          mode: mode,
          columns: mode == SightMode.bassOnly
              ? _bassColumns()
              : mode == SightMode.trebleOnly
                  ? _trebleColumns()
                  : _grandColumns(),
        )));
        expect(find.byType(CustomPaint), findsWidgets);
        final staffPaints =
            tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where(
                  (w) => w.painter is GrandStaffPainter,
                );
        expect(staffPaints.length, 1);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('提示列不抛异常', () {
    testWidgets('upperHintColumns / lowerHintColumns', (tester) async {
      await tester.pumpWidget(_wrap(GrandStaffView(
        mode: SightMode.grand,
        columns: _grandColumns(),
        upperHintColumns: const {0},
        lowerHintColumns: const {1},
      )));
      expect(tester.takeException(), isNull);
    });

    testWidgets('提示极端音位（C2 / C6）音名不越界崩溃', (tester) async {
      await tester.pumpWidget(_wrap(
        GrandStaffView(
          mode: SightMode.grand,
          columns: const [
            SightColumn(upper: 14, lower: -14),
            SightColumn(upper: 0, lower: 0),
          ],
          upperHintColumns: const {0, 1},
          lowerHintColumns: const {0, 1},
        ),
        height: 300,
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('极端音域与滚动', () {
    testWidgets('C2 + C6 双手，高度 300 不抛异常', (tester) async {
      await tester.pumpWidget(_wrap(
        GrandStaffView(
          mode: SightMode.grand,
          columns: const [
            SightColumn(upper: 14, lower: -14),
            SightColumn(upper: 0, lower: 0),
          ],
          upperCursorColumn: 0,
          lowerCursorColumn: 0,
        ),
        height: 300,
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('16 列窄屏可横向滚动', (tester) async {
      await tester.pumpWidget(_wrap(
        GrandStaffView(
          mode: SightMode.grand,
          columns: List<SightColumn>.generate(
            16,
            (i) => SightColumn(upper: 2 + i % 10, lower: -10 + i % 8),
          ),
        ),
        width: 320,
      ));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      final scrollable = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollable.scrollDirection, Axis.horizontal);
      expect(tester.takeException(), isNull);
    });
  });

  group('退化尺寸', () {
    testWidgets('空 columns 只画五线 + 谱号，不崩', (tester) async {
      await tester.pumpWidget(_wrap(const GrandStaffView(
        mode: SightMode.grand,
        columns: [],
      )));
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .where((w) => w.painter is GrandStaffPainter)
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('120×90 双手（间距/列宽压到下限）不崩', (tester) async {
      await tester.pumpWidget(_wrap(
        GrandStaffView(
          mode: SightMode.grand,
          columns: const [
            SightColumn(upper: 14, lower: -14),
            SightColumn(upper: 0, lower: 0),
          ],
          upperCursorColumn: 0,
          lowerCursorColumn: 0,
        ),
        width: 120,
        height: 90,
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('固定纸面底色', () {
    testWidgets('浅色主题下底色为 paperColor', (tester) async {
      await tester.pumpWidget(_wrap(GrandStaffView(
        mode: SightMode.trebleOnly,
        columns: _trebleColumns(),
      )));
      final boxes = tester.widgetList<ColoredBox>(find.descendant(
        of: find.byType(GrandStaffView),
        matching: find.byType(ColoredBox),
      ));
      expect(boxes.any((b) => b.color == StaffView.paperColor), isTrue);
    });

    testWidgets('深色主题下仍为 paperColor（不随 Theme 变暗）', (tester) async {
      await tester.pumpWidget(_wrap(
        GrandStaffView(
          mode: SightMode.grand,
          columns: _grandColumns(),
        ),
        theme: ThemeData.dark(useMaterial3: true),
      ));
      final boxes = tester.widgetList<ColoredBox>(find.descendant(
        of: find.byType(GrandStaffView),
        matching: find.byType(ColoredBox),
      ));
      expect(boxes.any((b) => b.color == StaffView.paperColor), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('答对后自动跟随光标滚动', () {
    testWidgets('长谱例 32 列 / 宽 320：初始停在第一个光标（offset ≈ 0）', (tester) async {
      await tester.pumpWidget(_longStaff(0));
      await tester.pumpAndSettle();
      final offset = _scrollOf(tester).offset;
      expect(offset, greaterThanOrEqualTo(0));
      expect(offset, lessThanOrEqualTo(30)); // 不超过一个列宽
      expect(tester.takeException(), isNull);
    });

    testWidgets('光标跳到第 20 列：自动滚动且 offset > 0', (tester) async {
      await tester.pumpWidget(_longStaff(0));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);

      await tester.pumpWidget(_longStaff(20));
      await tester.pumpAndSettle();
      final offset = _scrollOf(tester).offset;
      expect(offset, greaterThan(0));
      // 光标（第 20 列中心 ~665dp）落在视口 35%（112dp）处，约 553dp。
      expect(offset, greaterThan(300));
      expect(tester.takeException(), isNull);
    });

    testWidgets('短谱例 8 列 / 宽 360：不溢出，offset 恒为 0', (tester) async {
      Widget build(int cursor) => _wrap(
            GrandStaffView(
              mode: SightMode.trebleOnly,
              columns: _trebleColumns(),
              upperCursorColumn: cursor,
            ),
            width: 360,
          );
      await tester.pumpWidget(build(0));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);
      await tester.pumpWidget(build(7));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('autoScrollToCursor: false：光标变化后 offset 不变', (tester) async {
      await tester.pumpWidget(_longStaff(0, auto: false));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);
      await tester.pumpWidget(_longStaff(20, auto: false));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('光标在视口内 / 已对齐：不触发滚动（无抖动）', (tester) async {
      // 视口能容纳整条谱例：光标从 3 走到 4 也不滚。
      Widget fitted(int cursor) => _wrap(
            GrandStaffView(
              mode: SightMode.trebleOnly,
              columns: _trebleColumns(),
              upperCursorColumn: cursor,
            ),
            width: 360,
          );
      await tester.pumpWidget(fitted(3));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);
      await tester.pumpWidget(fitted(4));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, 0);

      // 已对齐到第 20 列：同参数重建（如答错重绘）不再改变 offset。
      await tester.pumpWidget(_longStaff(20));
      await tester.pumpAndSettle();
      final aligned = _scrollOf(tester).offset;
      expect(aligned, greaterThan(0));
      await tester.pumpWidget(_longStaff(20));
      await tester.pumpAndSettle();
      expect(_scrollOf(tester).offset, aligned);
      expect(tester.takeException(), isNull);
    });

    testWidgets('外部 controller：滚动作用在外部实例上，卸载不销毁它', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_longStaff(0, controller: controller));
      await tester.pumpAndSettle();
      expect(identical(_scrollOf(tester), controller), isTrue);

      await tester.pumpWidget(_longStaff(20, controller: controller));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));

      // 卸载后外部 controller 必须仍可用（内部只销毁自建的那个）。
      await tester.pumpWidget(_wrap(const SizedBox()));
      expect(controller.hasClients, isFalse);
      await tester.pumpWidget(_longStaff(20, controller: controller));
      await tester.pumpAndSettle();
      expect(controller.hasClients, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
