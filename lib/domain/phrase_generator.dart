// 规格: 05 §6 短句生成器 / 02 §5.1 短句生成 §5.3 复位锚点 §5.4 答错处理。
// 裁决记录:
// 1) "连续两次越界则重生成" 实现为：原方向越界且反弹（改符号）后仍越界 → 本次
//    尝试作废重生成，计入 100 次重试上限。
// 2) 单谱表句游走边界 = 当前谱表范围 ∩ 池（treble [0,14] / bass [-7,0]），
//    保证逐音 canClef；跨谱表句前后段分别按各自谱表范围游走。
// 3) 起点候选为空时：单谱表句先尝试另一谱表，仍无则回退共享音位 C4；
//    跨谱表句前段无候选直接回退 C4（05 未定义空集行为）。
// 4) 跨谱表支点 C4 归属后段 clefB（切换点即支点），全句恰一次切换；
//    校验要求切换处音位必为 0。
// 5) phraseMaxLeapSteps=3 指"三度"（02 §5.1），自然音级步长上限 = 3-1 = 2。
// 6) 重试 100 次仍撞去重 → 放宽去重并置 dedupRelaxed 标记（日志事件由调用方
//    据该标记记录）；其余约束永不放宽；100 次内无合法候选则抛 StateError。
// 7) wrongPhraseVariant 谱表指派：优先逐位保持原谱表，其次整体单谱表，
//    最后在内部 C4 支点处一次切换；均不可行则换移调/镜像重试。
library;

import '../core/config.dart';
import '../core/rng.dart';
import 'models/enums.dart';
import 'models/item.dart';
import 'models/note_position.dart';

/// 生成结果：payload + 去重放宽标记（05 §6 "记录日志"）。
class PhraseGenResult {
  final PhrasePayload payload;
  final bool dedupRelaxed;
  const PhraseGenResult(this.payload, {this.dedupRelaxed = false});
}

const int _maxAttempts = 100; // 05 §6 重试上限
const double _crossClefProb = 0.3; // 05 §6 跨谱表句概率
const double _stepProb = 0.6; // 05 §6 P(±1)=0.6

/// 02 §5.3：复位依赖 >1 次/句的短句不判稳定。
bool phraseResetAllowsStable(int resetCount) => resetCount <= 1;

List<List<int>> _recentWindow(
        List<List<int>> recentSequences, int window) =>
    recentSequences.length <= window
        ? recentSequences
        : recentSequences.sublist(recentSequences.length - window);

bool _seqEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isDup(List<int> seq, List<List<int>> recent) =>
    recent.any((r) => _seqEq(r, seq));

bool _inRange(int i, Clef clef) => inPool(i) && canClef(i, clef);

/// 单步游走：0.6 抽 ±1、0.4 抽 ±2，方向均匀；越界反弹，两次越界返回 null。
int? _step(int cur, Clef clef, Rng rng) {
  final mag = rng.chance(_stepProb) ? 1 : 2;
  final dir = rng.chance(0.5) ? 1 : -1;
  var nxt = cur + dir * mag;
  if (!_inRange(nxt, clef)) {
    nxt = cur - dir * mag;
    if (!_inRange(nxt, clef)) return null;
  }
  return nxt;
}

/// 硬约束校验（05 §6）：池内、逐音 canClef、步长 1..2、级进比例、
/// 最多一次谱表切换且切换处必为 C4。
bool _hardValid(PhrasePayload p, Config config) {
  final seq = p.noteSequence;
  if (seq.length < 2) return false;
  for (var i = 0; i < seq.length; i++) {
    if (!inPool(seq[i]) || !canClef(seq[i], p.clefSequence[i])) return false;
  }
  var steps = 0;
  var switches = 0;
  final maxStep = config.phraseMaxLeapSteps - 1;
  for (var i = 1; i < seq.length; i++) {
    final d = (seq[i] - seq[i - 1]).abs();
    if (d < 1 || d > maxStep) return false;
    if (d == 1) steps++;
    if (p.clefSequence[i] != p.clefSequence[i - 1]) {
      switches++;
      if (seq[i] != 0) return false;
    }
  }
  if (switches > 1) return false;
  return steps / (seq.length - 1) >= config.phraseStepMinRatio;
}

PhrasePayload? _tryGenerate(
  int stage,
  Rng rng,
  Set<int> union,
  Config config,
) {
  final len = stage == 4
      ? config.phraseLenStage4
      : rng.randInt(config.phraseLenStage5Min, config.phraseLenStage5Max);
  final cross = stage == 5 && rng.chance(_crossClefProb);

  if (cross) {
    if (len < 3) return null;
    final k = rng.randInt(1, len - 2);
    final clefA = rng.chance(0.5) ? Clef.treble : Clef.bass;
    final clefB = clefA == Clef.treble ? Clef.bass : Clef.treble;
    final starts = union.where((i) => canClef(i, clefA)).toList();
    final start = starts.isEmpty ? 0 : rng.pick(starts);
    final seq = List<int>.filled(len, 0);
    seq[0] = start;
    var cur = start;
    for (var p = 1; p < k; p++) {
      final nxt = _step(cur, clefA, rng);
      if (nxt == null) return null;
      seq[p] = nxt;
      cur = nxt;
    }
    // 支点前一步必须距 C4 一/二度（保证进入支点的步长合法）。
    if (cur.abs() < 1 || cur.abs() > 2) return null;
    seq[k] = 0;
    cur = 0;
    for (var p = k + 1; p < len; p++) {
      final nxt = _step(cur, clefB, rng);
      if (nxt == null) return null;
      seq[p] = nxt;
      cur = nxt;
    }
    return PhrasePayload(
      noteSequence: seq,
      clefSequence: [for (var p = 0; p < len; p++) p < k ? clefA : clefB],
    );
  }

  var clef =
      stage == 4 ? Clef.treble : (rng.chance(0.5) ? Clef.treble : Clef.bass);
  var starts = union.where((i) => canClef(i, clef)).toList();
  if (starts.isEmpty) {
    final other = clef == Clef.treble ? Clef.bass : Clef.treble;
    final os = union.where((i) => canClef(i, other)).toList();
    if (os.isNotEmpty) {
      clef = other;
      starts = os;
    } else {
      starts = [0];
    }
  }
  final seq = <int>[rng.pick(starts)];
  for (var p = 1; p < len; p++) {
    final nxt = _step(seq.last, clef, rng);
    if (nxt == null) return null;
    seq.add(nxt);
  }
  return PhrasePayload(
    noteSequence: seq,
    clefSequence: List.filled(len, clef),
  );
}

/// 短句生成（05 §6 / 02 §5.1）。stage ∈ {4,5}。
/// recentSequences 取最近 phraseDedupWindow 条做去重。
PhraseGenResult generatePhrase({
  required int stage,
  required Rng rng,
  List<List<int>> recentSequences = const [],
  Set<int> automatedIndices = const {},
  Set<int> anchorIndices = const {},
  Config config = Config.defaults,
}) {
  assert(stage == 4 || stage == 5, '短句仅在阶段 4/5 生成（02 §5.1）');
  final union = {...automatedIndices, ...anchorIndices}.where(inPool).toSet();
  final recent = _recentWindow(recentSequences, config.phraseDedupWindow);
  PhrasePayload? fallback;
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    final cand = _tryGenerate(stage, rng, union, config);
    if (cand == null || !_hardValid(cand, config)) continue;
    if (!_isDup(cand.noteSequence, recent)) return PhraseGenResult(cand);
    fallback = cand;
  }
  if (fallback != null) {
    return PhraseGenResult(fallback, dedupRelaxed: true);
  }
  throw StateError('短句生成 $_maxAttempts 次尝试均不满足硬约束');
}

/// 变体谱表指派（见文件头裁决 7）。
List<Clef>? _assignClefs(List<int> seq, List<Clef> orig) {
  if (orig.length == seq.length) {
    var ok = true;
    for (var i = 0; i < seq.length; i++) {
      if (!canClef(seq[i], orig[i])) ok = false;
    }
    if (ok) return orig;
  }
  if (seq.every((i) => canClef(i, Clef.treble))) {
    return List.filled(seq.length, Clef.treble);
  }
  if (seq.every((i) => canClef(i, Clef.bass))) {
    return List.filled(seq.length, Clef.bass);
  }
  for (var k = 1; k < seq.length; k++) {
    if (seq[k] != 0) continue;
    for (final a in Clef.values) {
      final b = a == Clef.treble ? Clef.bass : Clef.treble;
      var ok = true;
      for (var i = 0; i < k && ok; i++) {
        ok = canClef(seq[i], a);
      }
      for (var i = k; i < seq.length && ok; i++) {
        ok = canClef(seq[i], b);
      }
      if (ok) {
        return [for (var i = 0; i < seq.length; i++) i < k ? a : b];
      }
    }
  }
  return null;
}

/// 答错变体（05 §6 / 02 §5.4）：保持音程序列，整体移调 ±2..4 自然音级
/// 或首音镜像；越界换移调方向；产物走同样约束校验。
PhraseGenResult wrongPhraseVariant(
  PhrasePayload original,
  Rng rng, {
  List<List<int>> recentSequences = const [],
  Config config = Config.defaults,
}) {
  final seq = original.noteSequence;
  final recent = _recentWindow(recentSequences, config.phraseDedupWindow);
  PhrasePayload? fallback;
  for (var attempt = 0; attempt < _maxAttempts; attempt++) {
    List<int> cand;
    if (rng.chance(0.5)) {
      final mag = rng.randInt(2, 4);
      final dir = rng.chance(0.5) ? 1 : -1;
      cand = seq.map((i) => i + dir * mag).toList();
      if (!cand.every(inPool)) {
        cand = seq.map((i) => i - dir * mag).toList();
        if (!cand.every(inPool)) continue;
      }
    } else {
      cand = seq.map((i) => 2 * seq.first - i).toList();
      if (!cand.every(inPool)) continue;
    }
    final clefs = _assignClefs(cand, original.clefSequence);
    if (clefs == null) continue;
    final p = PhrasePayload(noteSequence: cand, clefSequence: clefs);
    if (!_hardValid(p, config)) continue;
    if (!_isDup(cand, recent)) return PhraseGenResult(p);
    fallback = p;
  }
  if (fallback != null) {
    return PhraseGenResult(fallback, dedupRelaxed: true);
  }
  throw StateError('短句变体 $_maxAttempts 次尝试均不满足硬约束');
}