// 规格: 06 §2 S3（统一出题器框架、题型差异、反馈时序）/ 05 §9 / 02 §7。
// 会话执行页：驱动 SessionEngine 状态机，渲染谱表/提示/反馈/输入。
// M4 增强: 02 §4.2 直认前置锚点闪现 / §4.1 §4.3 掌握度事件横幅 /
//          §2.2 + 05 §4 锚点重建立微循环 / §5.3 阶段4 短句走向判断。
//
// M4 裁决记录:
// 1) 重建立微循环的 5 题慢练为页面本地编排：不落库、不推进引擎队列
//    （05 §4 未定义慢练试次是否落库；最小实现避免引擎状态复杂化）。
//    引擎无 feedback 相位重呈 API（onResume 仅接受 paused），微循环结束后
//    以 engine.next() 恢复队列；触发的锚点错题已由 ReexposureScheduler
//    预约 2–4 题后换上下文复现（05 §3 C3），等效"回限时闪现"。
// 2) 走向判断正确性仅作观测指标（02 §5.3），不落库；判断展示 600ms 后
//    重新记 onset，首音 RT 不含走向判断时间。
// 3) 前置锚点闪现时长取 config.anchorPreludeMs 的前半（默认 1000/2=500ms，
//    02 §4.2"闪现 0.5s 后消失"）；onset 在目标音呈现后的 post-frame 记录。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../../core/clock.dart';
import '../../core/config.dart';
import '../../core/piano_midi.dart';
import '../../core/providers.dart';
import '../../data/repositories/session_repo.dart';
import '../../data/session_service.dart';
import '../../data/session_summary.dart';
import '../../domain/mastery.dart';
import '../../domain/models/answer_event.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/item.dart';
import '../../domain/models/note_position.dart';
import '../../domain/scheduler.dart';
import '../../domain/session_engine.dart';
import '../../ui/answer_input.dart';
import '../../ui/feedback_overlay.dart';
import '../../ui/hint_panel.dart';
import '../../ui/name_buttons.dart';
import '../../ui/progress_header.dart';
import '../../ui/staff_view.dart';
import '../../ui/virtual_keyboard.dart';
import '../diagnosis/diagnosis_controller.dart' show Delayer, RealDelayer;
import '../progress/mastery_map_page.dart';
import 'session_summary_view.dart';

class SessionPage extends ConsumerStatefulWidget {
  const SessionPage({
    super.key,
    required this.bundle,
    this.delayer = const RealDelayer(),
    this.onFinished,
    this.dbOverride,
  });

  final SessionBundle bundle;
  final Delayer delayer;
  final VoidCallback? onFinished;

  /// 试玩模式：整个会话（落库 + 总结）走这个内存库，不碰正式数据。
  final Database? dbOverride;

  @override
  ConsumerState<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends ConsumerState<SessionPage>
    with WidgetsBindingObserver {
  SessionEngine get engine => widget.bundle.engine;
  Config get config => ref.read(configProvider).value ?? Config.defaults;
  Clock get clock => ref.read(clockProvider);

  Timer? _limitTicker;
  int _limitTotalMs = 0;
  int _remainingMs = 0;

  // 键盘模式计时宽限（裁决：02 §8.6 限时未区分输入模式，键盘找八度耗时
  // 全算进闪现限时导致"搭不上第一个"）。按下不计时：定位完成
  // （滑动抬手/八度跳转）才开始倒计时，上限 keyLimitGraceMs 后强制启动；
  // 点按即作答不依赖倒计时。平板键盘全宽可见无需找音，正常计时。
  // RT 口径：从呈现起算，但扣除导航耗时（滑动/跳转是 UI 开销不是认谱
  // 反应，真实钢琴无需滑动琴键）；干等思考时间照算。宽限等待期显示
  // 实时正计时，让"时间在记录"可见。
  Timer? _limitGrace;
  Timer? _graceTicker;
  bool _limitAwaitingTouch = false;
  int _graceStartMono = 0;
  int? _navStartMono;

  /// 键盘滚动位置跨题持久化（上方部件增减会重建键盘组件）。
  late final ScrollController _keyboardScroll;

  bool _showFeedback = false;
  bool _blank = false;
  int _hintLevel = 0;
  bool _hintRequested = false;
  bool _resetAnchorVisible = false;
  bool _finishing = false;

  /// 会话总结数据（S4，进入 summary 时刷新）。
  SessionSummaryData? _summary;

  // 直认前置锚点闪现（02 §4.2）。_presentToken 使旧的异步编排失效。
  bool _preludeVisible = false;
  int _presentToken = 0;

  /// 失焦前本题是否已呈现过目标音：恢复时重放前置锚点会让题目闪回，故跳过。
  bool _wasAwaitingOnBackground = false;

  // 蓝牙电钢琴输入（02 §10.2）：应用级服务，页面只订阅事件与连接状态。
  StreamSubscription<PianoNoteEvent>? _pianoNoteSub;
  StreamSubscription<PianoConnectionState>? _pianoStateSub;

  // 掌握度事件横幅（02 §4.1 §4.3）。
  int _seenEvents = 0;
  String? _bannerText;
  int _bannerToken = 0;

  // 锚点重建立微循环（02 §2.2 / 05 §4，页面本地编排，见文件头裁决 1）。
  bool _rebuildPending = false;
  bool _rebuildCard = false;
  int _rebuildRemaining = 0;
  int? _rebuildAnchor;
  bool? _rebuildFeedback;
  Completer<String>? _rebuildAnswer;

  /// 慢练期间每题换呈现位置（防 5 题一模一样）。
  int _rebuildSeed = 0;

  // 阶段4 短句走向判断（02 §5.3，观测指标不落库，见文件头裁决 2）。
  bool _directionPending = false;
  bool? _directionResult;

  bool get _rebuildActive => _rebuildCard || _rebuildRemaining > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final piano = ref.read(pianoMidiServiceProvider);
    _pianoNoteSub = piano.noteEvents.listen(_onPianoNote);
    _pianoStateSub = piano.connectionStateChanges.listen((_) {
      if (mounted) setState(() {});
    });
    engine.start();
    // 首题初始视口：目标所在八度的 C（左留一键），避免从 C3 盲找第一题。
    _keyboardScroll =
        ScrollController(initialScrollOffset: _firstQuestionKeyboardOffset());
    // 窄视口下初始偏移可能超过最大滚动量，布局后夹紧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_keyboardScroll.hasClients) return;
      final max = _keyboardScroll.position.maxScrollExtent;
      if (_keyboardScroll.offset > max) _keyboardScroll.jumpTo(max);
    });
    if (engine.phase == SessionPhase.summary) {
      unawaited(_finish());
    } else {
      _beginPresent();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_pianoNoteSub?.cancel());
    unawaited(_pianoStateSub?.cancel());
    _limitTicker?.cancel();
    _limitGrace?.cancel();
    _graceTicker?.cancel();
    _keyboardScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 05 §9：退后台未答题作废，恢复重呈同题。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _limitTicker?.cancel();
      _limitGrace?.cancel();
      _graceTicker?.cancel();
      _limitAwaitingTouch = false;
      _navStartMono = null;
      _presentToken++; // 作废前置闪现/走向判断的异步续段。
      // inactive 后还会来一次 paused（此时 phase 已变），只置位不清位。
      if (engine.phase == SessionPhase.awaitingAnswer) {
        _wasAwaitingOnBackground = true;
      }
      engine.onBackground();
      setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      if (engine.phase == SessionPhase.paused) {
        final skipPrelude = _wasAwaitingOnBackground;
        _wasAwaitingOnBackground = false;
        engine.onResume();
        _beginPresent(skipPrelude: skipPrelude);
      }
    }
  }

  QueueEntry? get _entry => engine.current;

  /// 首题键盘视口：目标所在八度的 C 左移一键（不居中目标键，保留八度内找音）。
  /// 目标为短句时取首音。平板全宽键盘无滚动，偏移被忽略。
  double _firstQuestionKeyboardOffset() {
    final entry = _entry;
    if (entry == null) return 0;
    final note = entry.item.type == ItemType.phrase
        ? (entry.item.payload as PhrasePayload).noteSequence.first
        : entry.item.targetIndices.last;
    final midi = midiOf(note);
    // C3=48 起每 12 半音一个八度；C6 归入 C5 视口（键盘最右）。
    final octave = ((midi - 48) ~/ 12).clamp(0, 2);
    final keyIndex = (octave * 7 - 1).clamp(0, 21);
    return keyIndex * VirtualKeyboard.minKeyWidth;
  }

  bool get _isFlash {
    final t = _entry?.item.type;
    return t == ItemType.anchor || t == ItemType.direct;
  }

  bool get _isRelation => _entry?.item.type == ItemType.relation;
  bool get _isPhrase => _entry?.item.type == ItemType.phrase;

  /// 呈现刺激 → post-frame 记 onset（03 §2）。
  /// DIRECT 且 context.preludeAnchor：先闪现前置锚点 500ms（02 §4.2），
  /// 前置期间 phase 保持 presenting（按钮禁用），目标音呈现后才记 onset。
  /// [skipPrelude]：失焦恢复时目标音已呈现过，只重呈目标音（避免闪回锚点）。
  void _beginPresent({bool skipPrelude = false}) {
    _hintLevel = _isRelation ? (_entry?.mastery.hintLevel ?? 0) : 0;
    _hintRequested = false;
    _blank = false;
    _directionPending = false;
    _directionResult = null;
    _limitTotalMs = 0;
    _limitGrace?.cancel();
    _graceTicker?.cancel();
    _limitAwaitingTouch = false;
    _navStartMono = null;
    final entry = _entry;
    final prelude = !skipPrelude &&
        entry != null &&
        entry.item.type == ItemType.direct &&
        entry.context.preludeAnchor &&
        widget.bundle.activeAnchors.isNotEmpty;
    _preludeVisible = prelude;
    final token = ++_presentToken;
    setState(() {});
    if (prelude) {
      unawaited(_runPrelude(token));
    } else {
      _markOnset();
    }
  }

  Future<void> _runPrelude(int token) async {
    await widget.delayer
        .delay(Duration(milliseconds: config.anchorPreludeMs ~/ 2));
    if (!mounted ||
        token != _presentToken ||
        engine.phase != SessionPhase.presenting) {
      return;
    }
    setState(() => _preludeVisible = false);
    _markOnset();
  }

  void _markOnset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || engine.phase != SessionPhase.presenting) return;
      engine.onPresented();
      _graceStartMono = clock.monotonicMs();
      // 阶段4 短句首音：先走向判断再逐音命名（02 §5.3）；阶段5 默认关闭。
      if (_isPhrase && widget.bundle.stage == 4 && engine.phraseSlot == 0) {
        _directionPending = true;
      }
      setState(() {});
      _startLimit();
    });
  }

  /// 作答后消费 engine.events 新增事件（02 §4.1 §4.3）：横幅 2s；
  /// RebuildTriggerEvent 预约重建立微循环。返回是否触发重建立。
  bool _consumeEvents() {
    var rebuild = false;
    while (_seenEvents < engine.events.length) {
      final ev = engine.events[_seenEvents++];
      switch (ev) {
        case PromotionEvent():
          unawaited(_showBanner(
              '直认激活：${NotePosition.of(ev.diatonicIndex).displayName}'));
        case RelapseEvent():
          unawaited(_showBanner(
              '直认回退：${NotePosition.of(ev.diatonicIndex).displayName}，回到关系练习'));
        case RebuildTriggerEvent():
          // 去重：微循环进行中不重复触发。
          if (!_rebuildActive && !_rebuildPending) {
            rebuild = true;
            _rebuildAnchor =
                (_entry!.item.payload as AnchorPayload).diatonicIndex;
            unawaited(_showBanner('锚点重建立：进入慢速练习'));
          }
      }
    }
    return rebuild;
  }

  Future<void> _showBanner(String text) async {
    final token = ++_bannerToken;
    setState(() => _bannerText = text);
    await widget.delayer.delay(const Duration(milliseconds: 2000));
    if (!mounted || token != _bannerToken) return;
    setState(() => _bannerText = null);
  }

  /// 锚点重建立微循环（02 §2.2 / 05 §4）：展示卡 3s（常亮+音名标注+播音）
  /// → 5 题不限时慢练（同锚点，本地编排，不落库不推进引擎，见文件头裁决 1）。
  Future<void> _runRebuild() async {
    final anchor = _rebuildAnchor!;
    _presentToken++; // 使旧呈现/走向编排失效。
    setState(() {
      _rebuildCard = true;
      _rebuildRemaining = 5;
      _rebuildFeedback = null;
    });
    unawaited(ref.read(audioServiceProvider).playNote(midiOf(anchor)));
    await widget.delayer.delay(const Duration(milliseconds: 3000));
    if (!mounted) return;
    setState(() => _rebuildCard = false);
    for (var i = 0; i < 5; i++) {
      final c = Completer<String>();
      _rebuildAnswer = c;
      setState(() {
        _rebuildRemaining = 5 - i;
        _rebuildFeedback = null;
        // 慢练每题换呈现位置（02 §2.2 位置抖动防记忆），避免 5 题一模一样。
        _rebuildSeed = _entry!.context.jitterSeed + i * 37;
      });
      final pc = await c.future;
      _rebuildAnswer = null;
      if (!mounted) return;
      final ok = pc == pitchClassOf(anchor);
      setState(() => _rebuildFeedback = ok);
      final audio = ref.read(audioServiceProvider);
      if (ok) {
        await audio.playNote(midiOf(anchor));
      } else {
        await audio.playComparison(
          answerMidi: midiOf(_answerIndex(pc)),
          correctMidi: midiOf(anchor),
          gap: Duration(milliseconds: config.wrongAnswerGapMs),
        );
      }
      await widget.delayer.delay(const Duration(milliseconds: 600));
      if (!mounted) return;
    }
    setState(() {
      _rebuildRemaining = 0;
      _rebuildFeedback = null;
    });
  }

  /// 短句实际走向：相邻音程全正=上行、全负=下行、否则混合（02 §5.3）。
  String _phraseDirection(List<int> seq) {
    var up = true;
    var down = true;
    for (var i = 1; i < seq.length; i++) {
      final d = seq[i] - seq[i - 1];
      if (d <= 0) up = false;
      if (d >= 0) down = false;
    }
    return up ? '上行' : (down ? '下行' : '混合');
  }

  Future<void> _onDirection(String choice) async {
    if (!_directionPending || _entry == null) return;
    final seq = (_entry!.item.payload as PhrasePayload).noteSequence;
    final ok = choice == _phraseDirection(seq);
    final token = _presentToken;
    setState(() {
      _directionPending = false;
      _directionResult = ok; // 观测指标：仅展示，不落库（文件头裁决 2）。
    });
    await widget.delayer.delay(const Duration(milliseconds: 600));
    if (!mounted || token != _presentToken) return;
    setState(() => _directionResult = null);
    // 重新记 onset：首音 RT 从逐音命名开始（文件头裁决 2）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      engine.onPresented();
      setState(() {});
    });
  }

  /// 短句下一音（引擎已处于 awaitingAnswer）。
  void _beginPhraseNote() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      engine.onPresented();
      setState(() {});
    });
  }

  /// 闪现限时（02 §8.6：锚点 3s→1.5s、直认 2.5s→1.2s；宽松 ×1.5）。
  /// 收紧裁决：state∈{reviewing,automated} 用 min 档，其余用默认档。
  /// 键盘模式（手机）：倒计时等定位完成才启动（滑动找音免费），上限后强制启动。
  void _startLimit() {
    _limitTicker?.cancel();
    _limitGrace?.cancel();
    _limitAwaitingTouch = false;
    if (!_isFlash || engine.phase != SessionPhase.awaitingAnswer) return;
    final m = _entry!.mastery;
    final tight =
        m.state == ItemState.reviewing || m.state == ItemState.automated;
    final base = _entry!.item.type == ItemType.anchor
        ? (tight ? config.flashLimitAnchorMinMs : config.flashLimitAnchorMs)
        : (tight ? config.flashLimitDirectMinMs : config.flashLimitDirectMs);
    _limitTotalMs = config.limitMs(base);
    _remainingMs = _limitTotalMs;
    final keyboardScrolls =
        MediaQuery.sizeOf(context).width < VirtualKeyboard.tabletBreakpoint;
    if (_showsScreenKeyboard && keyboardScrolls) {
      _limitAwaitingTouch = true;
      _limitGrace = Timer(
          Duration(milliseconds: config.keyLimitGraceMs), _beginLimitCountdown);
      // 正计时可视：每 100ms 刷新实时 RT，让"时间在记录"可见。
      _graceTicker?.cancel();
      _graceTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
      setState(() {});
    } else {
      _beginLimitCountdown();
    }
  }

  void _beginLimitCountdown() {
    _limitGrace?.cancel();
    _graceTicker?.cancel();
    final wasAwaiting = _limitAwaitingTouch;
    _limitAwaitingTouch = false;
    if (!mounted ||
        !_isFlash ||
        _limitTotalMs <= 0 ||
        engine.phase != SessionPhase.awaitingAnswer) {
      return;
    }
    if (wasAwaiting) setState(() {}); // 宽限提示立即消失
    _limitTicker?.cancel();
    _limitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      setState(() => _remainingMs -= 50);
      if (_remainingMs <= 0) {
        _limitTicker?.cancel();
        _onTimeout();
      }
    });
  }

  /// 键盘导航开始（滑动超阈值/八度跳转）：记起点，耗时将从 RT 扣除。
  void _onKeyboardNavigateStart() {
    if (!mounted || _rebuildActive) return;
    if (engine.phase == SessionPhase.awaitingAnswer) {
      _navStartMono = clock.monotonicMs();
    }
  }

  /// 键盘导航结束（滑动抬手/跳转动画完成）：结算导航耗时；
  /// 若倒计时在等待定位，则启动。
  void _onKeyboardNavigateEnd() {
    if (!mounted) return;
    _flushNav();
    if (_limitAwaitingTouch) {
      _beginLimitCountdown();
    }
  }

  void _flushNav() {
    final start = _navStartMono;
    _navStartMono = null;
    if (start != null) {
      engine.addNavigationMs(clock.monotonicMs() - start);
    }
  }

  /// 宽限等待期展示的实时 RT：呈现至今 − 已结算导航 − 进行中导航。
  int _liveRtMs() {
    final now = clock.monotonicMs();
    final ongoing = _navStartMono == null ? 0 : now - _navStartMono!;
    final rt = now - _graceStartMono - engine.navigationMs - ongoing;
    return rt < 0 ? 0 : rt;
  }

  /// 最近试次的 RT 标注（反馈与空屏间隙展示）。
  String? get _lastRtLabel {
    final t = engine.lastTrial;
    if (t == null) return null;
    if (t.timeout) return '超时未答';
    final rt = t.rtMs;
    return rt == null ? null : '反应 ${(rt / 1000).toStringAsFixed(1)}s';
  }

  int _answerIndex(String pc) {
    final target = _entry!.item.targetIndices.last;
    const pcs = 'CDEFGAB';
    var d = pcs.indexOf(pc) - mod(target, 7);
    if (d > 3) d -= 7;
    if (d < -3) d += 7;
    return target + d;
  }

  PianoMidiService get _piano => ref.read(pianoMidiServiceProvider);

  bool get _pianoConnected =>
      _piano.connectionState == PianoConnectionState.connected;

  /// 是否显示屏幕键盘：虚拟键盘模式恒显示；电钢琴模式断连时回退显示。
  bool get _showsScreenKeyboard =>
      config.inputMode == InputMode.virtualKey ||
      (config.inputMode == InputMode.piano && !_pianoConnected);

  /// 电钢琴按键 → 作答事件。前置闪现/反馈/空屏期间由 _onAnswer 再次拦截。
  void _onPianoNote(PianoNoteEvent e) {
    if (!mounted ||
        config.inputMode != InputMode.piano ||
        !_pianoConnected) {
      return;
    }
    if (engine.phase != SessionPhase.awaitingAnswer) return;
    if (_preludeVisible || _directionPending || _directionResult != null ||
        _rebuildActive) {
      return;
    }
    final entry = _entry;
    if (entry == null) return;
    unawaited(_onAnswer(buildPianoAnswer(
      itemId: entry.item.id,
      midi: e.midiNote,
      timestamp: clock.nowUtcMs(),
    )));
  }

  Future<void> _onAnswer(AnswerEvent e) async {
    // 重建立慢练：本地消费作答，不走引擎（文件头裁决 1）。
    if (_rebuildActive) {
      if (!_rebuildCard &&
          _rebuildFeedback == null &&
          _rebuildAnswer != null &&
          !_rebuildAnswer!.isCompleted) {
        _rebuildAnswer!.complete(e.pitchClass);
      }
      return;
    }
    if (engine.phase != SessionPhase.awaitingAnswer) return;
    if (_preludeVisible || _directionPending || _directionResult != null) {
      return;
    }
    _limitTicker?.cancel();
    _limitGrace?.cancel();
    _graceTicker?.cancel();
    _limitAwaitingTouch = false;
    _flushNav(); // 作答前结算进行中的导航（多指边缘情形）
    final entry = _entry!;
    final target = _isPhrase
        ? (entry.item.payload as PhrasePayload)
            .noteSequence[engine.phraseSlot]
        : entry.item.targetIndices.last;
    final event = AnswerEvent(
      itemId: e.itemId,
      pitchClass: e.pitchClass,
      octave: e.octave,
      midi: e.midi,
      rtMs: 0, // 引擎用单调钟重算
      source: e.source,
      hintUsed: _isRelation ? _hintLevel : 0,
      hintRequested: _hintRequested,
      timestamp: e.timestamp,
    );
    final correct = e.pitchClass == pitchClassOf(target) &&
        (config.inputMode == InputMode.nameButtons ||
            e.octave == octaveOf(target)) &&
        event.hintUsed < 5;
    engine.submitAnswer(event);
    if (_consumeEvents()) _rebuildPending = true;
    setState(() {});

    // 听觉闭环（02 §1.4）：答对播目标；答错播答案→400ms→正确。
    final audio = ref.read(audioServiceProvider);
    if (correct) {
      await audio.playNote(midiOf(target));
    } else {
      await audio.playComparison(
        // 电钢琴直接携带真实按键音高（含黑键）；屏幕输入按音名反查。
        answerMidi: e.midi ?? midiOf(_answerIndex(e.pitchClass)),
        correctMidi: midiOf(target),
        gap: Duration(milliseconds: config.wrongAnswerGapMs),
      );
    }
    await _feedbackFlow();
  }

  Future<void> _onTimeout() async {
    if (engine.phase != SessionPhase.awaitingAnswer) return;
    _navStartMono = null; // 超时试次无 RT，导航不再结算
    final entry = _entry!;
    final target = entry.item.targetIndices.last;
    engine.timeout();
    if (_consumeEvents()) _rebuildPending = true;
    setState(() {});
    await ref.read(audioServiceProvider).playNote(midiOf(target));
    await _feedbackFlow();
  }

  /// 反馈时序（06 §5）：标记 600ms → 空屏 800ms → 下一题。
  /// 短句逐音：标记后高亮移下一音；整句完成连播 + 全句标记 2s。
  Future<void> _feedbackFlow() async {
    if (!mounted) return;
    setState(() => _showFeedback = true);
    final entry = _entry!;
    final phraseDone = _isPhrase &&
        engine.phraseSlot >=
            (entry.item.payload as PhrasePayload).noteSequence.length;
    if (phraseDone) {
      final midis = (entry.item.payload as PhrasePayload)
          .noteSequence
          .map(midiOf)
          .toList();
      await ref.read(audioServiceProvider).playSequence(midis,
          interval: Duration(milliseconds: config.phrasePlayIntervalMs));
      await widget.delayer
          .delay(const Duration(milliseconds: 2000));
      if (!mounted) return;
      setState(() => _showFeedback = false);
      engine.next();
      _afterNext();
      return;
    }
    await widget.delayer.delay(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _showFeedback = false);
    if (_isPhrase && engine.phase == SessionPhase.awaitingAnswer) {
      _beginPhraseNote();
      return;
    }
    setState(() => _blank = true);
    await widget.delayer
        .delay(Duration(milliseconds: config.interTrialBlankMs));
    if (!mounted) return;
    // 重建立微循环插在反馈之后、队列推进之前（02 §2.2，文件头裁决 1）。
    if (_rebuildPending) {
      _rebuildPending = false;
      setState(() => _blank = false);
      await _runRebuild();
      if (!mounted) return;
    }
    engine.next();
    _afterNext();
  }

  void _afterNext() {
    if (engine.phase == SessionPhase.summary) {
      _finish();
    } else {
      _beginPresent();
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final cfg = config;
    final clock = ref.read(clockProvider);
    await widget.bundle.flush();
    final Database db = widget.dbOverride ?? await ref.read(databaseProvider.future);
    await SessionRepo(db)
        .updateDoneCount(widget.bundle.sessionId, engine.doneCount);
    // S4 数据：本会话试次 + 掌握度 + 引擎事件（06 §2 S4）。
    final data = await loadSessionSummary(
      db: db,
      sessionId: widget.bundle.sessionId,
      config: cfg,
      clock: clock,
      doneCount: engine.doneCount,
      events: engine.events,
    );
    if (mounted) setState(() => _summary = data);
  }

  Future<void> _confirmExit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('已完成 ${engine.doneCount} 题已保存，剩余题目将重新安排'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续练习')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok == true && mounted) {
      _limitTicker?.cancel();
      _limitGrace?.cancel();
      _graceTicker?.cancel();
      engine.exit();
      await widget.bundle.flush();
      final Database db = widget.dbOverride ?? await ref.read(databaseProvider.future);
      await SessionRepo(db)
          .updateDoneCount(widget.bundle.sessionId, engine.doneCount);
      if (mounted) {
        widget.onFinished?.call();
        Navigator.of(context).maybePop();
      }
    }
  }

  SessionSegment _segmentOf(QueueSegment s) => switch (s) {
        QueueSegment.warmup => SessionSegment.warmup,
        QueueSegment.microLesson => SessionSegment.microLesson,
        QueueSegment.phrase => SessionSegment.phrase,
        _ => SessionSegment.mixed,
      };

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final phase = engine.phase;
    if (phase == SessionPhase.summary || entry == null) {
      final data = _summary;
      if (data == null) {
        // 数据加载中（flush 后才可读）。
        return Scaffold(
          appBar: AppBar(title: const Text('本次会话')),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return SessionSummaryView(
        data: data,
        onHome: () {
          widget.onFinished?.call();
          Navigator.of(context).maybePop();
        },
        onMasteryMap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MasteryMapPage()),
        ),
      );
    }

    final item = entry.item;
    final clef = entry.context.clef;
    final positions = _isPhrase
        ? (item.payload as PhrasePayload).noteSequence
        : [item.targetIndices.last];
    final anchorOverlay = _isRelation
        ? StaffAnchorOverlay(
            index: (item.payload as RelationPayload).anchorIndex,
            label: NotePosition.of(
                    (item.payload as RelationPayload).anchorIndex)
                .displayName,
          )
        : (_resetAnchorVisible && _isPhrase
            ? StaffAnchorOverlay(
                index: widget.bundle.activeAnchors.first,
                label: NotePosition.of(
                        widget.bundle.activeAnchors.first)
                    .displayName)
            : null);

    // 前置锚点闪现 / 重建立微循环：谱表区改为锚点常亮 + 音名标注。
    final overlayIndex = _preludeVisible
        ? widget.bundle.activeAnchors.first
        : (_rebuildActive ? _rebuildAnchor! : null);
    final overlayClef = overlayIndex == null
        ? clef
        : (canClef(overlayIndex, clef)
            ? clef
            : NotePosition.of(overlayIndex).clefs.first);
    final staff = overlayIndex != null
        ? StaffView(
            clef: overlayClef,
            positions: const [],
            // 慢练每题换位置；前置锚点闪现沿用当前题 seed。
            jitterSeed: _rebuildActive ? _rebuildSeed : entry.context.jitterSeed,
            anchorOverlay: StaffAnchorOverlay(
              index: overlayIndex,
              label: NotePosition.of(overlayIndex).displayName,
              ghost: _preludeVisible,
            ),
          )
        : StaffView(
            clef: clef,
            positions: positions,
            jitterSeed: entry.context.jitterSeed,
            highlightIndex: _isPhrase ? engine.phraseSlot : null,
            anchorOverlay: anchorOverlay,
          );

    final answerEnabled = _rebuildActive
        ? (!_rebuildCard &&
            _rebuildRemaining > 0 &&
            _rebuildFeedback == null)
        : (phase == SessionPhase.awaitingAnswer &&
            !_blank &&
            !_preludeVisible &&
            !_directionPending &&
            _directionResult == null);

    // 平板横屏双栏（06 §3）：左 55% 谱表 / 右 45% 作答与提示；
    // 可用宽度 <600dp（含 iPad Split View 窄分屏）走手机单列。
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 600 && size.width > size.height;
    final staffArea = Padding(
      padding: EdgeInsets.all(wide ? 16 : 12),
      child: Stack(
        children: [
          Positioned.fill(
            child: _blank
                ? Container(
                    color: StaffView.paperColor,
                    alignment: Alignment.center,
                    child: _lastRtLabel == null
                        ? null
                        : Text(
                            _lastRtLabel!,
                            key: const Key('blank_rt'),
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                  )
                : staff,
          ),
          if (_preludeVisible)
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '参照锚点闪现 · 接下来直认目标音',
                    key: const Key('prelude_caption'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          if (_rebuildActive && _rebuildFeedback != null)
            Positioned.fill(
              child: FeedbackOverlay(
                correct: _rebuildFeedback!,
                correctAnswer: NotePosition.of(_rebuildAnchor!).displayName,
              ),
            )
          else if (_showFeedback && engine.lastTrial != null)
            Positioned.fill(
              child: FeedbackOverlay(
                correct: engine.lastTrial!.correct,
                correctAnswer: NotePosition.of(item.targetIndices.last).displayName,
                // 级 5 = 直接给答案，按规格本题不计正确；反馈不能显示 ✗。
                answerGiven: engine.lastTrial!.hintLevelUsed >= 5,
                rtLabel: _lastRtLabel,
              ),
            ),
        ],
      ),
    );

    final controls = <Widget>[
      if (_isFlash &&
          _limitTotalMs > 0 &&
          !_rebuildActive &&
          !_preludeVisible)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LinearProgressIndicator(
            value: _limitTotalMs == 0
                ? 0
                : (_remainingMs / _limitTotalMs).clamp(0.0, 1.0),
            color: _remainingMs <= 500 ? StaffView.accentColor : Colors.grey,
          ),
        ),
      if (_limitAwaitingTouch)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            key: const Key('limit_grace_hint'),
            children: [
              Icon(Icons.timer_outlined,
                  size: 14, color: Theme.of(context).hintColor),
              const SizedBox(width: 4),
              Text(
                '${(_liveRtMs() / 1000).toStringAsFixed(1)}s',
                key: const Key('limit_grace_elapsed'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '找音不判超时 · 滑动不计反应',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor),
                ),
              ),
            ],
          ),
        ),
      if (_rebuildCard)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('锚点重建立', key: Key('rebuild_card')),
        ),
      if (_rebuildActive && !_rebuildCard)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '慢速练习 ${6 - _rebuildRemaining}/5（不限时）',
            key: const Key('rebuild_practice'),
          ),
        ),
      if (_directionPending)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (label, id) in const [
                ('上行', 'up'),
                ('下行', 'down'),
                ('混合', 'mixed'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton(
                    key: Key('direction_$id'),
                    onPressed: () => _onDirection(label),
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ),
      if (_directionResult != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            _directionResult! ? '走向判断：正确' : '走向判断：错误',
            key: const Key('direction_result'),
          ),
        ),
      if (_isRelation && _hintLevel > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: HintPanel(
            level: _hintLevel,
            relation: item.payload as RelationPayload,
          ),
        ),
      const SizedBox(height: 8),
      if (config.inputMode == InputMode.piano)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            key: const Key('piano_status'),
            children: [
              Icon(
                _pianoConnected ? Icons.piano : Icons.piano_off,
                size: 16,
                color: _pianoConnected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).hintColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _pianoConnected
                      ? '电钢琴已连接：${_piano.connectedDevice?.displayName ?? 'MIDI 设备'} · 弹奏作答'
                      : '电钢琴未连接 · 已切换屏幕键盘',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (!_pianoConnected && _piano.isSupported)
                TextButton(
                  key: const Key('piano_reconnect'),
                  onPressed: () => unawaited(_piano.reconnect()),
                  child: const Text('重连'),
                ),
            ],
          ),
        ),
      if (config.inputMode == InputMode.nameButtons)
        NameButtons(
          enabled: answerEnabled,
          onAnswer: (pc) => _onAnswer(buildNameButtonAnswer(
            itemId: item.id,
            pitchClass: pc,
            timestamp: 0,
          )),
        )
      else if (_showsScreenKeyboard)
        VirtualKeyboard(
          // 固定 key + 外部 controller：上方部件增减不丢滚动位置。
          key: const ValueKey('session_keyboard'),
          controller: _keyboardScroll,
          onNavigateStart: _onKeyboardNavigateStart,
          onNavigateEnd: _onKeyboardNavigateEnd,
          enabled: answerEnabled,
          onAnswer: (midi) => _onAnswer(buildKeyAnswer(
            itemId: item.id,
            midi: midi,
            timestamp: 0,
          )),
        ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isRelation)
              TextButton.icon(
                key: const Key('request_hint'),
                onPressed: phase == SessionPhase.awaitingAnswer
                    ? () => setState(() {
                          _hintLevel = (_hintLevel + 1).clamp(0, 5);
                          _hintRequested = true;
                        })
                    : null,
                icon: const Icon(Icons.lightbulb_outline),
                label: const Text('请求提示'),
              ),
            if (_isPhrase)
              TextButton.icon(
                key: const Key('reset_anchor'),
                onPressed: (_directionPending ||
                        _directionResult != null ||
                        _rebuildActive ||
                        _preludeVisible)
                    ? null
                    : () async {
                        engine.requestPhraseReset();
                        setState(() => _resetAnchorVisible = true);
                        await widget.delayer
                            .delay(const Duration(milliseconds: 2000));
                        if (mounted) {
                          setState(() => _resetAnchorVisible = false);
                        }
                      },
                icon: const Icon(Icons.my_location),
                label: const Text('复位到锚点'),
              ),
          ],
        ),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ProgressHeader(
              segment: _segmentOf(entry.segment),
              index: engine.position,
              total: engine.queueLength,
              onExit: _confirmExit,
            ),
            if (_bannerText != null)
              Container(
                key: const Key('mastery_banner'),
                width: double.infinity,
                color: Theme.of(context).colorScheme.secondaryContainer,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Text(
                  _bannerText!,
                  style: TextStyle(
                    color:
                        Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 55, child: staffArea),
                        Expanded(
                          flex: 45,
                          child: SingleChildScrollView(
                            child: Column(children: controls),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 5, child: staffArea),
                        ...controls,
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}