// 规格: 05 §9 会话状态机与计时 / 02 §7 / 03 §2（post-frame onset、单调钟）。
// 状态：idle → presenting → awaitingAnswer → feedback → next → … → summary。
// 规则层只消费 AnswerEvent（02 §10.1），本文件不得出现输入源分支。
library;

import '../core/clock.dart';
import '../core/config.dart';
import '../core/rng.dart';
import 'error_classifier.dart';
import 'hint_machine.dart';
import 'mastery.dart';
import 'models/answer_event.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/mastery.dart';
import 'models/note_position.dart';
import 'models/phrase_session.dart';
import 'models/trial.dart';
import 'scheduler.dart';

/// 会话阶段。
enum SessionPhase { idle, presenting, awaitingAnswer, feedback, paused, summary }

/// 试次落库接口（data 层 recordTrial 实现：trial+mastery+confusion 同事务）。
abstract interface class TrialRecorder {
  void record(Trial trial, Mastery mastery, (int, int)? seedPair);
  void recordPhrase(PhraseRecord record);
}

/// 规则管线所需数据访问（data 层实现；测试注入假实现）。
abstract interface class SessionDataSource {
  /// 条目当前掌握度。
  Mastery masteryOf(int itemId);

  /// 条目最近试次结果（时间升序，含本次之前），供自动化窗口(20)判定。
  List<TrialResult> recentResults(int itemId, int limit);

  /// 所有以 targetIndex 为目标的 RELATION 试次（时间升序），供晋升判定。
  List<TrialResult> relationHistoryFor(int targetIndex);

  /// 音位 p 的 DIRECT 条目掌握度（不存在返回 null）。
  Mastery? directMasteryOf(int diatonicIndex);

  /// 涉及音位 p 的 RELATION 条目 id 列表（回退重激活用）。
  List<int> relationItemIdsFor(int diatonicIndex);

  /// 晋升/回退等旁路掌握度写入（与试次事务分离）。
  void saveMastery(Mastery m);
}

/// 会话状态机。UI 驱动时序（post-frame 回调、反馈延时、空屏），
/// 引擎负责状态迁移、RT 计时、规则管线与落库编排。
class SessionEngine {
  final Config config;
  final Clock clock;
  final Rng rng;
  final TrialRecorder recorder;
  final SessionDataSource source;
  final int sessionId;
  final int stage;
  final InputMode mode;

  /// 会话末时间戳（q1 的 dueAt）；null 表示会话已结束口径。
  final int? sessionEndTs;

  final ReexposureScheduler reexposure;

  List<QueueEntry> _queue;
  int _pos = 0;
  int? _onsetMono;

  /// 本题键盘导航（滑动找音/八度跳转）累计耗时，从 RT 中扣除。
  /// 裁决：导航是 UI 操作开销不是认谱反应（真实钢琴无需滑动琴键）。
  int _navMs = 0;
  SessionPhase _phase = SessionPhase.idle;

  /// 本次会话累积的掌握度事件（晋升/回退/重建立），供报告。
  final List<MasteryEvent> events = [];

  /// 已落库试次数。
  int doneCount = 0;

  /// 最近一次落库试次（反馈展示用）。
  Trial? lastTrial;

  // PHRASE 逐音状态（05 §9 特例）。
  int _phraseSlot = 0;
  final List<int> _phraseRt = [];
  final List<bool> _phraseCorrect = [];
  int _phraseResets = 0;

  SessionEngine({
    required this.config,
    required this.clock,
    required this.rng,
    required this.recorder,
    required this.source,
    required this.sessionId,
    required this.stage,
    required this.mode,
    required List<QueueEntry> queue,
    this.sessionEndTs,
    ReexposureScheduler? reexposure,
  })  : _queue = List.of(queue),
        reexposure = reexposure ??
            ReexposureScheduler(config: config, rng: rng);

  SessionPhase get phase => _phase;
  int get position => _pos;
  int get queueLength => _queue.length;
  QueueEntry? get current => _pos < _queue.length ? _queue[_pos] : null;
  int get phraseSlot => _phraseSlot;

  /// 本题已扣除的导航时间（UI 展示实时 RT 用）。
  int get navigationMs => _navMs;

  /// 导航结束时由 UI 上报耗时；仅作答阶段累计，呈现/反馈期导航不计。
  void addNavigationMs(int ms) {
    if (_phase == SessionPhase.awaitingAnswer && ms > 0) _navMs += ms;
  }

  /// 开始会话：呈现第一题。
  void start() {
    if (_phase != SessionPhase.idle) return;
    if (_queue.isEmpty) {
      _phase = SessionPhase.summary;
      return;
    }
    _present();
  }

  void _present() {
    // 到达题序时插入预约的复现题（05 §3 C3）。
    final rx = reexposure.takeAt(_pos);
    if (rx.isNotEmpty) _queue.insertAll(_pos, rx);
    _onsetMono = null;
    _navMs = 0;
    _phraseSlot = 0;
    _phraseRt.clear();
    _phraseCorrect.clear();
    _phraseResets = 0;
    _phase = SessionPhase.presenting;
  }

  /// post-frame 回调：刺激渲染完成，记录 onset（单调钟，03 §2）。
  /// PHRASE 逐音：每个音位开始作答前由 UI 再次调用。
  void onPresented() {
    if (_phase == SessionPhase.presenting ||
        (_phase == SessionPhase.awaitingAnswer &&
            current?.item.type == ItemType.phrase)) {
      _onsetMono = clock.monotonicMs();
      _navMs = 0; // 逐音口径：上一音的导航不带入下一音
      _phase = SessionPhase.awaitingAnswer;
    }
  }

  /// 复位锚点按钮（02 §5.3）：计入短句复位依赖。
  void requestPhraseReset() {
    if (current?.item.type == ItemType.phrase) _phraseResets++;
  }

  /// 作答事件到达（规则层唯一入口）。
  void submitAnswer(AnswerEvent e) {
    if (_phase != SessionPhase.awaitingAnswer || _onsetMono == null) return;
    final entry = current!;
    final item = entry.item;
    final elapsed = clock.monotonicMs() - _onsetMono!;
    final rt = elapsed > _navMs ? elapsed - _navMs : 0;
    _onsetMono = null;

    if (item.type == ItemType.phrase) {
      _answerPhraseNote(entry, e, rt, elapsed);
      return;
    }

    final target = item.targetIndices.last;
    final correct = _isCorrect(target, e) && e.hintUsed < 5;
    final cls = classify(
      item: item,
      targetIndex: target,
      answerPitchClass: e.pitchClass,
      answerOctave: e.octave,
      mode: mode,
      stage: stage,
      rtMs: rt,
      correct: correct,
      config: config,
    );
    final trial = Trial(
      sessionId: sessionId,
      itemId: item.id,
      presentedAt: clock.nowUtcMs() - elapsed,
      answeredAt: clock.nowUtcMs(),
      rtMs: rt,
      correct: correct,
      hintLevelUsed: e.hintUsed,
      hintRequested: e.hintRequested,
      errorType: cls.errorType,
      answerPitchClass: e.pitchClass,
      answerOctave: e.octave,
      inputSource: e.source,
      contextSnapshot: entry.context,
    );
    final m = _applyRules(item, entry.mastery, trial, cls.seedPair, target);
    recorder.record(trial, m, cls.seedPair);
    lastTrial = trial;
    doneCount++;
    if (!correct) {
      reexposure.onWrong(
        item: item,
        mastery: m,
        trial: trial,
        currentIndex: _pos,
        sessionLength: _queue.length,
      );
    }
    _phase = SessionPhase.feedback;
  }

  /// 超时（05 §9）：记 TIMEOUT 试次，走答错反馈。
  void timeout() {
    if (_phase != SessionPhase.awaitingAnswer) return;
    final entry = current!;
    final item = entry.item;
    if (item.type == ItemType.phrase) {
      // 短句逐音超时：该音记错，流程继续（02 §5.2 不中断短句）。
      _recordPhraseNote(entry, null, null, false, timeout: true);
      return;
    }
    _onsetMono = null;
    final target = item.targetIndices.last;
    final trial = Trial(
      sessionId: sessionId,
      itemId: item.id,
      presentedAt: clock.nowUtcMs(),
      rtMs: null,
      correct: false,
      timeout: true,
      errorType: ErrorType.timeout,
      inputSource: _inputSourceForMode,
      contextSnapshot: entry.context,
    );
    final m = _applyRules(item, entry.mastery, trial, null, target);
    recorder.record(trial, m, null);
    lastTrial = trial;
    doneCount++;
    reexposure.onWrong(
      item: item,
      mastery: m,
      trial: trial,
      currentIndex: _pos,
      sessionLength: _queue.length,
    );
    _phase = SessionPhase.feedback;
  }

  /// 退后台/锁屏（05 §9）：当前未答题试次作废（不落库），会话暂停。
  void onBackground() {
    if (_phase == SessionPhase.presenting ||
        _phase == SessionPhase.awaitingAnswer) {
      _onsetMono = null;
      _phase = SessionPhase.paused;
    }
  }

  /// 恢复：重呈同一题（不计次）。
  void onResume() {
    if (_phase == SessionPhase.paused) _present();
  }

  /// 反馈结束（UI 在视觉标记 600ms + 空屏 800ms 后调用）→ 下一题。
  void next() {
    if (_phase != SessionPhase.feedback) return;
    _pos++;
    if (_pos >= _queue.length) {
      _phase = SessionPhase.summary;
    } else {
      _present();
    }
  }

  /// 退出会话（05 §9 / 02 §7.2）：已答试次已落库；未做队列丢弃。
  /// 下次会话由调用方重新 buildQueue（引擎不保留队列）。
  void exit() {
    _queue = [];
    _pos = 0;
    _onsetMono = null;
    _phase = SessionPhase.idle;
  }

  // ---- 内部 ----

  /// 超时/短句伪试次的默认输入源（真实作答仍以 AnswerEvent.source 为准）。
  InputSource get _inputSourceForMode => switch (mode) {
        InputMode.nameButtons => InputSource.nameButton,
        InputMode.virtualKey => InputSource.virtualKey,
        InputMode.piano => InputSource.midi,
      };

  bool _isCorrect(int target, AnswerEvent e) {
    if (e.pitchClass != pitchClassOf(target)) return false;
    if (mode != InputMode.nameButtons && e.octave != null) {
      return e.octave == octaveOf(target);
    }
    return true;
  }

  /// 规则管线：applyTrial → 提示状态机 → advance → 自动化/晋升/回退/重建立。
  Mastery _applyRules(
    Item item,
    Mastery base,
    Trial trial,
    (int, int)? seedPair,
    int target,
  ) {
    final r = TrialResult(
      correct: trial.correct,
      rtMs: trial.rtMs ?? 0,
      hintLevel: trial.hintLevelUsed,
      ts: trial.answeredAt ?? clock.nowUtcMs(),
    );
    var m = applyTrial(base, r, config);

    // 提示状态机（仅 RELATION；ANCHOR/DIRECT 闪现恒 0，PHRASE 无提示）。
    if (item.type == ItemType.relation) {
      final hm = HintMachine(
        level: m.hintLevel,
        cleanStreak: _cleanStreak(m.lastResults),
        consecutiveFail: trailingWrongStreak(m.lastResults),
      );
      final next = trial.correct
          ? hm.onCorrect(
              rtMs: r.rtMs, hintLevelUsed: r.hintLevel, config: config)
          : hm.onWrong(
              errorType: trial.errorType ?? ErrorType.other, config: config);
      m = m.copyWith(hintLevel: next.level);
    }

    final q = quality(trial, item.type, config);
    m = advance(m, q, sessionEndTs, clock, config);

    // 自动化判定（ANCHOR/DIRECT，窗口 20 由 source 供应）。
    if (item.type == ItemType.anchor || item.type == ItemType.direct) {
      final window = item.type == ItemType.anchor
          ? config.anchorAutoWindow
          : config.directAutoWindow;
      final history = [...source.recentResults(item.id, window), r];
      final up = checkAutomation(m, history, item.type, config);
      m = up.mastery;
      events.addAll(up.events);
      if (item.type == ItemType.anchor) {
        final rb = checkAnchorRebuild(m, config);
        events.addAll(rb.events);
      }
      if (item.type == ItemType.direct) {
        final p = target;
        final rel = checkRelapse(
          direct: m,
          diatonicIndex: p,
          relationItemIds: source.relationItemIdsFor(p),
          config: config,
          nowMs: clock.nowUtcMs(),
        );
        m = rel.mastery;
        for (final ev in rel.events) {
          events.add(ev);
          if (ev is RelapseEvent) {
            for (final rid in ev.relationItemIds) {
              source.saveMastery(resetRelationForRelapse(
                source.masteryOf(rid),
                nowMs: ev.dueAt,
                config: config,
              ));
            }
          }
        }
      }
    }

    // RELATION 作答后检查目标音位 DIRECT 晋升（05 §4）。
    if (item.type == ItemType.relation) {
      final direct = source.directMasteryOf(target);
      if (direct != null) {
        final history = [...source.relationHistoryFor(target), r];
        final up = checkPromotion(
          direct: direct,
          diatonicIndex: target,
          relationHistory: history,
          config: config,
          nowMs: clock.nowUtcMs(),
        );
        if (up.events.isNotEmpty) {
          source.saveMastery(up.mastery);
          events.addAll(up.events);
        }
      }
    }
    return m;
  }

  int _cleanStreak(List<TrialResult> results) {
    var n = 0;
    for (final r in results.reversed) {
      if (r.correct && r.hintLevel == 0 && r.rtMs <= config.hintDowngradeRtMs) {
        n++;
      } else {
        break;
      }
    }
    return n;
  }

  // ---- PHRASE 逐音（05 §9 特例 / 02 §5.2） ----

  void _answerPhraseNote(QueueEntry entry, AnswerEvent e, int rt, int elapsed) {
    final payload = entry.item.payload as PhrasePayload;
    final target = payload.noteSequence[_phraseSlot];
    final correct = _isCorrect(target, e);
    _recordPhraseNote(entry, e, rt, correct,
        targetOverride: target, elapsedMs: elapsed);
  }

  void _recordPhraseNote(
    QueueEntry entry,
    AnswerEvent? e,
    int? rt,
    bool correct, {
    bool timeout = false,
    int? targetOverride,
    int? elapsedMs,
  }) {
    final item = entry.item;
    final payload = item.payload as PhrasePayload;
    final target = targetOverride ?? payload.noteSequence[_phraseSlot];
    final cls = classify(
      item: item,
      targetIndex: target,
      answerPitchClass: e?.pitchClass,
      answerOctave: e?.octave,
      mode: mode,
      stage: stage,
      rtMs: rt ?? 0,
      timeout: timeout,
      correct: correct,
      config: config,
    );
    final ctx = ContextSnapshot(
      clef: payload.clefSequence[_phraseSlot],
      jitterSeed: entry.context.jitterSeed,
      phraseSlot: _phraseSlot,
      presentation: 'in_phrase',
    );
    final trial = Trial(
      sessionId: sessionId,
      itemId: item.id,
      presentedAt: clock.nowUtcMs() - (elapsedMs ?? rt ?? 0),
      answeredAt: clock.nowUtcMs(),
      rtMs: rt,
      correct: correct,
      timeout: timeout,
      errorType: cls.errorType,
      answerPitchClass: e?.pitchClass,
      answerOctave: e?.octave,
      inputSource: e?.source ??
          (mode == InputMode.nameButtons
              ? InputSource.nameButton
              : InputSource.virtualKey),
      contextSnapshot: ctx,
    );
    // 逐音试次落库；掌握度更新在整句完成时统一做（PHRASE 条目）。
    recorder.record(trial, source.masteryOf(item.id), cls.seedPair);
    lastTrial = trial;
    if (rt != null) _phraseRt.add(rt);
    _phraseCorrect.add(correct);
    _phraseSlot++;
    _onsetMono = null;

    if (_phraseSlot >= payload.noteSequence.length) {
      _finishPhrase(entry);
    } else {
      // 下一音：UI 播放反馈后再次 onPresented。
      _phase = SessionPhase.awaitingAnswer;
    }
  }

  void _finishPhrase(QueueEntry entry) {
    final item = entry.item;
    final n = _phraseCorrect.length;
    final acc = n == 0 ? 0.0 : _phraseCorrect.where((c) => c).length / n;
    final overallCorrect = acc == 1.0;
    recorder.recordPhrase(PhraseRecord(
      itemId: item.id,
      noteSequence: (item.payload as PhrasePayload).noteSequence,
      resetCount: _phraseResets,
      perNoteRt: List.of(_phraseRt),
      overallCorrect: acc,
      createdAt: clock.nowUtcMs(),
    ));
    // PHRASE 条目掌握度：整句正确率 + 逐音 RT 中位数 → q（05 §2）。
    final base = source.masteryOf(item.id);
    final r = TrialResult(
      correct: overallCorrect,
      rtMs: rtMedianOf(_phraseRt) ?? 0,
      hintLevel: 0,
      ts: clock.nowUtcMs(),
    );
    var m = applyTrial(base, r, config);
    final pseudoTrial = Trial(
      sessionId: sessionId,
      itemId: item.id,
      presentedAt: clock.nowUtcMs(),
      rtMs: r.rtMs,
      correct: overallCorrect,
      inputSource: _inputSourceForMode,
      contextSnapshot: entry.context,
    );
    final q = quality(pseudoTrial, ItemType.phrase, config,
        phrasePerNoteRt: _phraseRt);
    m = advance(m, q, sessionEndTs, clock, config);
    source.saveMastery(m);
    // 02 §5.2 第 5 条 / §5.5：错误音位反馈给其 DIRECT / 关系条目（双向联动）。
    _feedbackPhraseErrors(entry);
    doneCount++;
    if (acc < 1.0) {
      reexposure.onWrong(
        item: item,
        mastery: m,
        trial: pseudoTrial,
        currentIndex: _pos,
        sessionLength: _queue.length,
        phraseWrongRate: 1.0 - acc,
      );
    }
    _phase = SessionPhase.feedback;
  }

  /// 短句错误音位 → 单音位条目反馈（02 §5.2 第 5 条 / §5.5 双向联动）。
  ///
  /// 裁决（02 未定义反馈强度）：
  /// 1) DIRECT 条目只做一次 lapse（lapses+1、intervalDays=0、due 拉回会话末），
  ///    **不改 state、不动 ease** —— 回退由 checkRelapse 的连续 3 题错判定，
  ///    避免短句里一次失误把已自动化音位打回并让 ease 触底。
  /// 2) 关系条目只把「学习中/复习中」的提示级抬回脚手架（hintLevel = hintInitialLevel），
  ///    已自动化条目与更高提示级不动；不重置 due/state（避免抢占回退语义）。
  /// 3) 同一短句内重复出现的同一音位只反馈一次（去重）；正确音位不做正反馈。
  void _feedbackPhraseErrors(QueueEntry entry) {
    final payload = entry.item.payload as PhrasePayload;
    final wrong = <int>{};
    for (var i = 0;
        i < _phraseCorrect.length && i < payload.noteSequence.length;
        i++) {
      if (!_phraseCorrect[i]) wrong.add(payload.noteSequence[i]);
    }
    if (wrong.isEmpty) return;
    final dueAt = sessionEndTs ?? clock.localEndOfDayUtcMs(clock.localDate());
    for (final p in wrong) {
      final direct = source.directMasteryOf(p);
      if (direct != null &&
          (direct.state == ItemState.learning ||
              direct.state == ItemState.reviewing ||
              direct.state == ItemState.automated)) {
        source.saveMastery(direct.copyWith(
          lapses: direct.lapses + 1,
          intervalDays: 0,
          dueAt: () => dueAt,
        ));
      }
      for (final rid in source.relationItemIdsFor(p)) {
        final rm = source.masteryOf(rid);
        final learning = rm.state == ItemState.learning ||
            rm.state == ItemState.reviewing;
        if (learning && rm.hintLevel < config.hintInitialLevel) {
          source.saveMastery(
              rm.copyWith(hintLevel: config.hintInitialLevel));
        }
      }
    }
  }
}