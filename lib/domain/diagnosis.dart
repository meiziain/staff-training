// 规格: 05 §8 诊断评分 / 02 §2.1 入门诊断 / 04 settings 种子（diag_* 阈值）。
// 裁决记录:
// 1) 块A rtMedian 对偶数条试次取中间两值平均（05 未指定口径）；空试次列表 acc=0、
//    rtMedian=null、pass=false。
// 2) C4 必入：即使块A未达标也补入（02 §2.1 "取全部达标者+C4"）；补入时置于列表末尾，
//    集合已满 4 个则挤掉 rtMedian 最慢者（05 §8）。
// 3) "锚点未全部自动化前实际执行阶段强制 0" 是运行时规则（session_engine 负责），
//    本模块仅输出 startStage 评分结果（05 §8）。
// 4) 块C 8 题按 相邻线间 3 / 跨谱表同音名 3 / 八度 2 分配；强制覆盖 C4 两种呈现对
//    与 C4/C5 八度对各至少一题，其余随机选题后整体洗牌。
// 5) SeedPair 允许 pairA==pairB（C4 跨谱表对两音位同为 0，sort 后相等）。
library;

import '../core/config.dart';
import '../core/rng.dart';
import 'models/enums.dart';
import 'models/note_position.dart';

/// 诊断试次轻量输入（契约缺口：models/Trial 为落库重模型，诊断评分仅需
/// correct/rtMs，在本文件内局部定义，不改动共享模型）。
class DiagTrial {
  final bool correct;
  final int rtMs;
  const DiagTrial({required this.correct, required this.rtMs});
}

/// 块A 单候选评分。
class AnchorBlockScore {
  final double acc;
  final double? rtMedian;
  final bool pass;
  const AnchorBlockScore({
    required this.acc,
    required this.rtMedian,
    required this.pass,
  });

  Map<String, dynamic> toJson() =>
      {'acc': acc, 'rtMedian': rtMedian, 'pass': pass};

  factory AnchorBlockScore.fromJson(Map<String, dynamic> j) =>
      AnchorBlockScore(
        acc: (j['acc'] as num).toDouble(),
        rtMedian: (j['rtMedian'] as num?)?.toDouble(),
        pass: j['pass'] as bool,
      );
}

/// 块B 策略探测评分。
class StrategyBlockScore {
  final double acc;
  final int hintRequests;
  const StrategyBlockScore({required this.acc, required this.hintRequests});

  Map<String, dynamic> toJson() => {'acc': acc, 'hintRequests': hintRequests};

  factory StrategyBlockScore.fromJson(Map<String, dynamic> j) =>
      StrategyBlockScore(
        acc: (j['acc'] as num).toDouble(),
        hintRequests: j['hintRequests'] as int,
      );
}

/// 混淆先验种子对（sort 后 pairA<=pairB，见文件头裁决 5）。
class SeedPair {
  final int pairA;
  final int pairB;
  const SeedPair._(this.pairA, this.pairB);

  factory SeedPair.sorted(int a, int b) =>
      a <= b ? SeedPair._(a, b) : SeedPair._(b, a);

  Map<String, dynamic> toJson() => {'pairA': pairA, 'pairB': pairB};

  factory SeedPair.fromJson(Map<String, dynamic> j) =>
      SeedPair._(j['pairA'] as int, j['pairB'] as int);

  @override
  bool operator ==(Object other) =>
      other is SeedPair && other.pairA == pairA && other.pairB == pairB;

  @override
  int get hashCode => Object.hash(pairA, pairB);
}

/// 块C 同异判断题：先后呈现两个音位（含各自谱表），判断是否同一音位。
/// same = 两呈现 diatonicIndex 相同（C4 两种呈现为"同"，八度对为"异"）。
class ConfusionProbe {
  final int indexA;
  final Clef clefA;
  final int indexB;
  final Clef clefB;
  const ConfusionProbe({
    required this.indexA,
    required this.clefA,
    required this.indexB,
    required this.clefB,
  });

  bool get same => indexA == indexB;

  Map<String, dynamic> toJson() => {
        'indexA': indexA,
        'clefA': clefA.wire,
        'indexB': indexB,
        'clefB': clefB.wire,
        'same': same,
      };
}

double? _median(List<int> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m].toDouble() : (s[m - 1] + s[m]) / 2;
}

double _acc(List<DiagTrial> trials) => trials.isEmpty
    ? 0
    : trials.where((t) => t.correct).length / trials.length;

/// 块A 单候选评分：pass = acc >= diagAnchorPassAcc（05 §8）。
AnchorBlockScore scoreAnchor(List<DiagTrial> trials, Config config) {
  final acc = _acc(trials);
  return AnchorBlockScore(
    acc: acc,
    rtMedian: _median(trials.map((t) => t.rtMs).toList()),
    pass: trials.isNotEmpty && acc >= config.diagAnchorPassAcc,
  );
}

/// 初始锚点集（05 §8 / 02 §2.1）：pass 者按 rtMedian 升序取前 4；
/// 不足 3 个则全取达标者；C4 必入（见文件头裁决 2）。
List<int> selectAnchors(Map<int, AnchorBlockScore> blockA, Config config) {
  final passed = blockA.entries.where((e) => e.value.pass).toList()
    ..sort((a, b) => (a.value.rtMedian ?? double.infinity)
        .compareTo(b.value.rtMedian ?? double.infinity));
  // 05 §8 "取前 4"：上限 4 为规格字面值，settings 无对应键。
  final anchors = passed.take(4).map((e) => e.key).toList();
  if (!anchors.contains(0)) {
    if (anchors.length >= 4) anchors.removeLast();
    anchors.add(0);
  }
  return anchors;
}

/// 块B 起始阶段（05 §8）：acc>=diagStrategyPassAcc 且
/// hintRequests<=diagStrategyMaxHints → 2，否则 1。
/// 运行时"锚点未全部自动化前强制阶段 0"由会话层执行，不在此处实现。
int strategyStartStage(double acc, int hintRequests, Config config) =>
    acc >= config.diagStrategyPassAcc &&
            hintRequests <= config.diagStrategyMaxHints
        ? 2
        : 1;

/// 块C 结构先验选题（02 §2.1：相邻线/间对、跨谱表同音名对（C4 两种呈现）、
/// 八度对（C4/C5）各若干）。题数 = config.diagConfusionTrials。
List<ConfusionProbe> buildConfusionProbes(Config config, Rng rng) {
  final n = config.diagConfusionTrials;
  assert(n >= 3, '块C 至少 3 题才能覆盖三类结构先验');
  final octaveCount = (n / 4).round().clamp(1, n - 2);
  final crossCount = (3 * n / 8).round().clamp(1, n - octaveCount - 1);
  final adjacentCount = n - octaveCount - crossCount;

  final adjacentPool = <ConfusionProbe>[];
  for (var i = poolMin; i < poolMax; i++) {
    final clef = i >= 0 ? Clef.treble : Clef.bass;
    adjacentPool
      ..add(ConfusionProbe(
          indexA: i, clefA: clef, indexB: i + 1, clefB: clef))
      ..add(ConfusionProbe(
          indexA: i + 1, clefA: clef, indexB: i, clefB: clef));
  }

  const t = Clef.treble;
  const b = Clef.bass;
  final c4Cross = [
    const ConfusionProbe(indexA: 0, clefA: t, indexB: 0, clefB: b),
    const ConfusionProbe(indexA: 0, clefA: b, indexB: 0, clefB: t),
  ];
  final crossPool = <ConfusionProbe>[
    ...c4Cross,
    const ConfusionProbe(indexA: 4, clefA: t, indexB: -3, clefB: b),
    const ConfusionProbe(indexA: -3, clefA: b, indexB: 4, clefB: t),
    const ConfusionProbe(indexA: 3, clefA: t, indexB: -4, clefB: b),
    const ConfusionProbe(indexA: -4, clefA: b, indexB: 3, clefB: t),
    const ConfusionProbe(indexA: 2, clefA: t, indexB: -5, clefB: b),
    const ConfusionProbe(indexA: -5, clefA: b, indexB: 2, clefB: t),
    const ConfusionProbe(indexA: 1, clefA: t, indexB: -6, clefB: b),
    const ConfusionProbe(indexA: -6, clefA: b, indexB: 1, clefB: t),
  ];
  final c4Octave = [
    const ConfusionProbe(indexA: 0, clefA: t, indexB: 7, clefB: t),
    const ConfusionProbe(indexA: 7, clefA: t, indexB: 0, clefB: t),
  ];
  final octavePool = <ConfusionProbe>[
    ...c4Octave,
    const ConfusionProbe(indexA: -7, clefA: b, indexB: 0, clefB: b),
    const ConfusionProbe(indexA: 0, clefA: b, indexB: -7, clefB: b),
  ];

  final probes = <ConfusionProbe>[
    rng.pick(c4Cross),
    for (var i = 1; i < crossCount; i++) rng.pick(crossPool),
    rng.pick(c4Octave),
    for (var i = 1; i < octaveCount; i++) rng.pick(octavePool),
    for (var i = 0; i < adjacentCount; i++) rng.pick(adjacentPool),
  ];
  for (var i = probes.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = probes[i];
    probes[i] = probes[j];
    probes[j] = tmp;
  }
  return probes;
}

/// 块C 作答 → 混淆种子：判断错误的题对写 seedPair（去重，保持首现顺序）。
List<SeedPair> seedsFromAnswers(
    List<ConfusionProbe> probes, List<bool> answers) {
  assert(probes.length == answers.length);
  final seeds = <SeedPair>[];
  for (var i = 0; i < probes.length; i++) {
    if (answers[i] != probes[i].same) {
      final p = SeedPair.sorted(probes[i].indexA, probes[i].indexB);
      if (!seeds.contains(p)) seeds.add(p);
    }
  }
  return seeds;
}

/// 诊断总输出（05 §8 diagnosis_result JSON）。
class DiagnosisResult {
  final List<int> anchors;
  final int startStage;
  final Map<int, AnchorBlockScore> blockA;
  final StrategyBlockScore? blockB;
  final List<SeedPair> seeds;

  const DiagnosisResult({
    required this.anchors,
    required this.startStage,
    required this.blockA,
    required this.blockB,
    this.seeds = const [],
  });

  /// 跳过诊断（05 §8 / 02 §2.1）：anchors=[C4,G4]，阶段 0。
  factory DiagnosisResult.skipped() => const DiagnosisResult(
        anchors: [0, 4],
        startStage: 0,
        blockA: {},
        blockB: null,
        seeds: [],
      );

  Map<String, dynamic> toJson() => {
        'anchors': anchors,
        'startStage': startStage,
        'blockA': {
          for (final e in blockA.entries) e.key.toString(): e.value.toJson(),
        },
        'blockB': blockB?.toJson(),
        'seeds': seeds.map((e) => e.toJson()).toList(),
      };

  factory DiagnosisResult.fromJson(Map<String, dynamic> j) => DiagnosisResult(
        anchors: (j['anchors'] as List).map((e) => e as int).toList(),
        startStage: j['startStage'] as int,
        blockA: {
          for (final e in (j['blockA'] as Map<String, dynamic>).entries)
            int.parse(e.key):
                AnchorBlockScore.fromJson(e.value as Map<String, dynamic>),
        },
        blockB: j['blockB'] == null
            ? null
            : StrategyBlockScore.fromJson(
                j['blockB'] as Map<String, dynamic>),
        seeds: (j['seeds'] as List? ?? [])
            .map((e) => SeedPair.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 诊断评分入口（05 §8）。blockATrials 按候选 diatonicIndex 组织，
/// 每候选 diagAnchorTrials 题；blockBTrials 共 diagStrategyTrials 题。
DiagnosisResult scoreDiagnosis({
  required Map<int, List<DiagTrial>> blockATrials,
  required List<DiagTrial> blockBTrials,
  required int hintRequests,
  List<SeedPair> seeds = const [],
  Config config = Config.defaults,
}) {
  final blockA = {
    for (final c in config.anchorCandidates)
      c: scoreAnchor(blockATrials[c] ?? const [], config),
  };
  final bAcc = _acc(blockBTrials);
  return DiagnosisResult(
    anchors: selectAnchors(blockA, config),
    startStage: strategyStartStage(bAcc, hintRequests, config),
    blockA: blockA,
    blockB: StrategyBlockScore(acc: bAcc, hintRequests: hintRequests),
    seeds: seeds,
  );
}