// 规格: 11 §3 §9 / T04 —— 视奏执行页 widget 测试（两段式：submit 入槽 / tick 结算）。
// 拍结算用注入的 ManualBeatScheduler 手动触发，避免 widget test 依赖真实 Timer。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/repositories/sight_read_repo.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/sight_read_log.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/features/sight/sight_session_page.dart';
import 'package:sight_reading/ui/grand_staff_view.dart';
import 'package:sight_reading/ui/virtual_keyboard.dart';

import '../data/test_db.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  final List<int> played = [];

  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async => played.add(midi);
  @override
  Future<void> playComparison({
    required int answerMidi,
    required int correctMidi,
    Duration gap = const Duration(milliseconds: 400),
  }) async {}
  @override
  Future<void> playSequence(
    List<int> midis, {
    Duration interval = const Duration(milliseconds: 500),
  }) async {}
  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

/// 手动拍调度器：记录页面排的下一次拍延迟，由测试显式 fire。
class ManualBeatScheduler implements SightBeatScheduler {
  final List<_ManualTask> _tasks = [];

  /// 下一次拍的调度延迟（ms）；页面每次结算后会排下一拍。
  int get nextDelayMs => _tasks.isEmpty ? 0 : _tasks.last.delayMs;

  @override
  SightBeatTask schedule(Duration delay, void Function() callback) {
    final task = _ManualTask(delay.inMilliseconds, callback);
    _tasks.add(task);
    return task;
  }

  /// 触发当前所有未取消的拍任务；回调里排的新任务留到下一次。
  void fireAll() {
    final pending = List<_ManualTask>.of(_tasks);
    _tasks.clear();
    for (final task in pending) {
      if (!task.cancelled) task.callback();
    }
  }
}

class _ManualTask implements SightBeatTask {
  _ManualTask(this.delayMs, this.callback);

  final int delayMs;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

SightScore trebleScore(List<int> notes) => SightScore(
  mode: SightMode.trebleOnly,
  title: '右手练习',
  columns: [for (final n in notes) SightColumn.single(SightVoice.upper, n)],
);

/// 上声部三音 + 下声部三音，列坐标共用（11 §2）。
SightScore grandScore() => const SightScore(
  mode: SightMode.grand,
  columns: [
    SightColumn(upper: 0, lower: -7),
    SightColumn(upper: 2, lower: -5),
    SightColumn(upper: 4, lower: -3),
  ],
);

/// 下声部第 0 拍、上声部第 1/2 拍：验证双轨按拍各自结算。
SightScore staggeredGrandScore() => const SightScore(
  mode: SightMode.grand,
  columns: [
    SightColumn(upper: null, lower: -7, onsetBeat: 0),
    SightColumn(upper: 0, lower: null, onsetBeat: 1),
    SightColumn(upper: 2, lower: null, onsetBeat: 2),
  ],
);

Future<FakeAudio> pumpPage(
  WidgetTester tester,
  SightScore score, {
  FakeClock? clock,
  ManualBeatScheduler? scheduler,
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final audio = FakeAudio();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioServiceProvider.overrideWithValue(audio),
        clockProvider.overrideWithValue(clock ?? FakeClock()),
      ],
      child: MaterialApp(
        home: SightSessionPage(
          score: score,
          beatScheduler: scheduler ?? ManualBeatScheduler(),
          countdownSeconds: 0,
          // 沿用 T01 阶梯 L1 的四分音符速度（♩=50），保持既有拍长断言。
          quartersPerMinute: 50,
        ),
      ),
    ),
  );
  await tester.pump();
  return audio;
}

/// 点按某个 diatonicIndex 对应的屏幕琴键。
/// 双手模式有 29 键，窄屏下目标键可能在横向滚动区外，先滚到可见再点。
Future<void> tapNote(WidgetTester tester, int diatonicIndex) async {
  final finder = find.byKey(ValueKey('key_${midiOf(diatonicIndex)}'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

/// 把假时钟推进到下一拍 onset。
Future<void> reachBeat(
  WidgetTester tester,
  FakeClock clock,
  ManualBeatScheduler scheduler,
) async {
  final delay = scheduler.nextDelayMs;
  if (delay > 0) clock.advance(Duration(milliseconds: delay));
  await tester.pump();
}

/// 触发拍结算并刷新 UI。
Future<void> fireBeat(
  WidgetTester tester,
  ManualBeatScheduler scheduler,
) async {
  scheduler.fireAll();
  await tester.pump();
}

/// 完整答一拍：到 onset → 提交（不推进）→ fire tick（推进 + 四色）。
Future<void> answerBeat(
  WidgetTester tester,
  FakeClock clock,
  ManualBeatScheduler scheduler,
  int index,
) async {
  await reachBeat(tester, clock, scheduler);
  await tapNote(tester, index);
  await fireBeat(tester, scheduler);
}

GrandStaffView staff(WidgetTester tester) =>
    tester.widget<GrandStaffView>(find.byType(GrandStaffView));

/// 页面内 GrandStaffView 使用的横向滚动 controller（页面持有）。
ScrollController staffScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.descendant(
      of: find.byType(GrandStaffView),
      matching: find.byType(SingleChildScrollView),
    ))
    .controller!;

void main() {
  testWidgets('单手高音谱例：渲染谱表与键盘', (tester) async {
    await pumpPage(tester, trebleScore([0, 1, 2, 3]));
    expect(find.text('右手练习'), findsOneWidget);
    expect(find.byType(GrandStaffView), findsOneWidget);
    expect(find.byType(VirtualKeyboard), findsOneWidget);
    expect(staff(tester).upperCursorColumn, 0);
    expect(staff(tester).lowerCursorColumn, isNull);
    // 进度区初始状态。
    expect(find.text('已完成 0/4'), findsOneWidget);
    expect(find.text('错误 0'), findsOneWidget);
  });

  testWidgets('答对第一个音：submit 不前进，tick 后上光标到第 2 列',
      (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    final audio = await pumpPage(tester, trebleScore([0, 1, 2, 3]),
        clock: clock, scheduler: scheduler);
    await reachBeat(tester, clock, scheduler);
    await tapNote(tester, 0);
    expect(staff(tester).upperCursorColumn, 0, reason: 'submit 不推进');
    expect(find.text('已完成 0/4'), findsOneWidget);

    await fireBeat(tester, scheduler);
    expect(staff(tester).upperCursorColumn, 1);
    expect(find.text('已完成 1/4'), findsOneWidget);
    expect(audio.played, [midiOf(0)]); // 输入即回放该音
  });

  testWidgets('漏拍也推进：无输入时 tick 记 miss 且光标前移', (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1, 2, 3]),
        clock: clock, scheduler: scheduler);
    await reachBeat(tester, clock, scheduler);
    await tapNote(tester, 2); // 目标 C4，按 E4：入槽但不匹配
    expect(staff(tester).upperCursorColumn, 0);
    await fireBeat(tester, scheduler);
    await tester.pump(const Duration(milliseconds: 250)); // 等抖动动画结束
    expect(staff(tester).upperCursorColumn, 1, reason: 'miss 也推进');
    expect(find.text('错误 1'), findsOneWidget);
    // 光标前移但 miss 不算命中，故「已完成」仍是 0/4。
    expect(find.text('已完成 0/4'), findsOneWidget);
    expect(staff(tester).upperGrades?[0], isNotNull);
  });

  testWidgets('依次答完所有音：出现完成统计与新指标', (tester) async {
    final clock = FakeClock(monoMs: 1000);
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1, 2, 3, 4, 5, 6, 7]),
        clock: clock, scheduler: scheduler);
    // 首拍 reachBeat 还会推进一个引导拍（1200ms），这里先扣掉，净用时正好 75s。
    clock.advance(const Duration(milliseconds: 75000 - 1200));
    for (final note in [0, 1, 2, 3, 4, 5, 6, 7]) {
      await answerBeat(tester, clock, scheduler, note);
    }
    expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    expect(find.text('再来一条'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    expect(find.text('01:15'), findsOneWidget); // 用时 mm:ss
    expect(find.text('100%'), findsOneWidget);
    expect(find.byKey(const Key('sight_stat_onbeat')), findsOneWidget);
    expect(find.byKey(const Key('sight_stat_bias')), findsOneWidget);
    expect(find.byKey(const Key('sight_stat_streak')), findsOneWidget);
    expect(find.text('8'), findsOneWidget); // 最长连续命中
    expect(find.byKey(const Key('sight_grade_band')), findsOneWidget);
    expect(find.byType(VirtualKeyboard), findsNothing);
  });

  testWidgets('双声部按拍各自结算：下声部第 0 拍先走，上声部第 1 拍才走',
      (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, staggeredGrandScore(),
        clock: clock, scheduler: scheduler);
    // 上声部首个音在第 1 列（第 0 列只有下声部音）。
    expect(staff(tester).upperCursorColumn, 1);
    expect(staff(tester).lowerCursorColumn, 0);

    await answerBeat(tester, clock, scheduler, -7);
    expect(staff(tester).lowerCursorColumn, isNull, reason: '下声部已完成');
    expect(staff(tester).upperCursorColumn, 1, reason: '上声部本拍无待答音，仍停在第 1 列');

    await answerBeat(tester, clock, scheduler, 0);
    expect(staff(tester).upperCursorColumn, 2);
    expect(staff(tester).lowerCursorColumn, isNull);
  });

  testWidgets('同音连错 3 次：跨阈值才浮现音名，1.5s 后消失', (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1, 2, 3]),
        clock: clock, scheduler: scheduler);
    for (var i = 0; i < 3; i++) {
      await answerBeat(tester, clock, scheduler, 9); // 目标 C4/D4/E4，一直按 A5
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('错误 3'), findsOneWidget);
    // 提示指向结算后的当前待答音（第 4 列），按拍语义下提示「下一个该弹什么」。
    expect(staff(tester).upperHintColumns, {3});
    await tester.pump(const Duration(milliseconds: 1600));
    expect(staff(tester).upperHintColumns, isEmpty);
  });

  testWidgets('完成页易错音位 top3：先错后对仍有「易错」行', (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1, 2, 3]),
        clock: clock, scheduler: scheduler);
    await answerBeat(tester, clock, scheduler, 5); // 目标 C4，按 A4 → 记 C4 一次错误
    for (final note in [1, 2, 3]) {
      await answerBeat(tester, clock, scheduler, note);
    }
    expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    expect(find.textContaining('易错'), findsOneWidget);
    expect(find.text('易错：C4×1'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget); // 3 对 1 错 → 3/4
  });

  testWidgets('完成页无错误时不显示「易错」行', (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1]),
        clock: clock, scheduler: scheduler);
    await answerBeat(tester, clock, scheduler, 0);
    await answerBeat(tester, clock, scheduler, 1);
    expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    expect(find.byKey(const Key('sight_error_positions')), findsNothing);
    expect(find.textContaining('易错'), findsNothing);
  });

  testWidgets('「再来一条」：生成新谱例并重置进度、四色与光标', (tester) async {
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await pumpPage(tester, trebleScore([0, 1, 2, 3]),
        clock: clock, scheduler: scheduler);
    for (final note in [0, 1, 2, 3]) {
      await answerBeat(tester, clock, scheduler, note);
    }
    expect(find.text('再来一条'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sight_again')));
    await tester.pump();

    expect(find.byType(GrandStaffView), findsOneWidget);
    expect(find.byType(VirtualKeyboard), findsOneWidget);
    expect(find.text('已完成 0/4'), findsOneWidget);
    expect(find.text('错误 0'), findsOneWidget);
    expect(staff(tester).upperCursorColumn, 0);
    expect(staff(tester).upperGrades, isEmpty);
  });

  testWidgets('完成瞬间落库一条 sight_read_log；再来一条不重复写', (tester) async {
    late Database db;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      db = await openTestDb();
    });
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final clock = FakeClock(monoMs: 500, utcMs: 1700000000000);
    final scheduler = ManualBeatScheduler();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        audioServiceProvider.overrideWithValue(FakeAudio()),
        clockProvider.overrideWithValue(clock),
        databaseProvider.overrideWith((ref) async => db),
      ],
      child: MaterialApp(
        home: SightSessionPage(
          score: trebleScore([0, 1]),
          source: 'score',
          scoreRef: 'sr_treble_01',
          beatScheduler: scheduler,
          countdownSeconds: 0,
        ),
      ),
    ));
    await tester.pump();

    clock.advance(const Duration(seconds: 2));
    // 不推进到 onset：两拍都在同一假时钟读数上结算，保持 2s 用时断言。
    await tapNote(tester, 0);
    await fireBeat(tester, scheduler);
    await tapNote(tester, 1);
    await fireBeat(tester, scheduler);
    expect(find.byKey(const Key('sight_summary')), findsOneWidget);

    Future<List<SightReadRecord>> rows() =>
        SightReadRepo(db).recent();
    var records = <SightReadRecord>[];
    await tester.runAsync(() async {
      for (var i = 0; i < 30 && records.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        records = await rows();
      }
    });
    expect(records, hasLength(1));
    expect(records.first.mode, SightMode.trebleOnly);
    expect(records.first.source, 'score');
    expect(records.first.scoreRef, 'sr_treble_01');
    expect(records.first.columnCount, 2);
    expect(records.first.totalNotes, 2);
    expect(records.first.correctNotes, 2);
    expect(records.first.errorCount, 0);
    expect(records.first.durationMs, 2000);
    expect(records.first.finishedAt, 1700000002000);

    await tester.tap(find.byKey(const Key('sight_again')));
    await tester.pump();
    clock.advance(const Duration(seconds: 3));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    expect(await tester.runAsync(rows), hasLength(1));

    for (final column in staff(tester).columns) {
      await tapNote(tester, column.upper!);
      await fireBeat(tester, scheduler);
    }
    expect(find.byKey(const Key('sight_summary')), findsOneWidget);
    records = <SightReadRecord>[];
    await tester.runAsync(() async {
      for (var i = 0; i < 30 && records.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        records = await rows();
      }
    });
    expect(records, hasLength(2));
    expect(records.first.source, 'generated');
    expect(records.first.scoreRef, isNull);
    expect(records.last.scoreRef, 'sr_treble_01');
  });

  testWidgets('手机竖屏双手 8 列：布局不溢出，键盘含 C2–C6', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final score = SightScore(
      mode: SightMode.grand,
      columns: [
        for (var i = 0; i < 8; i++)
          SightColumn(upper: 8 + i % 5, lower: -12 + i % 5),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioServiceProvider.overrideWithValue(FakeAudio()),
          clockProvider.overrideWithValue(FakeClock()),
        ],
        child: MaterialApp(
          home: SightSessionPage(score: score, countdownSeconds: 0),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(GrandStaffView), findsOneWidget);
    expect(find.byKey(const ValueKey('octave_jump_C2')), findsOneWidget);
    expect(find.byKey(const ValueKey('octave_jump_C6')), findsOneWidget);
  });

  testWidgets('长谱例答对前 8 个音：谱面自动跟随光标滚动', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 24 音单手高音：手机窄屏下 24 列必然溢出（列宽最小 30dp）。
    final notes = List<int>.generate(24, (i) => 2 + i % 10);
    final clock = FakeClock();
    final scheduler = ManualBeatScheduler();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioServiceProvider.overrideWithValue(FakeAudio()),
          clockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: SightSessionPage(
            score: trebleScore(notes),
            beatScheduler: scheduler,
            countdownSeconds: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = staffScroll(tester);
    expect(scroll.offset, 0);

    for (final note in notes.take(8)) {
      await answerBeat(tester, clock, scheduler, note);
    }
    await tester.pumpAndSettle();
    expect(staff(tester).upperCursorColumn, 8);
    expect(scroll.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
