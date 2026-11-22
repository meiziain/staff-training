// 规格: 06 §4 NameButtons/VirtualKeyboard / §3 平板；02 §1.3 §10.1 §10.2。
@Tags(['widget'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/ui/answer_input.dart';
import 'package:sight_reading/ui/name_buttons.dart';
import 'package:sight_reading/ui/virtual_keyboard.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    );

void _surface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

const Size _phone = Size(390, 844);
const Size _tablet = Size(800, 600);

Finder _keyOf(int midi) => find.byKey(ValueKey('key_$midi'));

Finder get _allKeys => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('key_');
    });

void main() {
  group('NameButtons', () {
    testWidgets('renders 7 keys C D E F G A B', (tester) async {
      _surface(tester, _phone);
      await tester.pumpWidget(_host(NameButtons(onAnswer: (_) {})));
      for (final pc in ['C', 'D', 'E', 'F', 'G', 'A', 'B']) {
        expect(find.text(pc), findsOneWidget);
      }
    });

    testWidgets('fires onAnswer on pointer down with correct value',
        (tester) async {
      _surface(tester, _phone);
      String? answer;
      await tester.pumpWidget(_host(NameButtons(onAnswer: (v) => answer = v)));
      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('name_button_G'))));
      expect(answer, 'G');
      await gesture.up();
      await tester.pump();
    });

    testWidgets('all 7 keys report their pitch class', (tester) async {
      _surface(tester, _phone);
      final answers = <String>[];
      await tester.pumpWidget(_host(NameButtons(onAnswer: answers.add)));
      for (final pc in ['C', 'D', 'E', 'F', 'G', 'A', 'B']) {
        await tester.tap(find.byKey(ValueKey('name_button_$pc')));
        await tester.pump();
      }
      expect(answers, ['C', 'D', 'E', 'F', 'G', 'A', 'B']);
    });

    testWidgets('disabled keys do not fire', (tester) async {
      _surface(tester, _phone);
      String? answer;
      await tester.pumpWidget(
          _host(NameButtons(onAnswer: (v) => answer = v, enabled: false)));
      await tester.tap(find.byKey(const ValueKey('name_button_C')));
      await tester.pump();
      expect(answer, isNull);
    });

    testWidgets('key width >= 44dp on phone', (tester) async {
      _surface(tester, _phone);
      await tester.pumpWidget(_host(NameButtons(onAnswer: (_) {})));
      final size =
          tester.getSize(find.byKey(const ValueKey('name_button_C')));
      expect(size.width, greaterThanOrEqualTo(44));
    });

    testWidgets('key width 64dp on tablet (>=600dp)', (tester) async {
      _surface(tester, _tablet);
      await tester.pumpWidget(_host(NameButtons(onAnswer: (_) {})));
      final size =
          tester.getSize(find.byKey(const ValueKey('name_button_C')));
      expect(size.width, 64);
    });
  });

  group('VirtualKeyboard', () {
    testWidgets('renders 22 white keys', (tester) async {
      _surface(tester, _phone);
      await tester.pumpWidget(_host(VirtualKeyboard(onAnswer: (_) {})));
      expect(_allKeys, findsNWidgets(22));
    });

    testWidgets('点选提交：按下只高亮，抬手未滑动才 onAnswer（C4 = 60）',
        (tester) async {
      _surface(tester, _phone);
      int? answer;
      await tester
          .pumpWidget(_host(VirtualKeyboard(onAnswer: (m) => answer = m)));
      await tester.ensureVisible(_keyOf(60));
      await tester.pumpAndSettle();
      final gesture =
          await tester.startGesture(tester.getCenter(_keyOf(60)));
      expect(answer, isNull, reason: '按下不提交，避免横滑找音时误答');
      await gesture.up();
      await tester.pump();
      expect(answer, 60);
    });

    testWidgets('横滑浏览琴键（22 键需滚动）不触发作答', (tester) async {
      _surface(tester, _phone);
      final answers = <int>[];
      await tester
          .pumpWidget(_host(VirtualKeyboard(onAnswer: answers.add)));
      await tester.ensureVisible(_keyOf(60));
      await tester.pumpAndSettle();
      final gesture =
          await tester.startGesture(tester.getCenter(_keyOf(60)));
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(answers, isEmpty, reason: '滑动不是作答');
    });

    testWidgets('range endpoints C3 = 48 and C6 = 84', (tester) async {
      _surface(tester, _phone);
      final answers = <int>[];
      await tester
          .pumpWidget(_host(VirtualKeyboard(onAnswer: answers.add)));
      await tester.ensureVisible(_keyOf(48));
      await tester.pumpAndSettle();
      await tester.tap(_keyOf(48));
      await tester.ensureVisible(_keyOf(84));
      await tester.pumpAndSettle();
      await tester.tap(_keyOf(84));
      expect(answers, [48, 84]);
    });

    testWidgets('octave labels C3/C4/C5/C6 exist', (tester) async {
      _surface(tester, _phone);
      await tester.pumpWidget(_host(VirtualKeyboard(onAnswer: (_) {})));
      for (final label in ['C3', 'C4', 'C5', 'C6']) {
        expect(find.byKey(ValueKey('octave_label_$label')), findsOneWidget);
      }
    });

    testWidgets('scrolls horizontally on narrow screen', (tester) async {
      _surface(tester, _phone);
      await tester.pumpWidget(_host(VirtualKeyboard(onAnswer: (_) {})));
      final scroll = find.byType(SingleChildScrollView);
      expect(scroll, findsOneWidget);
      expect(tester.getTopLeft(_keyOf(84)).dx, greaterThan(390));
      await tester.drag(scroll, const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_keyOf(84)).dx, lessThan(390));
    });

    testWidgets('tablet full width, no scrolling', (tester) async {
      _surface(tester, _tablet);
      await tester.pumpWidget(_host(VirtualKeyboard(onAnswer: (_) {})));
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(_allKeys, findsNWidgets(22));
      expect(tester.getTopRight(_keyOf(84)).dx, closeTo(800, 0.01));
    });

    testWidgets('八度快捷跳转：C4 滚到 7*44，C6 钳到最右；平板隐藏 chip',
        (tester) async {
      _surface(tester, _phone);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(
          VirtualKeyboard(onAnswer: (_) {}, controller: controller)));
      expect(find.byKey(const ValueKey('octave_jump_C4')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('octave_jump_C4')));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(7 * 44, 0.01));

      await tester.tap(find.byKey(const ValueKey('octave_jump_C6')));
      await tester.pumpAndSettle();
      // 22*44 - 390 = 578 = maxScrollExtent。
      expect(controller.offset, closeTo(22 * 44 - 390, 0.01));

      _surface(tester, _tablet);
      await tester.pumpWidget(_host(
          VirtualKeyboard(onAnswer: (_) {}, controller: controller)));
      expect(find.byKey(const ValueKey('octave_jump_C4')), findsNothing);
    });

    testWidgets('导航回调：按下/点按不触发；滑动开始/抬手各触发；跳转含动画',
        (tester) async {
      _surface(tester, _phone);
      var starts = 0;
      var ends = 0;
      await tester.pumpWidget(_host(VirtualKeyboard(
          onAnswer: (_) {},
          onNavigateStart: () => starts++,
          onNavigateEnd: () => ends++)));

      // 按住不动再抬手（点按）：不触发。
      final g = await tester.startGesture(tester.getCenter(_keyOf(60)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(starts, 0);
      await g.up();
      await tester.pump();
      expect(starts, 0);
      expect(ends, 0);

      // 滑动：超阈值即 start，过程中不 end，抬手才 end。
      final g2 = await tester.startGesture(tester.getCenter(_keyOf(60)));
      await g2.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(starts, 1);
      expect(ends, 0);
      await g2.up();
      await tester.pump();
      expect(ends, 1);

      // 八度跳转 chip：start 立即，end 在动画完成后。
      await tester.tap(find.byKey(const ValueKey('octave_jump_C5')));
      await tester.pump();
      expect(starts, 2);
      expect(ends, 1);
      await tester.pumpAndSettle();
      expect(ends, 2);
    });

    testWidgets('外部 controller：组件因上方部件增减重建后滚动位置保留',
        (tester) async {
      _surface(tester, _phone);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget host({required bool withHeader}) => _host(Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (withHeader) const Text('header'),
              VirtualKeyboard(onAnswer: (_) {}, controller: controller),
            ],
          ));
      await tester.pumpWidget(host(withHeader: true));
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      final offset = controller.offset;
      expect(offset, greaterThan(0));

      // 上方部件移除 → 无 key 时键盘元素按索引错配重建；外部 controller 保住位置。
      await tester.pumpWidget(host(withHeader: false));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, 0.01));
    });
  });

  group('answer_input', () {
    test('buildNameButtonAnswer fields complete, source nameButton', () {
      final e = buildNameButtonAnswer(
        itemId: 7,
        pitchClass: 'G',
        hintUsed: 2,
        hintRequested: true,
        timestamp: 1234567890,
      );
      expect(e.itemId, 7);
      expect(e.pitchClass, 'G');
      expect(e.octave, isNull);
      expect(e.rtMs, 0);
      expect(e.source, InputSource.nameButton);
      expect(e.hintUsed, 2);
      expect(e.hintRequested, isTrue);
      expect(e.timestamp, 1234567890);
    });

    test('buildNameButtonAnswer hint defaults', () {
      final e = buildNameButtonAnswer(
          itemId: 1, pitchClass: 'C', timestamp: 0);
      expect(e.hintUsed, 0);
      expect(e.hintRequested, isFalse);
    });

    test('buildKeyAnswer fields complete, source virtualKey', () {
      final e = buildKeyAnswer(
        itemId: 9,
        midi: 67,
        hintUsed: 1,
        hintRequested: true,
        timestamp: 42,
      );
      expect(e.itemId, 9);
      expect(e.pitchClass, 'G');
      expect(e.octave, 4);
      expect(e.rtMs, 0);
      expect(e.source, InputSource.virtualKey);
      expect(e.hintUsed, 1);
      expect(e.hintRequested, isTrue);
      expect(e.timestamp, 42);
    });

    test('midi mapping: 60->C4, 48->C3, 84->C6', () {
      expect(midiToPitchClassOctave(60), (pitchClass: 'C', octave: 4));
      expect(midiToPitchClassOctave(48), (pitchClass: 'C', octave: 3));
      expect(midiToPitchClassOctave(84), (pitchClass: 'C', octave: 6));
    });

    test('buildKeyAnswer octave lookup at pool endpoints', () {
      final low = buildKeyAnswer(itemId: 1, midi: 48, timestamp: 0);
      expect(low.pitchClass, 'C');
      expect(low.octave, 3);
      final high = buildKeyAnswer(itemId: 2, midi: 84, timestamp: 0);
      expect(high.pitchClass, 'C');
      expect(high.octave, 6);
    });

    test('accidental midi rejected (MVP no black keys)', () {
      expect(() => midiToPitchClassOctave(61), throwsArgumentError);
    });

    test('buildPianoAnswer: C4=60，source midi，携带原始 midi', () {
      final e = buildPianoAnswer(
        itemId: 3,
        midi: 60,
        hintUsed: 2,
        hintRequested: true,
        timestamp: 99,
      );
      expect(e.itemId, 3);
      expect(e.pitchClass, 'C');
      expect(e.octave, 4);
      expect(e.midi, 60);
      expect(e.source, InputSource.midi);
      expect(e.hintUsed, 2);
      expect(e.hintRequested, isTrue);
      expect(e.timestamp, 99);
    });

    test('buildPianoAnswer 黑键给升号音名，绝不等于自然音目标', () {
      final e = buildPianoAnswer(itemId: 1, midi: 61, timestamp: 0);
      expect(e.pitchClass, 'C#');
      expect(e.octave, 4);
      expect(e.midi, 61);
      expect(e.pitchClass, isNot('C'));
      expect(() => buildPianoAnswer(itemId: 1, midi: 128, timestamp: 0),
          throwsArgumentError);
    });
  });
}