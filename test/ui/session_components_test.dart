// 规格: 06 §4 HintPanel/FeedbackOverlay/ProgressHeader / 02 §3.4 / 05 §7。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/ui/feedback_overlay.dart';
import 'package:sight_reading/ui/hint_panel.dart';
import 'package:sight_reading/ui/progress_header.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    );

void _surface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// C4=0 D4=1 E4=2 F4=3 G4=4 A4=5 B4=6 C5=7。
RelationPayload _single(int anchor, int direction, int steps) =>
    RelationPayload.single(
        anchorIndex: anchor, direction: direction, steps: steps);

RelationPayload get _chain => RelationPayload.chain(const [
      RelationStep(anchorIndex: 4, direction: 1, steps: 2), // G4→A4
      RelationStep(anchorIndex: 5, direction: 1, steps: 3), // A4→C5
    ]);

Finder _dots(String state) => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          k.value.startsWith('progress_dot_${state}_');
    });

Finder get _allDots => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('progress_dot_');
    });

void main() {
  group('HintPanel', () {
    testWidgets('level 0 renders nothing', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 0, relation: _single(4, 1, 2))));
      expect(tester.getSize(find.byType(HintPanel)), Size.zero);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('visible=false hides content at any level', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(
          HintPanel(level: 3, relation: _single(4, 1, 3), visible: false)));
      expect(tester.getSize(find.byType(HintPanel)), Size.zero);
      expect(find.text('三度'), findsNothing);
    });

    testWidgets('level 1 upward arrow + 往上 (G4→A4)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 1, relation: _single(4, 1, 2))));
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(find.text('往上'), findsOneWidget);
    });

    testWidgets('level 1 downward arrow + 往下 (A4→G4)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 1, relation: _single(5, -1, 2))));
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
      expect(find.text('往下'), findsOneWidget);
    });

    testWidgets('level 2 线→间＝二度 (G4线→A4间)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 2, relation: _single(4, 1, 2))));
      expect(find.text('线→间＝二度'), findsOneWidget);
    });

    testWidgets('level 2 线→线＝三度 (G4线→B4线)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 2, relation: _single(4, 1, 3))));
      expect(find.text('线→线＝三度'), findsOneWidget);
    });

    testWidgets('level 2 间→线＝二度 (A4间→B4线)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 2, relation: _single(5, 1, 2))));
      expect(find.text('间→线＝二度'), findsOneWidget);
    });

    testWidgets('level 2 间→间＝三度 (A4间→C5间)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 2, relation: _single(5, 1, 3))));
      expect(find.text('间→间＝三度'), findsOneWidget);
    });

    testWidgets('level 3 interval name 三度 / 二度', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 3, relation: _single(4, 1, 3))));
      expect(find.text('三度'), findsOneWidget);
      await tester.pumpWidget(
          _host(HintPanel(level: 3, relation: _single(4, 1, 2))));
      expect(find.text('二度'), findsOneWidget);
    });

    testWidgets('level 3 chain shows 两步推导', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(HintPanel(level: 3, relation: _chain)));
      expect(find.text('两步推导'), findsOneWidget);
      expect(find.text('二度 → 三度'), findsOneWidget);
    });

    testWidgets('level 4 anchor card G4 + reset text', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 4, relation: _single(4, 1, 3))));
      expect(find.text('G4'), findsOneWidget);
      expect(find.textContaining('锚点'), findsOneWidget);
    });

    testWidgets('level 5 answer label single (G4→B4)', (tester) async {
      _surface(tester);
      await tester.pumpWidget(
          _host(HintPanel(level: 5, relation: _single(4, 1, 3))));
      expect(find.text('答案：B4'), findsOneWidget);
    });

    testWidgets('level 5 answer label chain target C5', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(HintPanel(level: 5, relation: _chain)));
      expect(find.text('答案：C5'), findsOneWidget);
    });
  });

  group('FeedbackOverlay', () {
    testWidgets('correct shows check icon + answer, no close',
        (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(
          const FeedbackOverlay(correct: true, correctAnswer: 'G4')));
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('正确答案：G4'), findsOneWidget);
    });

    testWidgets('wrong shows close icon + answer, no check', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(
          const FeedbackOverlay(correct: false, correctAnswer: 'A4')));
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.text('正确答案：A4'), findsOneWidget);
    });

    testWidgets('visible=false renders nothing', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(const FeedbackOverlay(
          correct: true, correctAnswer: 'G4', visible: false)));
      expect(tester.getSize(find.byType(FeedbackOverlay)), Size.zero);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('overlay does not block taps underneath', (tester) async {
      _surface(tester);
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(alignment: Alignment.center, children: [
            TextButton(
              onPressed: () => tapped = true,
              child: const Text('底层按钮'),
            ),
            const FeedbackOverlay(correct: false, correctAnswer: 'G4'),
          ]),
        ),
      ));
      await tester.tap(find.text('底层按钮'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  group('ProgressHeader', () {
    testWidgets('segment label and index/total text', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(ProgressHeader(
        segment: SessionSegment.warmup,
        index: 2,
        total: 8,
        onExit: () {},
      )));
      expect(find.text('热身'), findsOneWidget);
      expect(find.text('3/8'), findsOneWidget);
    });

    testWidgets('dot count equals total', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(ProgressHeader(
        segment: SessionSegment.mixed,
        index: 1,
        total: 5,
        onExit: () {},
      )));
      expect(_allDots, findsNWidgets(5));
    });

    testWidgets('three states: done / current / todo', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(ProgressHeader(
        segment: SessionSegment.mixed,
        index: 2,
        total: 5,
        onExit: () {},
      )));
      expect(_dots('done'), findsNWidgets(2));
      expect(_dots('current'), findsNWidgets(1));
      expect(_dots('todo'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('progress_dot_current_2')),
          findsOneWidget);
    });

    testWidgets('exit button fires onExit', (tester) async {
      _surface(tester);
      var exited = false;
      await tester.pumpWidget(_host(ProgressHeader(
        segment: SessionSegment.phrase,
        index: 0,
        total: 3,
        onExit: () => exited = true,
      )));
      await tester.tap(find.byKey(const ValueKey('session_exit')));
      await tester.pump();
      expect(exited, isTrue);
    });

    testWidgets('all segment labels render', (tester) async {
      _surface(tester);
      const expected = {
        SessionSegment.warmup: '热身',
        SessionSegment.microLesson: '微课',
        SessionSegment.mixed: '混合',
        SessionSegment.phrase: '短句',
        SessionSegment.summary: '总结',
      };
      for (final e in expected.entries) {
        await tester.pumpWidget(_host(ProgressHeader(
          segment: e.key,
          index: 0,
          total: 3,
          onExit: () {},
        )));
        expect(find.text(e.value), findsOneWidget);
      }
    });
  });
}