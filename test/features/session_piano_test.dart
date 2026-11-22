// 规格: 02 §10.2 —— 蓝牙电钢琴作答（MIDI note-on → AnswerEvent）。
// 用假 MIDI 服务验证：八度校验、黑键判错、断连回退键盘、前置闪现期拦截。
@Tags(['widget'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/piano_midi.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/data/repositories/phrase_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/data/session_service.dart';
import 'package:sight_reading/domain/course.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/domain/scheduler.dart';
import 'package:sight_reading/domain/session_engine.dart';
import 'package:sight_reading/features/diagnosis/diagnosis_controller.dart'
    show Delayer;
import 'package:sight_reading/features/session/session_page.dart';
import 'package:sight_reading/ui/name_buttons.dart';
import 'package:sight_reading/ui/virtual_keyboard.dart';

import '../data/test_db.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async {}
  @override
  Future<void> playComparison(
      {required int answerMidi,
      required int correctMidi,
      Duration gap = const Duration(milliseconds: 400)}) async {}
  @override
  Future<void> playSequence(List<int> midis,
      {Duration interval = const Duration(milliseconds: 500)}) async {}
  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

class FakeDelayer implements Delayer {
  final List<(int, Completer<void>)> _pending = [];
  int _now = 0;
  @override
  Future<void> delay(Duration d) {
    final c = Completer<void>();
    _pending.add((_now + d.inMilliseconds, c));
    return c.future;
  }

  void elapse(int ms) {
    _now += ms;
    final due = _pending.where((p) => p.$1 <= _now).toList();
    _pending.removeWhere((p) => p.$1 <= _now);
    for (final p in due) {
      p.$2.complete();
    }
  }
}

class FakeRecorder implements TrialRecorder {
  final List<Trial> trials = [];
  @override
  void record(Trial trial, Mastery mastery, (int, int)? seedPair) =>
      trials.add(trial);
  @override
  void recordPhrase(PhraseRecord record) {}
}

class FakeSource implements SessionDataSource {
  @override
  Mastery masteryOf(int itemId) =>
      Mastery(itemId: itemId, state: ItemState.learning);
  @override
  List<TrialResult> recentResults(int itemId, int limit) => const [];
  @override
  List<TrialResult> relationHistoryFor(int targetIndex) => const [];
  @override
  Mastery? directMasteryOf(int diatonicIndex) => null;
  @override
  List<int> relationItemIdsFor(int diatonicIndex) => const [];
  @override
  void saveMastery(Mastery m) {}
}

class FakePiano implements PianoMidiService {
  final StreamController<PianoConnectionState> _stateCtrl =
      StreamController<PianoConnectionState>.broadcast();
  final StreamController<List<PianoDevice>> _deviceCtrl =
      StreamController<List<PianoDevice>>.broadcast();
  final StreamController<PianoNoteEvent> _noteCtrl =
      StreamController<PianoNoteEvent>.broadcast();

  PianoConnectionState _state = PianoConnectionState.disconnected;
  PianoDevice? _connected;

  static const PianoDevice fp18 = PianoDevice(
    id: 'fp18-test',
    name: 'FP-18',
    transport: PianoTransport.ble,
    profileId: 'roland_fp18',
    profileLabel: 'Roland FP-18',
  );

  @override
  bool get isSupported => true;
  @override
  PianoConnectionState get connectionState => _state;
  @override
  PianoDevice? get connectedDevice => _connected;
  @override
  List<PianoDevice> get devices => const [fp18];
  @override
  String? get lastError => null;
  @override
  List<String> get logLines => const [];
  @override
  Stream<PianoConnectionState> get connectionStateChanges =>
      _stateCtrl.stream;
  @override
  Stream<List<PianoDevice>> get deviceChanges => _deviceCtrl.stream;
  @override
  Stream<PianoNoteEvent> get noteEvents => _noteCtrl.stream;

  void connectNow() {
    _connected = fp18;
    _state = PianoConnectionState.connected;
    _stateCtrl.add(_state);
  }

  void disconnectNow() {
    _connected = null;
    _state = PianoConnectionState.disconnected;
    _stateCtrl.add(_state);
  }

  void emitNote(int midi, {int velocity = 90}) {
    _noteCtrl.add(PianoNoteEvent(
      midiNote: midi,
      velocity: velocity,
      deviceName: 'FP-18',
    ));
  }

  @override
  Future<void> startScan() async {}
  @override
  void stopScan() {}
  @override
  Future<void> connect(PianoDevice device) async => connectNow();
  @override
  Future<void> disconnect() async => disconnectNow();
  @override
  Future<void> reconnect() async => connectNow();
  @override
  Future<void> dispose() async {}
}

QueueEntry makeEntry(int id, int index, {bool prelude = false}) => QueueEntry(
      item: Item(
        id: id,
        type: ItemType.direct,
        payload: DirectPayload(diatonicIndex: index),
        createdAt: 0,
      ),
      mastery: Mastery(itemId: id, state: ItemState.learning),
      context: ContextSnapshot(
          clef: Clef.treble, jitterSeed: id * 7 + 1, preludeAnchor: prelude),
      segment: QueueSegment.direct,
    );

class Harness {
  final SessionBundle bundle;
  final FakeRecorder rec;
  final FakeClock clock;
  final FakeDelayer delayer;
  final FakePiano piano;
  final Database db;
  Harness(
      this.bundle, this.rec, this.clock, this.delayer, this.piano, this.db);

  SessionEngine get engine => bundle.engine;
}

Future<Harness> setup(WidgetTester tester, List<QueueEntry> queue) async {
  final rec = FakeRecorder();
  final clock = FakeClock();
  final delayer = FakeDelayer();
  final piano = FakePiano()..connectNow();
  late SessionBundle bundle;
  late Database db;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    db = await openTestDb();
    final sessionId = await SessionRepo(db).insert(Session(
      date: '2026-11-20',
      startedAt: 0,
      plannedCount: queue.length,
    ));
    final engine = SessionEngine(
      config: Config.defaults,
      clock: clock,
      rng: rng(42),
      recorder: rec,
      source: FakeSource(),
      sessionId: sessionId,
      stage: 1,
      mode: InputMode.piano,
      queue: queue,
      sessionEndTs: 9999999,
    );
    final dbSource = await DbSessionDataSource.load(db);
    bundle = SessionBundle(
      engine: engine,
      plan: QueuePlan(
          entries: queue,
          noDueReview: false,
          carryoverIds: const {},
          c2Relaxed: false),
      sessionId: sessionId,
      stage: 1,
      activeAnchors: const {0, 4},
      diagnosisDone: true,
      source: dbSource,
      recorder: DbTrialRecorder(
        trialRepo: TrialRepo(db),
        phraseRepo: PhraseRepo(db),
        source: dbSource,
      ),
      advance: const AdvanceDecision(
          currentStage: 1,
          ratio: 0,
          canAdvance: false,
          nextStage: 1,
          microLessonNextSession: false),
    );
  });
  return Harness(bundle, rec, clock, delayer, piano, db);
}

Future<void> pumpPage(WidgetTester tester, Harness h) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => h.db),
      configProvider.overrideWith(
          (ref) async => const Config(inputMode: InputMode.piano)),
      audioServiceProvider.overrideWithValue(FakeAudio()),
      clockProvider.overrideWithValue(h.clock),
      pianoMidiServiceProvider.overrideWithValue(h.piano),
    ],
    child: MaterialApp(
      home: SessionPage(bundle: h.bundle, delayer: h.delayer),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> nextQuestion(WidgetTester tester, Harness h) async {
  h.delayer.elapse(600);
  await tester.pump();
  h.delayer.elapse(800);
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('电钢琴按键作答：自然音正确，source=MIDI，八度校验生效',
      (tester) async {
    final h = await setup(tester, [
      makeEntry(1, 4), // G4
      makeEntry(2, 0), // C4
      makeEntry(3, 4), // G4
    ]);
    await pumpPage(tester, h);
    expect(find.textContaining('电钢琴已连接'), findsOneWidget);
    expect(find.byType(NameButtons), findsNothing);
    expect(find.byType(VirtualKeyboard), findsNothing);

    h.clock.monoMs += 800;
    h.piano.emitNote(67); // G4
    await tester.pump();
    expect(h.rec.trials.single.correct, isTrue);
    expect(h.rec.trials.single.inputSource, InputSource.midi);
    expect(h.rec.trials.single.rtMs, 800);
    expect(h.rec.trials.single.answerPitchClass, 'G');

    await nextQuestion(tester, h);
    expect(h.engine.current!.item.id, 2);

    // 正确音名、错误八度（C5=72，目标 C4）→ 八度错误。
    h.clock.monoMs += 500;
    h.piano.emitNote(72);
    await tester.pump();
    expect(h.rec.trials.last.correct, isFalse);
    expect(h.rec.trials.last.errorType, ErrorType.octave);
    expect(h.rec.trials.last.inputSource, InputSource.midi);

    await nextQuestion(tester, h);
    await exitSession(tester, h);
  });

  testWidgets('黑键按错误答案记录（C#4 → other，绝不判对）', (tester) async {
    final h = await setup(tester, [
      makeEntry(1, 0), // C4
      makeEntry(2, 4),
    ]);
    await pumpPage(tester, h);
    h.piano.emitNote(61); // C#4
    await tester.pump();
    expect(h.rec.trials.single.correct, isFalse);
    expect(h.rec.trials.single.answerPitchClass, 'C#');
    expect(h.rec.trials.single.answerOctave, 4);
    expect(h.rec.trials.single.errorType, ErrorType.other);
    await nextQuestion(tester, h);
    await exitSession(tester, h);
  });

  testWidgets('会话中断连：提示并回退屏幕键盘，按键不再作答', (tester) async {
    final h = await setup(tester, [
      makeEntry(1, 4),
      makeEntry(2, 0),
    ]);
    await pumpPage(tester, h);
    expect(find.byType(VirtualKeyboard), findsNothing);

    h.piano.disconnectNow();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('已切换屏幕键盘'), findsOneWidget);
    expect(find.byType(VirtualKeyboard), findsOneWidget);

    h.piano.emitNote(67); // 断连后的残留事件应被忽略
    await tester.pump();
    expect(h.rec.trials, isEmpty);

    h.piano.connectNow();
    await tester.pump();
    await tester.pump();
    expect(find.byType(VirtualKeyboard), findsNothing);
    expect(find.textContaining('电钢琴已连接'), findsOneWidget);

    h.piano.emitNote(67);
    await tester.pump();
    expect(h.rec.trials.single.correct, isTrue);
    await nextQuestion(tester, h);
    await exitSession(tester, h);
  });

  testWidgets('前置参照闪现期间按键无效，闪现结束后才计入 RT', (tester) async {
    final h = await setup(tester, [
      makeEntry(1, 4, prelude: true),
      makeEntry(2, 0),
    ]);
    await pumpPage(tester, h);
    expect(find.byKey(const Key('prelude_caption')), findsOneWidget);

    h.piano.emitNote(67);
    await tester.pump();
    expect(h.rec.trials, isEmpty);
    expect(h.engine.phase, SessionPhase.presenting);

    h.delayer.elapse(500);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    h.clock.monoMs += 400;
    h.piano.emitNote(67);
    await tester.pump();
    expect(h.rec.trials.single.rtMs, 400);
    expect(h.rec.trials.single.correct, isTrue);
    await nextQuestion(tester, h);
    await exitSession(tester, h);
  });
}

Future<void> exitSession(WidgetTester tester, Harness h) async {
  await tester.tap(find.byKey(const Key('session_exit')));
  await tester.pump();
  await tester.tap(find.text('退出'));
  await tester.pump();
  await tester.runAsync(() async {
    await h.bundle.flush();
  });
}