// 规格: 11 §3 §6.2 §6.3 §7 —— 视奏训练执行页（S8）。
//
// 定位：纯练习，不进 SM-2（11 §0 §7）：只写 sight_read_log 一条完成记录，
// 不写 mastery / trial_log / phrase。整页无倒计时、无超时、无闪现；
// 离开页面即结束，未走完的谱例不落库。
//
// 实现取舍：
// 1) 谱面稳定不抖动（11 §6.3 裁决 6）；"答错抖动"只作用于整个谱表容器
//    （AnimatedBuilder + Transform.translate，200ms 内两个来回、±3dp），
//    不改变谱面内部坐标。
// 2) 连错提示只浮现音名 1.5s（11 §3.3 上半句），不自动跳过、不额外给位置。
// 3) MIDI 与屏幕键盘并存；只有 MIDI 自然音能提交，黑键（midiToDiatonicIndex
//    返回 null）被忽略——引擎只接受 diatonicIndex，无法表达"黑键答错"。
// 4) 同一次按键可能重复上报 note-on：同一 midi 在 [midiDedupWindowMs] 内
//    只认第一次，避免一次弹奏推进两格 / 多记一次错误（见 _onMidiNote）。
// 5) 落库时机 = engine.finished 首次为 true（每次完成一条）。写库失败静默，
//    只 debugPrint 留痕：视奏记录不参与统计页/排程，不能因为磁盘问题挡住完成页。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/piano_midi.dart';
import '../../core/providers.dart';
import '../../core/rng.dart';
import '../../data/repositories/sight_read_repo.dart';
import '../../domain/models/note_position.dart';
import '../../domain/models/sight_beat_result.dart';
import '../../domain/models/sight_level.dart';
import '../../domain/models/sight_read_log.dart';
import '../../domain/models/sight_score.dart';
import '../../domain/models/sight_time_signature.dart';
import '../../domain/sight_engine.dart';
import '../../domain/sight_generator.dart';
import '../../ui/grand_staff_view.dart';
import '../../ui/virtual_keyboard.dart';

/// 一次已排程的拍任务，可取消（换谱 / 退页时不能让旧拍回调打新引擎）。
abstract interface class SightBeatTask {
  void cancel();
}

/// 拍调度器：生产用 Timer；widget 测试注入可手动触发的实现，
/// 避免依赖真实定时器在测试环境里的不可靠行为。
abstract interface class SightBeatScheduler {
  SightBeatTask schedule(Duration delay, void Function() callback);
}

/// 生产拍调度器。
class TimerBeatScheduler implements SightBeatScheduler {
  const TimerBeatScheduler();

  @override
  SightBeatTask schedule(Duration delay, void Function() callback) =>
      _SightBeatTimerTask(Timer(delay, callback));
}

class _SightBeatTimerTask implements SightBeatTask {
  _SightBeatTimerTask(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// 视奏执行页：驱动 [SightSessionEngine]，渲染大谱表 / 进度 / 键盘 / 完成统计。
class SightSessionPage extends ConsumerStatefulWidget {
  const SightSessionPage({
    super.key,
    required this.score,
    this.source = 'generated',
    this.scoreRef,
    this.level = SightLevel.L1,
    this.beatScheduler,
    this.timeSignature = SightTimeSignature.common4_4,
    this.countdownSeconds = 3,
    this.quartersPerMinute = 60,
  });

  final SightScore score;

  /// `generated`（生成练习）或 `score`（内置曲目），落 sight_read_log。
  final String source;

  /// 内置曲目 id；生成练习为 null。
  final String? scoreRef;

  /// 难度档（生成练习用；内置曲目仍走 legacy 生成路径）。
  final SightLevel level;

  /// 仅测试注入；生产为 null 时用 [TimerBeatScheduler]。
  final SightBeatScheduler? beatScheduler;

  /// 拍号：分母决定每拍时长（速度），分子决定小节重音位置。
  final SightTimeSignature timeSignature;

  /// 开场准备倒计时秒数；<=0 表示不倒数（兼容旧入口）。
  final int countdownSeconds;

  /// 速度：每分钟四分音符数（♩=N），独立于拍号与难度档。
  final int quartersPerMinute;

  @override
  ConsumerState<SightSessionPage> createState() => _SightSessionPageState();
}

class _SightSessionPageState extends ConsumerState<SightSessionPage>
    with SingleTickerProviderStateMixin {
  /// 答错抖动时长（11 §3.3：200ms）。
  static const Duration _shakeDuration = Duration(milliseconds: 200);

  /// 抖动幅度（dp）：谱表整体左右 ±3dp，200ms 内两个来回。
  static const double _shakeAmplitude = 3;

  /// 同一 midi 的重复 note-on 去抖窗口。
  static const int midiDedupWindowMs = 60;

  /// 连错提示停留时长（11 §3.3：1.5s）。
  static const Duration _hintDuration = Duration(milliseconds: 1500);

  /// 连错提示音的播放间隔（11 §3.3：浮现音名 + 播放正确音）。
  static const Duration _hintPlayGap = Duration(milliseconds: 180);

  late SightScore _score;
  late SightSessionEngine _engine;

  late final SightBeatScheduler _beatScheduler;
  SightBeatTask? _beatTask;
  SightBeatTask? _countdownTask;

  /// 开场准备倒计时状态：期间谱面可见但输入全部忽略。
  bool _countingIn = false;
  int _countdownLeft = 0;

  /// 下一拍号（严格递增），与引擎 tick 的 beatIndex 对齐。
  int _nextBeatIndex = 0;

  /// 换谱后作废旧拍回调，防止 Timer 竞态打到新引擎。
  int _beatGeneration = 0;

  /// 已结算音的四色（key=列号），传给 GrandStaffView 的可选参数。
  Map<int, SightHitGrade> _upperGrades = {};
  Map<int, SightHitGrade> _lowerGrades = {};

  /// 上次弹提示时的连续 miss 数，防止每拍漏拍都重复弹。
  int _lastHintStreak = 0;

  /// 本次记录的来源；「再来一条」生成的谱例改记为 generated。
  late String _source;
  String? _scoreRef;

  /// 本段是否已写过 sight_read_log（每次完成只写一条）。
  bool _logged = false;

  /// 页面打开 / 重新生成时的单调钟读数，用于统计用时。
  late int _startMono;

  /// 完成瞬间的单调钟读数；null = 尚未完成（用时实时累计）。
  int? _finishedMono;

  late final AnimationController _shake;

  /// 谱面横向滚动控制器：由页面持有，答错抖动重建谱表子树（key 变）时
  /// 滚动位置不会被重置；自动跟随滚动由 GrandStaffView 内部驱动。
  final ScrollController _staffScroll = ScrollController();

  /// 每次答错自增，作为抖动部件的 key（重启动画并让测试可观测）。
  int _shakeTick = 0;

  Set<int> _upperHint = const {};
  Set<int> _lowerHint = const {};
  Timer? _hintTimer;

  /// 页面是否已销毁：提示音是异步延时播放，销毁后不得再响。
  bool _disposed = false;

  /// 提示音播放轮次：新的 hintDue 到来时作废上一轮未播完的延时。
  int _hintPlayToken = 0;

  StreamSubscription<PianoNoteEvent>? _noteSub;
  StreamSubscription<PianoConnectionState>? _stateSub;

  /// MIDI 去抖：上次提交的 midi + 单调钟时刻。
  int? _lastMidi;
  int _lastMidiMono = 0;

  @override
  void initState() {
    super.initState();
    _score = widget.score;
    _source = widget.source;
    _scoreRef = widget.scoreRef;
    _beatScheduler = widget.beatScheduler ?? const TimerBeatScheduler();
    _engine = SightSessionEngine(
      _score,
      level: widget.level,
      denominator: widget.timeSignature.denominator,
      quartersPerMinute: widget.quartersPerMinute,
    );
    _startMono = ref.read(clockProvider).monotonicMs();
    _shake = AnimationController(vsync: this, duration: _shakeDuration);
    final piano = ref.read(pianoMidiServiceProvider);
    _noteSub = piano.noteEvents.listen(_onMidiNote);
    _stateSub = piano.connectionStateChanges.listen((_) {
      if (mounted) setState(() {});
    });
    _startCountdown(fromInit: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _beatGeneration++;
    _beatTask?.cancel();
    _countdownTask?.cancel();
    _hintTimer?.cancel();
    unawaited(_noteSub?.cancel());
    unawaited(_stateSub?.cancel());
    _shake.dispose();
    _staffScroll.dispose();
    super.dispose();
  }

  int get _elapsedMs =>
      (_finishedMono ?? ref.read(clockProvider).monotonicMs()) - _startMono;

  /// 当前模式对应的键盘音域（11 §3.4）。
  (int, int) get _keyRange => switch (_score.mode) {
    SightMode.trebleOnly => (sightTrebleMin, sightTrebleMax),
    SightMode.bassOnly => (sightBassMin, sightBassMax),
    SightMode.grand => (sightAllMin, sightAllMax),
  };

  // ------------------------------------------------------------- 输入

  /// MIDI note-on → 作答。velocity 不参与判断（11 §3.4：只监听 note-on）。
  void _onMidiNote(PianoNoteEvent e) {
    if (!mounted || _engine.finished || _countingIn) return;
    final index = midiToDiatonicIndex(e.midiNote);
    if (index == null) return; // 黑键：视奏只作答自然音。
    final now = ref.read(clockProvider).monotonicMs();
    // 去抖：同一次弹奏重复上报 note-on 时（间隔 < 窗口）只认第一次。
    // 窗口取 60ms，远小于正常人连击同键的间隔（>100ms）。
    if (_lastMidi == e.midiNote && now - _lastMidiMono < midiDedupWindowMs) {
      return;
    }
    _lastMidi = e.midiNote;
    _lastMidiMono = now;
    _submit(index);
  }

  /// 键盘 / MIDI 统一入口：只把音入当前拍输入槽，绝不推进光标 / 落库。
  ///
  /// [screenTap] 为屏幕点击：按 T02 约定加 +30ms 补偿触屏事件排队延迟；
  /// MIDI 用真实事件时刻，不补偿。
  void _submit(int diatonicIndex, {bool screenTap = false}) {
    if (_engine.finished || _countingIn) return;
    final now = ref.read(clockProvider).monotonicMs();
    final result = _engine.submit(
      diatonicIndex,
      atMonoMs: screenTap ? now + 30 : now,
    );
    // 输入即回放所按的音（含错音）；四色、推进、落库一律等 tick 结算。
    final played = result.note?.diatonicIndex ?? diatonicIndex;
    unawaited(ref.read(audioServiceProvider).playNote(midiOf(played)));
  }

  /// 开场准备倒计时：用同一个拍调度器排 1 秒 task（不另起真实 Timer），
  /// 期间谱面正常显示但输入全部忽略；倒数结束才起跑拍钟与第一拍。
  void _startCountdown({bool fromInit = false}) {
    if (widget.countdownSeconds <= 0) {
      _countingIn = false;
      _countdownLeft = 0;
      _leadInBeatClock();
      _scheduleNextBeat();
      return;
    }
    _countingIn = true;
    _countdownLeft = widget.countdownSeconds;
    // initState 阶段不能 setState，字段已直接赋值；后续重建（再来一条）才刷新。
    if (!fromInit && mounted) setState(() {});
    _scheduleCountdownTick();
  }

  void _scheduleCountdownTick() {
    _countdownTask?.cancel();
    final generation = _beatGeneration;
    _countdownTask = _beatScheduler.schedule(const Duration(seconds: 1), () {
      if (!mounted || generation != _beatGeneration) return;
      _countdownLeft--;
      if (_countdownLeft > 0) {
        setState(() {});
        _scheduleCountdownTick();
        return;
      }
      _countingIn = false;
      _leadInBeatClock();
      _scheduleNextBeat();
      setState(() {});
    });
  }

  /// 拍钟起跑留一拍引导：引擎自建时钟从构造时刻起跑，若立刻排第 0 拍会在
  /// 用户还没弹第一个音时就结算成 miss。引导长度随拍号分母缩放。
  void _leadInBeatClock() {
    final now = ref.read(clockProvider).monotonicMs();
    final beatMs = widget.timeSignature.beatMsAt(widget.quartersPerMinute);
    _engine.beatClock.start(now + beatMs);
  }

  /// 按 beatClock 的绝对 onset 排下一拍；delay 用「绝对 onset - 当前单调时刻」
  /// 计算，不逐拍累加，避免非整数拍长时漂移。
  void _scheduleNextBeat() {
    if (!mounted || _engine.finished) return;
    _beatTask?.cancel();
    final index = _nextBeatIndex;
    final onset = _engine.beatClock.onsetOf(index);
    final now = ref.read(clockProvider).monotonicMs();
    final delayMs = math.max(0, onset - now);
    final generation = _beatGeneration;
    _beatTask = _beatScheduler.schedule(Duration(milliseconds: delayMs), () {
      if (!mounted || generation != _beatGeneration) return;
      _onBeat(index);
    });
  }

  /// 拍到点：引擎结算本拍（含漏拍 miss 也推进），统一处理四色反馈。
  void _onBeat(int beatIndex) {
    if (!mounted || _engine.finished || beatIndex != _nextBeatIndex) return;
    final onset = _engine.beatClock.onsetOf(beatIndex);
    // 结算前记下各声部待答列，结算后光标已前移，必须提前取。
    final upperColumn = _engine.upper?.current?.column;
    final lowerColumn = _engine.lower?.current?.column;
    final result = _engine.tick(beatIndex, nowMonoMs: onset);
    _nextBeatIndex = beatIndex + 1;

    final upperGrades = <int, SightHitGrade>{..._upperGrades};
    final lowerGrades = <int, SightHitGrade>{..._lowerGrades};
    var missed = false;
    for (final hit in result.hits) {
      if (hit.voice == SightVoice.upper && upperColumn != null) {
        upperGrades[upperColumn] = hit.grade;
      }
      if (hit.voice == SightVoice.lower && lowerColumn != null) {
        lowerGrades[lowerColumn] = hit.grade;
      }
      if (hit.grade == SightHitGrade.miss) missed = true;
    }

    // 节拍 click：小节首拍强音。
    unawaited(ref.read(audioServiceProvider).playClick(
          accent: beatIndex % widget.timeSignature.numerator == 0,
        ));

    // 按拍语义下的连错提示：只在连续 miss 跨过阈值倍数时弹一次。
    final streak = _engine.errorStreak;
    final shouldHint = streak >= _engine.hintThreshold &&
        streak % _engine.hintThreshold == 0 &&
        streak != _lastHintStreak;
    _lastHintStreak = streak;

    int? finishedAt;
    if (result.finished && _finishedMono == null) {
      finishedAt = ref.read(clockProvider).monotonicMs();
      _persistRecord(finishedAt - _startMono);
    }

    setState(() {
      _upperGrades = upperGrades;
      _lowerGrades = lowerGrades;
      if (missed) _shakeTick++;
      if (shouldHint) {
        _applyHints();
      } else if (streak == 0) {
        _clearHints();
      }
      if (finishedAt != null) _finishedMono = finishedAt;
    });
    if (missed) _shake.forward(from: 0);
    _scheduleNextBeat();
  }

  /// 连错达阈值：把当前待答音所在列标为提示列，1.5s 后清除，
  /// 同时依次播放当前两个待答音（11 §3.3：浮现音名 + 播放正确音）。
  void _applyHints() {
    final upper = _engine.upper?.current?.column;
    final lower = _engine.lower?.current?.column;
    _upperHint = upper == null ? const {} : {upper};
    _lowerHint = lower == null ? const {} : {lower};
    _hintTimer?.cancel();
    _hintTimer = Timer(_hintDuration, () {
      if (!mounted) return;
      setState(() {
        _upperHint = const {};
        _lowerHint = const {};
        _hintTimer = null;
      });
    });
    _playHintNotes();
  }

  /// 播放提示音：上声部 → 下声部，间隔 [_hintPlayGap]。
  ///
  /// 每次 hintDue 只播一轮；页面销毁或新的提示到来时立即停播后续音。
  void _playHintNotes() {
    final token = ++_hintPlayToken;
    final notes = _engine.pending;
    if (notes.isEmpty) return;
    final audio = ref.read(audioServiceProvider);
    unawaited(() async {
      for (var i = 0; i < notes.length; i++) {
        if (i > 0) await Future<void>.delayed(_hintPlayGap);
        if (_disposed || token != _hintPlayToken) return;
        unawaited(audio.playNote(midiOf(notes[i].diatonicIndex)));
      }
    }());
  }

  void _clearHints() {
    _hintTimer?.cancel();
    _hintTimer = null;
    _upperHint = const {};
    _lowerHint = const {};
  }

  // ------------------------------------------------------------- 完成 / 重来

  /// 写一条 sight_read_log（11 §7）。只写一次；失败静默，不阻塞完成页。
  void _persistRecord(int durationMs) {
    if (_logged) return;
    _logged = true;
    final record = SightReadRecord(
      mode: _score.mode,
      source: _source,
      scoreRef: _scoreRef,
      columnCount: _score.columnCount,
      totalNotes: _engine.totalNotes,
      correctNotes: _engine.correctNotes,
      errorCount: _engine.errorCount,
      errorPositions: _engine.errorPositions,
      durationMs: durationMs,
      finishedAt: ref.read(clockProvider).nowUtcMs(),
    );
    // ref 在 dispose 后不可读，Future 必须同步取出再异步等待。
    final dbFuture = ref.read(databaseProvider.future);
    unawaited(() async {
      try {
        final db = await dbFuture;
        await SightReadRepo(db).insert(record);
      } catch (e) {
        debugPrint('视奏记录写入失败（不影响本次练习）：$e');
      }
    }());
  }

  /// 「再来一条」：同模式、同列数生成新谱例，重建引擎与计时（11 §3.3）。
  void _regenerate() {
    final clock = ref.read(clockProvider);
    // 内置曲目延用 legacy 生成；生成练习沿用当前难度档。
    final level = _source == 'score' ? SightLevel.L1 : widget.level;
    final generated = generateSightScore(
      mode: _score.mode,
      // 随机源必须来自注入的 Clock（项目约定，禁止裸 DateTime.now()）。
      rng: rng(clock.nowUtcMs() & 0x7fffffff),
      columnCount: _score.columnCount,
      level: _source == 'score' ? null : level,
    );
    _clearHints();
    _shake.reset();
    _beatGeneration++;
    _beatTask?.cancel();
    _countdownTask?.cancel();
    _beatTask = null;
    _countdownTask = null;
    setState(() {
      _score = generated.score;
      _engine = SightSessionEngine(
        _score,
        level: level,
        denominator: widget.timeSignature.denominator,
        quartersPerMinute: widget.quartersPerMinute,
      );
      _startMono = clock.monotonicMs();
      _finishedMono = null;
      _shakeTick = 0;
      _lastMidi = null;
      _nextBeatIndex = 0;
      _upperGrades = {};
      _lowerGrades = {};
      _lastHintStreak = 0;
      // 新谱例是随机生成的，不再归属原曲目 id（下次完成按 generated 记）。
      _source = 'generated';
      _scoreRef = null;
      _logged = false;
    });
    // 再来一条也重新做开场准备。
    _startCountdown();
  }

  String get _elapsedLabel {
    final seconds = _elapsedMs ~/ 1000;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  int get _accuracyPercent {
    final attempts = _engine.correctNotes + _engine.errorCount;
    if (attempts == 0) return 0;
    return (_engine.correctNotes * 100 / attempts).round();
  }

  /// 流速保持率：命中拍里落在标准窗内的比例（新指标，过程反馈）。
  int get _onBeatPercent {
    final hits = _engine.onBeatCount + _engine.earlyCount + _engine.lateCount;
    if (hits == 0) return 0;
    return (_engine.onBeatCount * 100 / hits).round();
  }

  /// 有符号平均偏差的人话表述（负=整体偏早）。
  String get _biasLabel {
    final bias = _engine.timingBiasMs;
    if (bias.abs() < 1) return '平均 0ms';
    return bias < 0
        ? '平均早 ${bias.abs().round()}ms'
        : '平均晚 ${bias.round()}ms';
  }

  /// 完成页「易错音位」：按错误次数降序取前 3（11 §3.3 / §7）。
  /// 次数相同按音位升序，保证同一谱例的输出稳定。无错误时返回 null。
  String? get _errorPositionsLabel {
    final entries = _engine.errorPositions.entries.toList()
      ..sort((a, b) => a.value != b.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key));
    if (entries.isEmpty) return null;
    final top = entries.take(3).map(
          (e) => '${NotePosition.of(e.key).displayName}×${e.value}',
        );
    return '易错：${top.join(' · ')}';
  }

  // ------------------------------------------------------------- 渲染

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final piano = ref.watch(pianoMidiServiceProvider);
    final connected = piano.connectionState == PianoConnectionState.connected;

    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 600 && size.width > size.height;
    // 平板横屏谱表占更高比例（11 §6.2：不套用会话页左右分栏）。
    // 键盘高度由键高决定、不参与 flex，故 7:3 体现为谱表 flex 7。
    final staffFlex = wide ? 7 : (_score.mode == SightMode.grand ? 6 : 5);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _score.title ?? _score.mode.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (connected)
              Text(
                piano.connectedDevice?.displayName ?? 'MIDI 设备',
                key: const Key('sight_midi_device'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('sight_exit'),
            tooltip: '退出',
            // 未完成不落库（11 §3.3），直接返回。
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        child: _engine.finished
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: _buildSummary(context),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    flex: staffFlex,
                    child: Stack(
                      children: [
                        _buildStaffArea(),
                        if (_countingIn)
                          Positioned.fill(
                            child: Container(
                              key: const Key('sight_countdown_overlay'),
                              color: theme.colorScheme.surface
                                  .withValues(alpha: 0.72),
                              child: Center(
                                child: Text(
                                  '$_countdownLeft',
                                  key: const Key('sight_countdown'),
                                  style: theme.textTheme.displayLarge?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _buildProgress(theme),
                  _buildKeyboard(),
                ],
              ),
      ),
    );
  }

  Widget _buildStaffArea() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: AnimatedBuilder(
        key: ValueKey('sight_staff_shake_$_shakeTick'),
        animation: _shake,
        builder: (context, child) {
          // 200ms 内两个来回：sin 周期 4π => 2 个完整周期。
          final dx = math.sin(_shake.value * math.pi * 4) * _shakeAmplitude;
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
        child: GrandStaffView(
          mode: _score.mode,
          columns: _score.columns,
          controller: _staffScroll,
          upperCursorColumn: _engine.cursorColumnOf(SightVoice.upper),
          lowerCursorColumn: _engine.cursorColumnOf(SightVoice.lower),
          upperDoneColumns: _engine.upper?.doneColumns.toSet() ?? const {},
          lowerDoneColumns: _engine.lower?.doneColumns.toSet() ?? const {},
          upperHintColumns: _upperHint,
          lowerHintColumns: _lowerHint,
          upperGrades: _upperGrades,
          lowerGrades: _lowerGrades,
        ),
      ),
    );
  }

  Widget _buildProgress(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const Key('sight_progress_bar'),
              value: _engine.progress,
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '已完成 ${_engine.correctNotes}/${_engine.totalNotes}',
                key: const Key('sight_progress_text'),
                style: small,
              ),
              Text(
                '错误 ${_engine.errorCount}',
                key: const Key('sight_error_count'),
                style: small,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKeyboard() {
    final (min, max) = _keyRange;
    return VirtualKeyboard(
      key: const ValueKey('sight_keyboard'),
      rangeMin: min,
      rangeMax: max,
      onAnswer: (midi) {
        final index = midiToDiatonicIndex(midi);
        if (index != null) _submit(index, screenTap: true);
      },
    );
  }

  Widget _buildSummary(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      key: const Key('sight_summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('本段完成', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${_score.mode.displayName} · ♩=${widget.quartersPerMinute} · '
              '${widget.timeSignature.displayName}',
              style: small,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stat(theme, '用时', _elapsedLabel, 'sight_stat_time'),
                _stat(
                  theme,
                  '准确率（过程反馈）',
                  '$_accuracyPercent%',
                  'sight_stat_accuracy',
                ),
                _stat(
                  theme,
                  '错误',
                  '${_engine.errorCount}',
                  'sight_stat_errors',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stat(theme, '流速保持率', '$_onBeatPercent%', 'sight_stat_onbeat'),
                _stat(theme, '平均偏差', _biasLabel, 'sight_stat_bias'),
                _stat(
                  theme,
                  '最长连续命中',
                  '${_engine.longestHitStreak}',
                  'sight_stat_streak',
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildGradeBand(),
            const SizedBox(height: 16),
            if (_errorPositionsLabel case final label?) ...[
              Text(
                label,
                key: const Key('sight_error_positions'),
                textAlign: TextAlign.center,
                style: small,
              ),
              const SizedBox(height: 16),
            ],
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  key: const Key('sight_again'),
                  onPressed: _regenerate,
                  child: const Text('再来一条'),
                ),
                OutlinedButton(
                  key: const Key('sight_summary_exit'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('退出'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 四色分布色带：只展示比例，不加渐变/动画（视觉约束：沿用现有语言）。
  Widget _buildGradeBand() {
    final counts = <SightHitGrade, int>{
      SightHitGrade.onBeat: _engine.onBeatCount,
      SightHitGrade.early: _engine.earlyCount,
      SightHitGrade.late: _engine.lateCount,
      SightHitGrade.miss: _engine.missCount,
    };
    final total = counts.values.fold<int>(0, (sum, n) => sum + n);
    if (total == 0) return const SizedBox.shrink();
    return Row(
      key: const Key('sight_grade_band'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final grade in SightHitGrade.values)
          if (counts[grade]! > 0)
            Container(
              key: Key('sight_grade_${grade.name}'),
              width: (counts[grade]! * 96 / total).clamp(8.0, 96.0).toDouble(),
              height: 6,
              color: sightGradeColor(grade),
            ),
      ],
    );
  }

  Widget _stat(ThemeData theme, String label, String value, String key) {
    return Column(
      children: [
        Text(
          value,
          key: Key(key),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
