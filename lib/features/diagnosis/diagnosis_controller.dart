// 规格: 02 §2.1 入门诊断 / 05 §8 诊断评分 / 06 §1 §2（S0/S1/S1R）§5 时序常量。
// 纯状态机 + 注入时序（Delayer）/ 时钟（Clock）/ 随机源（Rng）/ 结果接收（DiagnosisSink）。
// 裁决记录:
// 1) 诊断无硬限时（02 §2.1 未给诊断限时；闪现限时仅属 S3 训练题型）。
// 2) 块B 锚点取候选中高音区（diatonicIndex ∈ (0,7]，默认 G4/C5），目标限高音谱表；
//    二度/三度各半（前 n~/2 题二度，其余三度），方向随机，整体洗牌。
// 3) 块A 候选 0（C4）固定高音谱表呈现；跨谱表混淆由块C 结构先验覆盖。
// 4) 块C 第二音呈现结束后进入作答（RT onset = 作答按钮可用帧），作答期保留第二音。
// 5) 中途退出 abort()：所有异步续段检查停止标志，不落半截状态、不调 sink。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/clock.dart';
import '../../core/config.dart';
import '../../core/rng.dart';
import '../../data/repositories/app_state_repo.dart';
import '../../domain/diagnosis.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/note_position.dart';

/// 延时接口：生产 Future.delayed，测试手动推进（FakeDelayer）。
abstract interface class Delayer {
  Future<void> delay(Duration d);
}

class RealDelayer implements Delayer {
  const RealDelayer();

  @override
  Future<void> delay(Duration d) => Future.delayed(d);
}

/// 诊断结果接收器（生产接 app_state 仓库，测试假实现）。
abstract interface class DiagnosisSink {
  Future<void> save(DiagnosisResult result);
}

/// 生产实现：写 app_state（04 种子键名与 JSON 口径）。
class AppStateDiagnosisSink implements DiagnosisSink {
  AppStateDiagnosisSink(this._db);

  final Database _db;

  @override
  Future<void> save(DiagnosisResult result) async {
    final repo = AppStateRepo(_db);
    await repo.set('diagnosis_result', jsonEncode(result.toJson()));
    await repo.set('active_anchors', jsonEncode(result.anchors));
    await repo.set('course_stage', '${result.startStage}');
    await repo.set('diagnosis_done', '1');
  }
}

enum DiagBlock { anchor, strategy, confusion }

/// idle=未开始；showing=块C 双音呈现中；presenting=刺激已呈现待 post-frame onset；
/// awaitingAnswer=可作答；blank=题间空屏；done/aborted=终态。
enum DiagPhase { idle, showing, presenting, awaitingAnswer, blank, done, aborted }

enum ConfusionStage { first, gap, second, answer }

class StrategyTrial {
  final int anchor;
  final int target;
  const StrategyTrial({required this.anchor, required this.target});

  int get steps => (target - anchor).abs();
  bool get upward => target > anchor;
}

class DiagnosisController extends ChangeNotifier {
  DiagnosisController({
    required this.config,
    required this.clock,
    required this.delayer,
    required this.sink,
    Rng? rng,
    int seed = 0,
  }) : _rng = rng ?? SeededRng(seed);

  final Config config;
  final Clock clock;
  final Delayer delayer;
  final DiagnosisSink sink;
  final Rng _rng;

  final Map<int, List<DiagTrial>> _blockA = {};
  final List<DiagTrial> _blockB = [];
  final List<bool> _cAnswers = [];
  late final List<int> _aOrder;
  late final List<StrategyTrial> _bTrials;
  late final List<ConfusionProbe> _probes;
  bool _prepared = false;
  bool _aborted = false;
  bool _disposed = false;
  int? _onset;

  DiagBlock block = DiagBlock.anchor;
  DiagPhase phase = DiagPhase.idle;

  /// 块内已完成题数（blank 期已递增）。
  int trialIndex = 0;

  /// 块A/B 作答目标音位；blank 期为 null（不提前显示下一题）。
  int? currentNote;

  /// 块B 常亮锚点音位。
  int? anchorIndex;
  Clef clef = Clef.treble;
  int jitterSeed = 0;

  /// 块C 当前题与呈现阶段。
  ConfusionProbe? probe;
  ConfusionStage confusionStage = ConfusionStage.first;

  /// 块B 当前题提示层级（0 无 / 1 方向箭头 / 2 距离标尺）。
  int hintLevel = 0;

  /// 块B 累计请求提示次数。
  int hintRequests = 0;

  DiagnosisResult? result;

  bool get _stopped => _aborted || _disposed;

  bool get needsOnset => phase == DiagPhase.presenting;
  bool get answerEnabled => phase == DiagPhase.awaitingAnswer;

  int get blockTotal => switch (block) {
        DiagBlock.anchor =>
          config.anchorCandidates.length * config.diagAnchorTrials,
        DiagBlock.strategy => config.diagStrategyTrials,
        DiagBlock.confusion => config.diagConfusionTrials,
      };

  int get displayIndex =>
      (phase == DiagPhase.blank ? trialIndex : trialIndex + 1)
          .clamp(1, blockTotal);

  String get blockLabel => switch (block) {
        DiagBlock.anchor => '锚点再认',
        DiagBlock.strategy => '推导策略',
        DiagBlock.confusion => '混淆探测',
      };

  /// 块B 当前题（提示渲染用）；非块B 或空屏期 null。
  StrategyTrial? get strategyTrial =>
      block == DiagBlock.strategy && currentNote != null && anchorIndex != null
          ? StrategyTrial(anchor: anchorIndex!, target: currentNote!)
          : null;

  void _prepare() {
    if (_prepared) return;
    _prepared = true;
    for (final c in config.anchorCandidates) {
      _blockA[c] = [];
    }
    _aOrder = [
      for (final c in config.anchorCandidates)
        for (var i = 0; i < config.diagAnchorTrials; i++) c,
    ];
    _shuffle(_aOrder);

    var anchorPool =
        config.anchorCandidates.where((c) => c > 0 && c <= 7).toList();
    if (anchorPool.isEmpty) {
      anchorPool = config.anchorCandidates.where((c) => c >= 0).toList();
    }
    if (anchorPool.isEmpty) anchorPool = [4];
    final n = config.diagStrategyTrials;
    _bTrials = [];
    for (var i = 0; i < n; i++) {
      final step = i < n ~/ 2 ? 1 : 2;
      final a = _rng.pick(anchorPool);
      var dir = _rng.chance(0.5) ? 1 : -1;
      if (!inTrebleRange(a + dir * step)) dir = -dir;
      _bTrials.add(StrategyTrial(anchor: a, target: a + dir * step));
    }
    _shuffle(_bTrials);

    _probes = buildConfusionProbes(config, _rng);
  }

  void _shuffle<T>(List<T> xs) {
    for (var i = xs.length - 1; i > 0; i--) {
      final j = _rng.nextInt(i + 1);
      final tmp = xs[i];
      xs[i] = xs[j];
      xs[j] = tmp;
    }
  }

  /// S0 → S1：开始块A。
  void start() {
    if (phase != DiagPhase.idle || _stopped) return;
    _prepare();
    block = DiagBlock.anchor;
    trialIndex = 0;
    _beginTrial();
  }

  /// S0 跳过：默认配置（anchors=[0,4]，阶段 0）直接落 sink。
  Future<void> skip() async {
    if (phase != DiagPhase.idle || _stopped) return;
    final r = DiagnosisResult.skipped();
    result = r;
    phase = DiagPhase.done;
    notifyListeners();
    await sink.save(r);
  }

  /// 中途退出：诊断作废（06 §2 S1），不落半截状态。
  void abort() {
    if (_stopped || phase == DiagPhase.done || phase == DiagPhase.idle) return;
    _aborted = true;
    phase = DiagPhase.aborted;
    notifyListeners();
  }

  /// post-frame onset（03 §2 / 05 §9）：由页面在呈现帧后调用。
  void markOnset() {
    if (phase != DiagPhase.presenting || _stopped) return;
    _onset = clock.monotonicMs();
    phase = DiagPhase.awaitingAnswer;
    notifyListeners();
  }

  void _beginTrial() {
    _onset = null;
    hintLevel = 0;
    jitterSeed = _rng.nextInt(1 << 30);
    switch (block) {
      case DiagBlock.anchor:
        currentNote = _aOrder[trialIndex];
        anchorIndex = null;
        clef = canClef(currentNote!, Clef.treble) ? Clef.treble : Clef.bass;
        phase = DiagPhase.presenting;
        notifyListeners();
      case DiagBlock.strategy:
        final t = _bTrials[trialIndex];
        anchorIndex = t.anchor;
        currentNote = t.target;
        clef = Clef.treble;
        phase = DiagPhase.presenting;
        notifyListeners();
      case DiagBlock.confusion:
        unawaited(_runConfusion());
    }
  }

  /// 块C 时序：两音各 1000ms，间隔 500ms（06 §5）。
  Future<void> _runConfusion() async {
    probe = _probes[trialIndex];
    confusionStage = ConfusionStage.first;
    phase = DiagPhase.showing;
    notifyListeners();
    await delayer.delay(const Duration(milliseconds: 1000));
    if (_stopped) return;
    confusionStage = ConfusionStage.gap;
    notifyListeners();
    await delayer.delay(const Duration(milliseconds: 500));
    if (_stopped) return;
    confusionStage = ConfusionStage.second;
    notifyListeners();
    await delayer.delay(const Duration(milliseconds: 1000));
    if (_stopped) return;
    confusionStage = ConfusionStage.answer;
    phase = DiagPhase.presenting;
    notifyListeners();
  }

  /// 块A/B 音名作答：无对错反馈、无声音（02 §2.1）。
  void answerName(String pitchClass) {
    if (phase != DiagPhase.awaitingAnswer ||
        block == DiagBlock.confusion ||
        _stopped) {
      return;
    }
    final now = clock.monotonicMs();
    final rt = now - (_onset ?? now);
    final target = currentNote!;
    final trial =
        DiagTrial(correct: pitchClass == pitchClassOf(target), rtMs: rt);
    if (block == DiagBlock.anchor) {
      _blockA[target]!.add(trial);
    } else {
      _blockB.add(trial);
    }
    unawaited(_afterAnswer());
  }

  /// 块B 请求提示：方向箭头 → 距离标尺两级，记录次数。
  void requestHint() {
    if (block != DiagBlock.strategy ||
        phase != DiagPhase.awaitingAnswer ||
        hintLevel >= 2 ||
        _stopped) {
      return;
    }
    hintLevel++;
    hintRequests++;
    notifyListeners();
  }

  /// 块C 同异作答。
  void answerSame(bool same) {
    if (phase != DiagPhase.awaitingAnswer ||
        block != DiagBlock.confusion ||
        _stopped) {
      return;
    }
    _cAnswers.add(same);
    unawaited(_afterAnswer());
  }

  Future<void> _afterAnswer() async {
    phase = DiagPhase.blank;
    currentNote = null;
    anchorIndex = null;
    probe = null;
    trialIndex++;
    notifyListeners();
    await delayer.delay(Duration(milliseconds: config.interTrialBlankMs));
    if (_stopped) return;
    if (trialIndex < blockTotal) {
      _beginTrial();
      return;
    }
    switch (block) {
      case DiagBlock.anchor:
        block = DiagBlock.strategy;
        trialIndex = 0;
        _beginTrial();
      case DiagBlock.strategy:
        block = DiagBlock.confusion;
        trialIndex = 0;
        _beginTrial();
      case DiagBlock.confusion:
        await _finish();
    }
  }

  Future<void> _finish() async {
    final seeds = seedsFromAnswers(_probes, _cAnswers);
    final r = scoreDiagnosis(
      blockATrials: _blockA,
      blockBTrials: _blockB,
      hintRequests: hintRequests,
      seeds: seeds,
      config: config,
    );
    result = r;
    phase = DiagPhase.done;
    notifyListeners();
    await sink.save(r);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}