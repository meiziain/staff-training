// 规格: 11 §3 / 视奏训练改进 P0 T03 —— 拍网格驱动的视奏判定引擎。零 Flutter 依赖。
//
// 新语义（T03）：submit 只把输入记入当前拍输入槽，不推进任何光标；tick 在拍
// onset 到点时统一结算四色并推进光标（答错也走）。旧「提交即推进 / 答错不动」
// 语义已完整迁移到 sight_free_engine.dart 的 SightFreeEngine，供分手练习入口使用。
//
// Δ = 输入时刻 - 拍 onset；负=早(early)、正=晚(late)。判定基准为
// SightBeatClock.onsetOf(beatIndex)，UI 帧与音频实际发声时刻不参与判定。
library;

import '../core/clock.dart';
import 'models/sight_beat_result.dart';
import 'models/sight_level.dart';
import 'models/sight_score.dart';
import 'sight_beat_clock.dart';

/// 谱面上的一个音：所在列 + 音位。
class SightNote {
  final int column;
  final int diatonicIndex;

  const SightNote(this.column, this.diatonicIndex);

  String get key => '$column:$diatonicIndex';

  @override
  bool operator ==(Object other) =>
      other is SightNote &&
      other.column == column &&
      other.diatonicIndex == diatonicIndex;

  @override
  int get hashCode => Object.hash(column, diatonicIndex);

  @override
  String toString() => 'SightNote(col=$column, idx=$diatonicIndex)';
}

/// 单声部轨道：该声部的全部音（按列升序）+ 光标。
class SightVoiceTrack {
  final SightVoice voice;
  final List<SightNote> notes;
  int cursor = 0;

  SightVoiceTrack(this.voice, this.notes);

  bool get done => cursor >= notes.length;

  SightNote? get current => done ? null : notes[cursor];

  /// 已完成（已结算）的列号，供渲染层淡化符头。
  Iterable<int> get doneColumns => notes.take(cursor).map((n) => n.column);

  /// 剩余音数（含当前待答）。
  int get remaining => notes.length - cursor;
}

/// 按谱面模式建立某声部的轨道；该声部缺席或无声时返回 null。
/// 两个引擎共用，避免重复实现（T03）。
SightVoiceTrack? buildSightVoiceTrack(SightScore score, SightVoice voice) {
  if (voice == SightVoice.upper && !score.mode.hasUpper) return null;
  if (voice == SightVoice.lower && !score.mode.hasLower) return null;
  final notes = <SightNote>[];
  for (var i = 0; i < score.columns.length; i++) {
    final n = score.columns[i].noteIn(voice);
    if (n != null) notes.add(SightNote(i, n));
  }
  return notes.isEmpty ? null : SightVoiceTrack(voice, notes);
}

/// 判定窗口档位。
///
/// spec 枚举写作 \{relaxed, normal, strict\}，而构造器默认值写作
/// `SightTimingWindow.standard`。两者都保留：standard 与 normal 同义（±120ms）。
enum SightTimingWindow { relaxed, normal, standard, strict }

extension SightTimingWindowX on SightTimingWindow {
  /// 单侧容差（ms）：±200 / ±120 / ±80。
  int get windowMs => switch (this) {
        SightTimingWindow.relaxed => 200,
        SightTimingWindow.normal => 120,
        SightTimingWindow.standard => 120,
        SightTimingWindow.strict => 80,
      };
}

/// 一次输入的结果（legacy 与 FreeEngine 亦使用）。
class SightSubmitResult {
  /// 是否匹配到某个待答音（注意：不代表已推进光标）。
  final bool accepted;

  /// 被匹配的声部；未匹配时为 null。
  final SightVoice? voice;

  /// 被匹配的待答音；未匹配时为 null。
  final SightNote? note;

  /// 连错达到提示阈值。
  final bool hintDue;

  /// 本次输入后整段是否完成。
  final bool finished;

  const SightSubmitResult({
    required this.accepted,
    this.voice,
    this.note,
    this.hintDue = false,
    required this.finished,
  });
}

/// 当前拍输入槽中的一次输入。
class _PendingInput {
  final int diatonicIndex;
  final int atMonoMs;
  final SightVoice? voice;
  bool consumed = false;

  _PendingInput(this.diatonicIndex, this.atMonoMs, this.voice);
}

/// 拍网格视奏引擎。
class SightSessionEngine {
  final SightScore score;
  final SightVoiceTrack? upper;
  final SightVoiceTrack? lower;

  /// 连错多少次触发一次音名提示。
  final int hintThreshold;

  final SightLevel level;
  final int pairWindowMs;
  final SightTimingWindow timingWindow;
  final Clock clock;

  /// 拍号分母：只影响自建拍钟的每拍时长，不改任何音高逻辑。
  final int denominator;

  /// 速度：每分钟四分音符数（♩=N），与拍号无关。
  final int quartersPerMinute;

  /// 可由 UI 注入同一个拍网格时钟；未提供时按速度/拍号自建并从构造时刻起跑。
  late final SightBeatClock _beatClock;

  int _correct = 0;
  int _errors = 0;
  int _streak = 0;
  int _onBeatCount = 0;
  int _earlyCount = 0;
  int _lateCount = 0;
  int _missCount = 0;
  int _timingBiasSum = 0;
  int _timingBiasCount = 0;
  int _longestHitStreak = 0;
  int _currentHitStreak = 0;
  int _lastBeatIndex = -1;

  /// 逐音错误计数（diatonicIndex → 次数），供完成页 top3 与 P4 落库。
  final Map<int, int> _errorPositions = {};

  /// 本拍尚未结算的输入。
  final List<_PendingInput> _slot = [];

  SightSessionEngine(
    this.score, {
    this.hintThreshold = 3,
    this.level = SightLevel.L1,
    this.pairWindowMs = 150,
    this.timingWindow = SightTimingWindow.standard,
    this.denominator = 4,
    this.quartersPerMinute = 60,
    Clock? clock,
    SightBeatClock? beatClock,
  })  : clock = clock ?? SystemClock(),
        upper = buildSightVoiceTrack(score, SightVoice.upper),
        lower = buildSightVoiceTrack(score, SightVoice.lower) {
    if (upper == null && lower == null) {
      throw ArgumentError('谱例没有任何音（mode=${score.mode.wire}）');
    }
    _beatClock = beatClock ??
        SightBeatClock(
          clock: this.clock,
          quartersPerMinute: quartersPerMinute,
          denominator: denominator,
        );
    // 自建时钟才自动起跑；注入的时钟由调用方负责 start/pause/resume。
    if (beatClock == null) _beatClock.start(this.clock.monotonicMs());
  }

  /// 单侧判定窗（ms）。
  int get windowMs => timingWindow.windowMs;

  /// 当前使用的拍网格（供 UI 复用同一时间基准）。
  SightBeatClock get beatClock => _beatClock;

  /// 全谱总音数。
  int get totalNotes => (upper?.notes.length ?? 0) + (lower?.notes.length ?? 0);

  /// 已命中音数（onBeat / early / late 均算命中）。
  int get correctNotes => _correct;

  /// 累计 miss 次数。
  int get errorCount => _errors;

  /// 逐音 miss 计数。
  Map<int, int> get errorPositions => Map.unmodifiable(_errorPositions);

  /// 连续 miss 数。
  int get errorStreak => _streak;

  bool get finished => (upper?.done ?? true) && (lower?.done ?? true);

  /// 按已结算光标计算进度（miss 也推进，故完成后必为 1）。
  double get progress {
    final total = totalNotes;
    if (total == 0) return 1;
    return ((upper?.cursor ?? 0) + (lower?.cursor ?? 0)) / total;
  }

  /// 当前待答的音（0–2 个），供渲染光标与判定。
  List<SightNote> get pending => [
        if (upper?.current != null) upper!.current!,
        if (lower?.current != null) lower!.current!,
      ];

  /// 某声部当前光标所在列；该声部已完成时为 null。
  int? cursorColumnOf(SightVoice voice) =>
      voice == SightVoice.upper ? upper?.current?.column : lower?.current?.column;

  int get onBeatCount => _onBeatCount;
  int get earlyCount => _earlyCount;
  int get lateCount => _lateCount;
  int get missCount => _missCount;

  /// 命中拍 Δ 的有符号均值（负=整体偏早）；无命中返回 0。
  double get timingBiasMs =>
      _timingBiasCount == 0 ? 0 : _timingBiasSum / _timingBiasCount;

  /// 最长连续非 miss 拍数。
  int get longestHitStreak => _longestHitStreak;

  /// 本拍输入槽大小（供 UI / 测试观察；不暴露内部列表）。
  int get pendingInputCount => _slot.length;

  /// 提交一次音高作答，只入槽、不推进光标。
  ///
  /// [atMonoMs] 为空时取注入 Clock 的 monotonicMs。先上后下：同一拍内每个
  /// 声部最多接收一个输入，两侧同音时第一次归上声部、第二次归下声部。
  SightSubmitResult submit(int diatonicIndex, {int? atMonoMs}) {
    if (finished) {
      throw StateError('视奏已结束，不可再提交');
    }
    final at = atMonoMs ?? clock.monotonicMs();
    final target = _voiceForInput(diatonicIndex);
    _slot.add(_PendingInput(diatonicIndex, at, target));
    if (target != null) {
      final note = target == SightVoice.upper ? upper!.current! : lower!.current!;
      return SightSubmitResult(
        accepted: true,
        voice: target,
        note: note,
        finished: finished,
      );
    }
    final projectedMisses =
        _streak + _slot.where((e) => e.voice == null).length;
    return SightSubmitResult(
      accepted: false,
      hintDue: projectedMisses % hintThreshold == 0,
      finished: finished,
    );
  }

  SightVoice? _voiceForInput(int diatonicIndex) {
    final u = upper?.current;
    if (u != null &&
        u.diatonicIndex == diatonicIndex &&
        !_slot.any((e) => e.voice == SightVoice.upper)) {
      return SightVoice.upper;
    }
    final l = lower?.current;
    if (l != null &&
        l.diatonicIndex == diatonicIndex &&
        !_slot.any((e) => e.voice == SightVoice.lower)) {
      return SightVoice.lower;
    }
    return null;
  }

  /// 结算第 [beatIndex] 拍：四色判定 + 光标推进（含 miss 跳过）。
  /// [beatIndex] 必须严格递增。
  SightBeatResult tick(int beatIndex, {required int nowMonoMs}) {
    if (beatIndex <= _lastBeatIndex) {
      throw StateError(
        'beatIndex 必须严格递增：收到 $beatIndex，上次 $_lastBeatIndex',
      );
    }
    return _resolveBeat(beatIndex, nowMonoMs: nowMonoMs);
  }

  /// 强制跳过当前拍：所有待答声部记 miss 并推进，语义同 tick 的 miss 分支。
  SightBeatResult skipCurrentBeat({required int nowMonoMs}) =>
      _resolveBeat(_lastBeatIndex + 1, nowMonoMs: nowMonoMs, forceMiss: true);

  SightBeatResult _resolveBeat(
    int beatIndex, {
    required int nowMonoMs,
    bool forceMiss = false,
  }) {
    _lastBeatIndex = beatIndex;
    final onset = _beatClock.onsetOf(beatIndex);

    // onset 已到（或漏拍补到）的待答音都在本拍结算。
    final due = <SightVoiceTrack>[];
    for (final track in [upper, lower]) {
      if (track == null || track.current == null) continue;
      if (_columnOnset(track.current!.column) <= beatIndex) due.add(track);
    }

    final hits = <SightVoiceHit>[];
    final matchedDeltas = <SightVoice, int>{};

    for (final track in due) {
      final note = track.current!;
      _PendingInput? matched;
      if (!forceMiss) {
        for (final input in _slot) {
          if (!input.consumed &&
              input.voice == track.voice &&
              input.diatonicIndex == note.diatonicIndex) {
            matched = input;
            break;
          }
        }
      }

      SightHitGrade grade;
      int? delta;
      if (matched == null) {
        grade = SightHitGrade.miss;
      } else {
        matched.consumed = true;
        delta = matched.atMonoMs - onset;
        final absDelta = delta.abs();
        grade = absDelta <= windowMs
            ? SightHitGrade.onBeat
            : (delta < 0 ? SightHitGrade.early : SightHitGrade.late);
        matchedDeltas[track.voice] = delta;
      }

      hits.add(SightVoiceHit(
        voice: track.voice,
        diatonicIndex: note.diatonicIndex,
        deltaMs: delta,
        grade: grade,
      ));

      // 无论命中与否都推进一格：答错也走。
      track.cursor++;
      _applyHit(grade, delta, note.diatonicIndex);
    }

    // SR 共享光标档：同一拍两侧输入时差须在配对窗内。
    var pairOk = true;
    if (level.spec.sharedCursor && matchedDeltas.length == 2) {
      final diff = (matchedDeltas[SightVoice.upper]! -
              matchedDeltas[SightVoice.lower]!)
          .abs();
      pairOk = diff <= pairWindowMs;
    }

    _slot.clear();
    return SightBeatResult(
      beatIndex: beatIndex,
      beatOnsetMonoMs: onset,
      hits: hits,
      finished: finished,
      skipped: forceMiss,
      pairWindowOk: pairOk,
    );
  }

  void _applyHit(SightHitGrade grade, int? delta, int expectedIndex) {
    if (grade == SightHitGrade.miss) {
      _missCount++;
      _errors++;
      _streak++;
      _currentHitStreak = 0;
      _errorPositions[expectedIndex] = (_errorPositions[expectedIndex] ?? 0) + 1;
      return;
    }
    _correct++;
    _streak = 0;
    _currentHitStreak++;
    if (_currentHitStreak > _longestHitStreak) {
      _longestHitStreak = _currentHitStreak;
    }
    switch (grade) {
      case SightHitGrade.onBeat:
        _onBeatCount++;
      case SightHitGrade.early:
        _earlyCount++;
      case SightHitGrade.late:
        _lateCount++;
      case SightHitGrade.miss:
        break;
    }
    if (delta != null) {
      _timingBiasSum += delta;
      _timingBiasCount++;
    }
  }

  /// 当前待答音所在列的起始拍。
  int _columnOnset(int column) => score.columns[column].onsetBeat;
}

/// MIDI → diatonicIndex（C4=60 → 0）；非自然音（黑键）返回 null。
///
/// 视奏只作答自然音（11 §4.1：v1 无变音）。换算与 note_position.dart 的
/// `midiOf` 互逆：octave = midi ~/ 12 - 1，diatonicIndex = (octave - 4) * 7 + 音级。
int? midiToDiatonicIndex(int midi) {
  const degreeOfSemitone = <int, int>{
    0: 0, // C
    2: 1, // D
    4: 2, // E
    5: 3, // F
    7: 4, // G
    9: 5, // A
    11: 6, // B
  };
  final degree = degreeOfSemitone[midi % 12];
  if (degree == null) return null; // 黑键（C#/D#/F#/G#/A#）不参与视奏作答。
  final octave = midi ~/ 12 - 1; // MIDI 60 = C4。
  return (octave - 4) * 7 + degree;
}
