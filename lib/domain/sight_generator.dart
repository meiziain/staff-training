// 规格: 11 §4 —— 视奏谱例生成器（约束生成，非题库）。
//
// 裁决记录：
// 1) 级进比例用「自适应强制」而非事后校验：一旦累计级进比 < 0.6，本步强制
//    mag=1，因此最终比例必然达标，无需整条重试（重试只用于无解情形）。
// 2) 禁止同音重复（步长 0）：规格上界是"不超过连续 2 次"，取更严格的禁止，
//    既满足约束也让级进统计口径干净（分母 = 全部步数）。
// 3) 双手单声部列占比取 1..ceil(0.7N)（规格"约 30%"在 N=6..10 下与
//    "至少 1 列双声部"冲突，放宽到 ≤50%；N>10 时上下声部上限 10/8 已到顶，
//    每列平均音数必然下降，上限再放宽到 ≤70%，否则无解）。
// 4) 起音间距 8–12 自然音级：先取上声部起音 8..12，再取间距 ≥ 起音值，
//    保证下声部起音落在 C4 以下（-4..0）。
// 5) 结束音落 C/F/G（mod 7 ∈ {0,3,4}）：只约束双手模式；单手规格未要求。
library;

import 'dart:math' as math;

import '../core/rng.dart';
import 'models/note_position.dart';
import 'models/sight_level.dart';
import 'models/sight_motive.dart';
import 'models/sight_score.dart';

/// 生成结果：谱例 + 去重放宽标记。
class SightGenResult {
  final SightScore score;
  final bool dedupRelaxed;
  const SightGenResult(this.score, {this.dedupRelaxed = false});
}

const int _maxAttempts = 300;
const double _stepRatioMin = 0.6;
const int _signatureSeparator = -99; // 不在音域内，仅作上/下声部签名分隔

/// 旋律轮廓（11 §4 补充裁决）。
///
/// 均匀随机游走方向每步独立，统计上必然呈等幅锯齿（用户实测"波浪型"）。
/// 先随机挑一条整体轮廓，再让每步有 65% 朝轮廓目标、35% 沿用上一步方向，
/// 得到有走向的旋律线，而不是原地摆动。
enum _SightContour { arch, ascend, descend, wave, flat }

/// 单手音数允许区间（S7 滑杆口径：4–32）。
const int sightSingleMinCount = 4;
const int sightSingleMaxCount = 32;

/// 双手列数允许区间（S7 滑杆口径：4–12）。
const int sightGrandMinColumns = 4;
const int sightGrandMaxColumns = 12;

/// 生成音数 / 列数默认值（单手与双手共用 8）。
const int sightDefaultLength = 8;

/// 单手旧预设档位（保留给历史入口与测试）。
const List<int> sightSingleLengths = [8, 12, 16];

/// 生成一条视奏谱例。
///
/// [recentSignatures] 取最近 N 条签名做去重（11 §4.1/§4.2）；
/// [columnCount] 为空时单手默认 8 音、双手默认 8 列。
///
/// [level] 非空时走动机库新路径（T03），旧 `_walk` 路径完全冻结；
/// [forceMotive] 仅在新路径生效，强制首个动机。
SightGenResult generateSightScore({
  required SightMode mode,
  required Rng rng,
  int? columnCount,
  List<String> recentSignatures = const [],
  int dedupWindow = 20,
  SightLevel? level,
  SightMotive? forceMotive,
}) {
  if (level != null) {
    return _generateByLevel(
      level,
      rng,
      columnCount ?? sightDefaultLength,
      recentSignatures,
      dedupWindow,
      forceMotive,
    );
  }
  final recent = recentSignatures.length <= dedupWindow
      ? recentSignatures
      : recentSignatures.sublist(recentSignatures.length - dedupWindow);
  SightScore? fallback;
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    final score = mode == SightMode.grand
        ? _tryGrand(rng, columnCount)
        : _trySingle(mode, rng, columnCount ?? sightDefaultLength);
    if (score == null) continue;
    if (!_valid(score)) continue;
    final sig = sightSignature(score);
    if (!recent.contains(sig)) return SightGenResult(score);
    fallback = score;
  }
  if (fallback != null) return SightGenResult(fallback, dedupRelaxed: true);
  throw StateError('视奏谱例生成 $_maxAttempts 次均不满足约束（mode=${mode.wire}）');
}

/// 谱例签名（去重口径）：上声部音位序列 + 分隔符 + 下声部音位序列。
String sightSignature(SightScore score) => [
      for (final c in score.columns)
        if (c.upper != null) c.upper!,
      _signatureSeparator,
      for (final c in score.columns)
        if (c.lower != null) c.lower!,
    ].join(',');

/// 稳定音级（C/F/G），双手结束音收束用。
bool _isStableDegree(int diatonicIndex) =>
    const {0, 3, 4}.contains(mod(diatonicIndex, 7));

// ---------------------------------------------------------------- 单手

SightScore? _trySingle(SightMode mode, Rng rng, int len) {
  final voice =
      mode == SightMode.trebleOnly ? SightVoice.upper : SightVoice.lower;
  final lo = sightVoiceMin(voice);
  final hi = sightVoiceMax(voice);
  final mid = (lo + hi) ~/ 2;
  // 起音落在音域中部 ±3 度（11 §4.1）。
  final start = (mid + rng.randInt(-3, 3)).clamp(lo, hi).toInt();
  final seq = _walk(rng, start, lo, hi, len, maxLeap: 2, stableEnd: false);
  if (seq == null) return null;
  return SightScore(
    mode: mode,
    columns: [for (final n in seq) SightColumn.single(voice, n)],
  );
}

// ---------------------------------------------------------------- 双手

SightScore? _tryGrand(Rng rng, int? columnCount) {
  final n = columnCount ?? sightDefaultLength;
  // 上声部 ceil(n*0.5)..min(10,n)、下声部 ceil(n*0.4)..min(8,n)。n 增大时
  // 靠抬高上限（10/8）吸收更多音，而不是压低音数下限（裁决 3 修订）。
  final uCount = rng.randInt(math.max(4, (n * 0.5).ceil()), math.min(10, n));
  final lCount = rng.randInt(math.max(3, (n * 0.4).ceil()), math.min(8, n));
  // 不设空列（整列上下都休止会让谱面出现断档），故双声部列数被唯一确定。
  final both = uCount + lCount - n;
  if (both < 1) return null;
  final uOnly = uCount - both;
  final lOnly = lCount - both;
  final single = uOnly + lOnly;
  // 单声部列 1..ceil(0.7N)：N 越大每列平均音数越低，50% 已无解（裁决 3）。
  if (single < 1 || single > (n * 0.7).ceil()) return null;

  final upperStart = rng.randInt(8, 12);
  final gap = rng.randInt(math.max(8, upperStart), 12);
  final lowerStart = upperStart - gap;

  final uSeq = _walk(rng, upperStart, sightTrebleMin, sightTrebleMax, uCount,
      maxLeap: 2, stableEnd: true);
  final lSeq = _walk(rng, lowerStart, sightBassMin, sightBassMax, lCount,
      maxLeap: 3, stableEnd: true);
  if (uSeq == null || lSeq == null) return null;

  final cols = _shuffledColumns(n, rng);
  final bothSet = cols.take(both).toSet();
  final uSet = bothSet.union(cols.skip(both).take(uOnly).toSet());
  final lSet = bothSet.union(cols.skip(both + uOnly).take(lOnly).toSet());

  final columns = <SightColumn>[];
  var ui = 0;
  var li = 0;
  for (var c = 0; c < n; c++) {
    final hasU = uSet.contains(c);
    final hasL = lSet.contains(c);
    columns.add(SightColumn(
      upper: hasU ? uSeq[ui++] : null,
      lower: hasL ? lSeq[li++] : null,
    ));
  }
  return SightScore(mode: SightMode.grand, columns: columns);
}

/// 0..n-1 的部分 Fisher-Yates 洗牌，返回全部列的一个排列。
List<int> _shuffledColumns(int n, Rng rng) {
  final pool = List<int>.generate(n, (i) => i);
  for (var i = n - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final t = pool[i];
    pool[i] = pool[j];
    pool[j] = t;
  }
  return pool;
}

// ---------------------------------------------------------------- 游走

/// 轮廓驱动的旋律生成（11 §4 补充裁决，解决"生成结果总是波浪型"）。
///
/// - 先随机选一条整体轮廓：arch / ascend / descend / wave / flat；
/// - 方向决策优先「跳进后反向级进」→「65% 朝轮廓目标」→「65% 惯性」；
/// - 步长上声部 85% 级进、15% 三度；下声部 75/20/5；
/// - 越界反弹，两向都越界则本步作废；级进比例自适应保证 ≥ 0.6（裁决 1）；
/// - [stableEnd] 为 true 时最后一步只接受稳定音级（裁决 5）。
List<int>? _walk(
  Rng rng,
  int start,
  int lo,
  int hi,
  int len, {
  required int maxLeap,
  required bool stableEnd,
  _SightContour? contour,
}) {
  final _SightContour shape = contour ?? rng.pick(_SightContour.values);
  final span = math.max(1, len - 1);
  final upRoom = hi - start;
  final downRoom = start - lo;
  // 轮廓幅度受起音到两端余量约束，保证峰值不越界。
  final archAmp = math.min(rng.randInt(4, 6), math.min(upRoom, downRoom));
  final netUp = math.min(rng.randInt(3, 8), upRoom);
  final netDown = math.min(rng.randInt(3, 8), downRoom);
  final flatNet = rng
      .randInt(-2, 2)
      .clamp(-math.min(2, downRoom), math.min(2, upRoom))
      .toInt();

  double targetAt(int i) {
    final t = i / span;
    return switch (shape) {
      _SightContour.arch => start + archAmp * math.sin(math.pi * t),
      _SightContour.ascend => start + netUp * t,
      _SightContour.descend => start - netDown * t,
      _SightContour.wave => start + archAmp * math.sin(2 * math.pi * t),
      _SightContour.flat => start + flatNet * t,
    };
  }

  final seq = <int>[start];
  var steps = 0;
  var total = 0;
  var lastDir = rng.chance(0.5) ? 1 : -1;
  var lastWasLeap = false;

  for (var i = 1; i < len; i++) {
    final prev = seq.last;
    final isLast = i == len - 1;
    final forceStep = total > 0 && steps * 10 < total * 6;
    // 用轮廓"斜率"而不是 target-prev：音符每步跳 1–2 度，而目标曲线每步只
    // 移动不到 1 度，prev 会反复冲过目标导致方向反转（实测同向仅 49.8%）。
    // 斜率给出的是该段的走向，与当前音是否超前无关。
    final slope = targetAt(math.min(i + 1, len - 1)) - targetAt(i);
    int chosen;
    if (isLast && stableEnd) {
      // 结束音枚举候选（裁决 5）：级进候选优先，无候选时才允许跳进。
      final near = <int>[];
      final far = <int>[];
      for (var mag = 1; mag <= maxLeap; mag++) {
        for (final dir in const [1, -1]) {
          final next = prev + dir * mag;
          if (next < lo || next > hi) continue;
          if (!_isStableDegree(next)) continue;
          (mag == 1 ? near : far).add(next);
        }
      }
      final pool = forceStep && near.isNotEmpty ? near : [...near, ...far];
      if (pool.isEmpty) return null;
      chosen = rng.pick(pool);
    } else {
      int? found;
      int? nextDir;
      for (var attempt = 0; attempt < 24; attempt++) {
        // 方向：跳进后反向 > 沿轮廓斜率 > 惯性。
        final dir = lastWasLeap
            ? -lastDir
            : (slope.abs() > 0.08 && rng.chance(0.75))
                ? (slope > 0 ? 1 : -1)
                : (rng.chance(0.7) ? lastDir : -lastDir);
        // 步长：跳进后必级进；forceStep 时必级进；否则按声部概率。
        // 上声部跳进率降到 10%：跳进必触发下一步反向，过多会抵消方向惯性。
        final mag = forceStep || lastWasLeap
            ? 1
            : maxLeap == 2
                ? (rng.chance(0.9) ? 1 : 2)
                : (rng.chance(0.75) ? 1 : rng.chance(0.8) ? 2 : 3);
        var next = prev + dir * mag;
        if (next < lo || next > hi) next = prev - dir * mag;
        if (next < lo || next > hi) continue;
        found = next;
        nextDir = dir;
        break;
      }
      if (found == null || nextDir == null) return null;
      lastDir = nextDir;
      lastWasLeap = (found - prev).abs() > 1;
      chosen = found;
    }
    if ((chosen - prev).abs() == 1) steps++;
    total++;
    seq.add(chosen);
  }
  return seq;
}

// ---------------------------------------------------------------- 校验

bool _valid(SightScore score) {
  if (!score.inRange) return false;
  for (final voice in SightVoice.values) {
    final seq = score.sequenceOf(voice).whereType<int>().toList();
    if (seq.isEmpty) continue;
    if (!_validRun(seq, voice)) return false;
  }
  // 双手必须两声部都有音（单手模式另一声部必然为空）。
  if (score.mode == SightMode.grand &&
      (score.voiceAbsent(SightVoice.upper) ||
          score.voiceAbsent(SightVoice.lower))) {
    return false;
  }
  return true;
}

bool _validRun(List<int> seq, SightVoice voice) {
  if (seq.length < 2) return true;
  final maxLeap = voice == SightVoice.upper ? 2 : 3;
  var steps = 0;
  for (var i = 1; i < seq.length; i++) {
    final d = (seq[i] - seq[i - 1]).abs();
    if (d < 1 || d > maxLeap) return false;
    if (d == 1) steps++;
  }
  return steps / (seq.length - 1) >= _stepRatioMin;
}

// ---------------------------------------------------------------- 动机库新路径（T03）

/// 动机拼接出的一个音事件（起始拍 / 音级 / 时值）。
class _LevelNote {
  final int onset;
  final int index;
  final int duration;

  const _LevelNote(this.onset, this.index, this.duration);
}

/// 一条音事件序列 + 所用动机 wire 序列。
class _MotiveSequence {
  final List<_LevelNote> notes;
  final List<String> kinds;

  const _MotiveSequence(this.notes, this.kinds);
}

/// 按难度档生成：level 非空时旧 `_walk` 路径完全不执行。
SightGenResult _generateByLevel(
  SightLevel level,
  Rng rng,
  int columnCount,
  List<String> recentSignatures,
  int dedupWindow,
  SightMotive? forceMotive,
) {
  final recent = recentSignatures.length <= dedupWindow
      ? recentSignatures
      : recentSignatures.sublist(recentSignatures.length - dedupWindow);
  SightScore? fallback;
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    final score = _tryMotif(level, rng, columnCount, forceMotive);
    if (score == null) continue;
    if (!_validByLevel(score)) continue;
    final sig = sightMotiveSignature(score, level);
    if (!recent.contains(sig)) return SightGenResult(score);
    fallback = score;
  }
  if (fallback != null) return SightGenResult(fallback, dedupRelaxed: true);
  throw StateError('动机谱例生成 $_maxAttempts 次均不满足约束（level=${level.wire}）');
}

/// 动机去重签名：`MOTIVE|level|kind序列|起音|时值型`。
/// legacy [sightSignature] 的格式保持不变。
String sightMotiveSignature(SightScore score, SightLevel level) => [
      'MOTIVE',
      level.wire,
      (score.motiveIds ?? const <String>[]).join('/'),
      score.columns.isEmpty
          ? ''
          : '${score.columns.first.upper ?? score.columns.first.lower}',
      score.columns.map((c) => c.durationBeats).join(''),
    ].join('|');

bool _validByLevel(SightScore score) {
  if (score.columns.isEmpty || !score.inRange) return false;
  if (score.columns.any((c) => c.isEmpty)) return false;
  if (score.mode == SightMode.grand &&
      (score.voiceAbsent(SightVoice.upper) ||
          score.voiceAbsent(SightVoice.lower))) {
    return false;
  }
  return true;
}

/// 档位下某声部的音域闭区间。grand 档上声部从 C4 起、下声部到 C4 止。
int _levelVoiceLo(SightLevelSpec spec, SightVoice voice) => voice == SightVoice.upper
    ? math.max(sightTrebleMin, spec.pitchMin ?? sightTrebleMin)
    : math.max(sightBassMin, spec.pitchMin ?? sightBassMin);

int _levelVoiceHi(SightLevelSpec spec, SightVoice voice) => voice == SightVoice.upper
    ? math.min(sightTrebleMax, spec.pitchMax ?? sightTrebleMax)
    : math.min(sightBassMax, spec.pitchMax ?? sightBassMax);

/// 档位允许时值：P0 动机本身全 1 拍，档位含 2 拍时少量拉长末音以增加变化。
int _pickDuration(SightLevelSpec spec, Rng rng) {
  final options = spec.allowedDurations.toList()..sort();
  if (options.length == 1) return options.first;
  return rng.chance(0.25) ? options.last : options.first;
}

/// 拼接 3–5 个（必要时更多以凑够 [targetNotes]）P0 动机。
_MotiveSequence _buildMotiveSequence(
  SightLevelSpec spec,
  SightVoice voice,
  Rng rng,
  int targetNotes,
  SightMotive? forceMotive,
) {
  final lo = _levelVoiceLo(spec, voice);
  final hi = _levelVoiceHi(spec, voice);
  if (lo > hi) return const _MotiveSequence([], []);

  final fitting = forceMotive == null ? kP0Motives : [forceMotive];
  var start = lo;
  var startFound = false;
  for (var i = 0; i < 24; i++) {
    final candidate = rng.randInt(lo, hi);
    if (fitting.any((m) => m.fits(candidate, lo, hi))) {
      start = candidate;
      startFound = true;
      break;
    }
  }
  if (!startFound) return const _MotiveSequence([], []);

  final notes = <_LevelNote>[];
  final kinds = <String>[];
  var current = start;
  var onset = 0;
  notes.add(_LevelNote(0, current, _pickDuration(spec, rng)));
  var emitted = 0;
  // 常规为 3–5 个动机；目标音数更多时继续拼接到 targetNotes（最大 32 音滑杆）。
  final planned = rng.randInt(3, 5);
  final limit = math.max(planned, targetNotes).clamp(3, 32);

  while (notes.length < targetNotes && emitted < limit) {
    emitted++;
    final forced = forceMotive;
    SightMotive? chosen;
    if (emitted == 1 && forced != null && forced.fits(current, lo, hi)) {
      chosen = forced;
    } else {
      for (var attempt = 0; attempt < 3; attempt++) {
        final candidate = rng.pick(kP0Motives);
        if (candidate.fits(current, lo, hi)) {
          chosen = candidate;
          break;
        }
      }
    }

    if (chosen == null) {
      // 无解时退化为级进 ±1 连接音。
      final before = notes.length;
      final firstDir = rng.chance(0.5) ? 1 : -1;
      for (final dir in [firstDir, -firstDir]) {
        final next = current + dir;
        if (next < lo || next > hi) continue;
        final duration = _pickDuration(spec, rng);
        current = next;
        onset += duration;
        notes.add(_LevelNote(onset, current, duration));
        break;
      }
      if (notes.length == before) break;
      continue;
    }

    final applied = chosen.applyFrom(current);
    for (var i = 1; i < applied.length && notes.length < targetNotes; i++) {
      final duration = _pickDuration(spec, rng);
      current = applied[i];
      onset += duration;
      notes.add(_LevelNote(onset, current, duration));
    }
    kinds.add(chosen.wire);
  }
  return _MotiveSequence(notes, kinds);
}

/// 动机路径生成一条谱例；同列合并上下声部，按起始拍升序输出。
SightScore? _tryMotif(
  SightLevel level,
  Rng rng,
  int columnCount,
  SightMotive? forceMotive,
) {
  final spec = level.spec;
  final primaryVoice =
      spec.mode == SightMode.bassOnly ? SightVoice.lower : SightVoice.upper;
  final primary =
      _buildMotiveSequence(spec, primaryVoice, rng, columnCount, forceMotive);
  if (primary.notes.isEmpty) return null;

  final byOnset = <int, SightColumn>{};
  void put(_LevelNote n, SightVoice voice) {
    final old = byOnset[n.onset];
    byOnset[n.onset] = SightColumn(
      upper: voice == SightVoice.upper ? n.index : old?.upper,
      lower: voice == SightVoice.lower ? n.index : old?.lower,
      onsetBeat: n.onset,
      durationBeats: math.max(old?.durationBeats ?? 1, n.duration),
    );
  }

  for (final n in primary.notes) {
    put(n, primaryVoice);
  }
  final kinds = <String>[...primary.kinds];

  if (spec.mode == SightMode.grand) {
    final lowerSeq = level == SightLevel.L5_SR_P
        ? _MotiveSequence(
            [
              for (final n in primary.notes)
                _LevelNote(n.onset, n.index - 7, n.duration),
            ],
            const <String>[],
          )
        : _buildMotiveSequence(spec, SightVoice.lower, rng, columnCount, null);
    if (lowerSeq.notes.isEmpty) return null;
    for (final n in lowerSeq.notes) {
      if (n.index < sightBassMin || n.index > sightBassMax) return null;
      put(n, SightVoice.lower);
    }
    kinds.addAll(lowerSeq.kinds);
  }

  final entries = byOnset.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return SightScore(
    mode: spec.mode,
    columns: [for (final e in entries) e.value],
    beatsPerBar: spec.beatsPerBar,
    chunkRanges: const <SightChunkRange>[],
    motiveIds: kinds.isEmpty ? null : kinds,
  );
}
