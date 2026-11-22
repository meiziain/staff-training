// 规格: 视奏训练改进 P0 / T03 —— 拍级判定结果（四色 + 双声部配对）。
// Δ = 输入时刻 - 拍 onset；负=早(early)、正=晚(late)。全链路不得反号。
library;

import 'sight_score.dart';

/// 单音判定档位。
enum SightHitGrade {
  onBeat,
  early,
  late,
  miss,
}

/// 单个声部在一拍内的判定明细。
class SightVoiceHit {
  /// 被判定的声部。
  final SightVoice voice;

  /// 该声部本拍待答音的音级（期望音）；无待答音时为 null。
  final int? diatonicIndex;

  /// 有符号时差（ms）；miss 为 null。
  final int? deltaMs;

  final SightHitGrade grade;

  const SightVoiceHit({
    required this.voice,
    this.diatonicIndex,
    this.deltaMs,
    required this.grade,
  });

  @override
  String toString() =>
      'SightVoiceHit($voice, idx=$diatonicIndex, Δ=$deltaMs, $grade)';
}

/// 一拍的聚合判定。
class SightBeatResult {
  /// 0-based 拍号（严格递增）。
  final int beatIndex;

  /// 本拍绝对 onset（Clock.monotonicMs 口径）。
  final int beatOnsetMonoMs;

  final List<SightVoiceHit> hits;

  /// 本拍处理完后整段是否完成。
  final bool finished;

  /// 是否为强制跳过（skipCurrentBeat）。
  final bool skipped;

  /// 内部配对窗校验结果：非共享光标档恒 true。
  final bool _pairWindowOk;

  const SightBeatResult({
    required this.beatIndex,
    required this.beatOnsetMonoMs,
    required this.hits,
    this.finished = false,
    this.skipped = false,
    bool pairWindowOk = true,
    // pairWindowOk 是公开参数、_pairWindowOk 是私有存储，无法用初始化形参。
    // ignore: prefer_initializing_formals
  }) : _pairWindowOk = pairWindowOk;

  /// 聚合档位：任一 miss → miss；否则任一 late → late；否则任一 early → early。
  SightHitGrade get grade {
    if (hits.any((h) => h.grade == SightHitGrade.miss)) return SightHitGrade.miss;
    if (hits.any((h) => h.grade == SightHitGrade.late)) return SightHitGrade.late;
    if (hits.any((h) => h.grade == SightHitGrade.early)) return SightHitGrade.early;
    return SightHitGrade.onBeat;
  }

  /// 双手同拍命中且时差在配对窗内才为 true。
  bool get paired {
    if (hits.length < 2) return false;
    if (!_pairWindowOk) return false;
    if (hits.any((h) => h.grade == SightHitGrade.miss)) return false;
    final voices = hits.map((h) => h.voice).toSet();
    return voices.contains(SightVoice.upper) &&
        voices.contains(SightVoice.lower);
  }

  @override
  String toString() =>
      'SightBeatResult(beat=$beatIndex, grade=${grade.name}, hits=$hits)';
}
