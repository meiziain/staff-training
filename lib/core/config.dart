// 规格: 02 §8.6 / 03 §2 规则3 —— 全部阈值来自 settings 表，启动加载为不可变 Config。
// 字段与 04-数据库设计.sql settings 种子一一对应；默认值即 04 种子值。
library;

/// 作答模式（02 §1.3）。piano = 蓝牙电钢琴 MIDI 输入（含八度）。
enum InputMode {
  nameButtons,
  virtualKey,
  piano;

  /// 是否携带八度（音名按钮模式不考察八度）。
  bool get includesOctave => this != InputMode.nameButtons;
}

/// 不可变配置对象。domain 层只读。
class Config {
  // 锚点自动化（F1）
  final double anchorAutoAcc;
  final int anchorAutoRtMs;
  final int anchorAutoWindow;
  // 直认自动化（F3）
  final double directAutoAcc;
  final int directAutoRtMs;
  final int directAutoWindow;
  // 直认晋升/回退（F3）
  final int promoteStreak;
  final int promoteRtMs;
  final int promoteRtLedgerMs;
  final int relapseDirectStreak;
  // 提示（F2）
  final int hintInitialLevel;
  final int microLessonLevel;
  final int hintDowngradeStreak;
  final int hintDowngradeRtMs;
  final double hintDepStableMax;
  final List<double> hintDepWeights; // 级1..5
  // 调度（F5）
  final List<int> intervalLadderDays;
  final double easeInit;
  final double easeMin;
  final double easeMax;
  final int stableMinIntervalDays;
  final int stableStreak;
  final int dedupGap;
  final int lapseReexposeMin;
  final int lapseReexposeMax;
  final double mixReview;
  final double mixNew;
  final double mixDirect;
  final double mixPhrase;
  final int maxSameTypeRun;
  final double stageAdvanceRatio;
  // 限时
  final int flashLimitAnchorMs;
  final int flashLimitAnchorMinMs;
  final int flashLimitDirectMs;
  final int flashLimitDirectMinMs;
  final int slowCorrectRtMs;

  /// 键盘模式找音宽限：倒计时等首触启动的上限（02 §8.6 未区分输入模式的补充裁决）。
  final int keyLimitGraceMs;
  // 短句（F4）
  final int phraseLenStage4;
  final int phraseLenStage5Min;
  final int phraseLenStage5Max;
  final double phraseStepMinRatio;
  final int phraseMaxLeapSteps;
  final int phraseDedupWindow;
  final double wrongPhraseThreshold;
  final int phrasePlayIntervalMs;
  final int wrongAnswerGapMs;
  // 诊断（F1）
  final int diagAnchorTrials;
  final double diagAnchorPassAcc;
  final int diagStrategyTrials;
  final double diagStrategyPassAcc;
  final int diagStrategyMaxHints;
  final int diagConfusionTrials;
  final List<int> anchorCandidates; // diatonicIndex: C4,G4,F3,C5,C3
  // 会话
  final int sessionDefaultCount;
  final int warmupCount;
  final int interTrialBlankMs;
  final int anchorPreludeMs;
  final int microLessonAnchorMs;
  // 用户偏好
  final InputMode inputMode;
  final bool audioEnabled;
  final bool relaxedTiming;
  final int dailyCount;

  const Config({
    this.anchorAutoAcc = 0.95,
    this.anchorAutoRtMs = 1200,
    this.anchorAutoWindow = 20,
    this.directAutoAcc = 0.95,
    this.directAutoRtMs = 1500,
    this.directAutoWindow = 20,
    this.promoteStreak = 5,
    this.promoteRtMs = 2000,
    this.promoteRtLedgerMs = 2500,
    this.relapseDirectStreak = 3,
    this.hintInitialLevel = 3,
    this.microLessonLevel = 5,
    this.hintDowngradeStreak = 3,
    this.hintDowngradeRtMs = 2000,
    this.hintDepStableMax = 0.3,
    this.hintDepWeights = const [0.2, 0.4, 0.6, 0.8, 1.0],
    this.intervalLadderDays = const [0, 1, 3, 7, 14, 30],
    this.easeInit = 2.5,
    this.easeMin = 1.3,
    this.easeMax = 2.8,
    this.stableMinIntervalDays = 7,
    this.stableStreak = 5,
    this.dedupGap = 4,
    this.lapseReexposeMin = 2,
    this.lapseReexposeMax = 4,
    this.mixReview = 0.4,
    this.mixNew = 0.2,
    this.mixDirect = 0.2,
    this.mixPhrase = 0.2,
    this.maxSameTypeRun = 2,
    this.stageAdvanceRatio = 0.8,
    this.flashLimitAnchorMs = 3000,
    this.flashLimitAnchorMinMs = 1500,
    this.flashLimitDirectMs = 2500,
    this.flashLimitDirectMinMs = 1200,
    this.slowCorrectRtMs = 4000,
    this.keyLimitGraceMs = 5000,
    this.phraseLenStage4 = 3,
    this.phraseLenStage5Min = 4,
    this.phraseLenStage5Max = 5,
    this.phraseStepMinRatio = 0.6,
    this.phraseMaxLeapSteps = 3,
    this.phraseDedupWindow = 20,
    this.wrongPhraseThreshold = 0.4,
    this.phrasePlayIntervalMs = 500,
    this.wrongAnswerGapMs = 400,
    this.diagAnchorTrials = 6,
    this.diagAnchorPassAcc = 0.8,
    this.diagStrategyTrials = 6,
    this.diagStrategyPassAcc = 0.8,
    this.diagStrategyMaxHints = 1,
    this.diagConfusionTrials = 8,
    this.anchorCandidates = const [0, 4, -4, 7, -7],
    this.sessionDefaultCount = 40,
    this.warmupCount = 8,
    this.interTrialBlankMs = 800,
    this.anchorPreludeMs = 1000,
    this.microLessonAnchorMs = 1500,
    this.inputMode = InputMode.nameButtons,
    this.audioEnabled = true,
    this.relaxedTiming = false,
    this.dailyCount = 40,
  });

  /// 04 settings 种子默认值。
  static const Config defaults = Config();

  /// 限时宽松模式：所有时限 ×1.5（02 §7.3）。
  int limitMs(int baseMs) =>
      relaxedTiming ? (baseMs * 1.5).round() : baseMs;

  static double _d(Map<String, String> s, String k, double def) =>
      double.tryParse(s[k] ?? '') ?? def;
  static int _i(Map<String, String> s, String k, int def) =>
      int.tryParse(s[k] ?? '') ?? def;
  static List<int> _il(Map<String, String> s, String k, List<int> def) {
    final v = s[k];
    if (v == null || v.isEmpty) return def;
    return v.split(',').map((e) => int.parse(e.trim())).toList();
  }

  static List<double> _dl(Map<String, String> s, String k, List<double> def) {
    final v = s[k];
    if (v == null || v.isEmpty) return def;
    return v.split(',').map((e) => double.parse(e.trim())).toList();
  }

  /// 从 settings 表键值加载（缺失键回退默认值）。
  factory Config.fromSettings(Map<String, String> s) {
    const d = defaults;
    return Config(
      anchorAutoAcc: _d(s, 'anchor_auto_acc', d.anchorAutoAcc),
      anchorAutoRtMs: _i(s, 'anchor_auto_rt_ms', d.anchorAutoRtMs),
      anchorAutoWindow: _i(s, 'anchor_auto_window', d.anchorAutoWindow),
      directAutoAcc: _d(s, 'direct_auto_acc', d.directAutoAcc),
      directAutoRtMs: _i(s, 'direct_auto_rt_ms', d.directAutoRtMs),
      directAutoWindow: _i(s, 'direct_auto_window', d.directAutoWindow),
      promoteStreak: _i(s, 'promote_streak', d.promoteStreak),
      promoteRtMs: _i(s, 'promote_rt_ms', d.promoteRtMs),
      promoteRtLedgerMs: _i(s, 'promote_rt_ledger_ms', d.promoteRtLedgerMs),
      relapseDirectStreak:
          _i(s, 'relapse_direct_streak', d.relapseDirectStreak),
      hintInitialLevel: _i(s, 'hint_initial_level', d.hintInitialLevel),
      microLessonLevel: _i(s, 'micro_lesson_level', d.microLessonLevel),
      hintDowngradeStreak:
          _i(s, 'hint_downgrade_streak', d.hintDowngradeStreak),
      hintDowngradeRtMs: _i(s, 'hint_downgrade_rt_ms', d.hintDowngradeRtMs),
      hintDepStableMax: _d(s, 'hint_dep_stable_max', d.hintDepStableMax),
      hintDepWeights: _dl(s, 'hint_dep_weights', d.hintDepWeights),
      intervalLadderDays:
          _il(s, 'interval_ladder_days', d.intervalLadderDays),
      easeInit: _d(s, 'ease_init', d.easeInit),
      easeMin: _d(s, 'ease_min', d.easeMin),
      easeMax: _d(s, 'ease_max', d.easeMax),
      stableMinIntervalDays:
          _i(s, 'stable_min_interval_days', d.stableMinIntervalDays),
      stableStreak: _i(s, 'stable_streak', d.stableStreak),
      dedupGap: _i(s, 'dedup_gap', d.dedupGap),
      lapseReexposeMin: _i(s, 'lapse_reexpose_min', d.lapseReexposeMin),
      lapseReexposeMax: _i(s, 'lapse_reexpose_max', d.lapseReexposeMax),
      mixReview: _d(s, 'mix_review', d.mixReview),
      mixNew: _d(s, 'mix_new', d.mixNew),
      mixDirect: _d(s, 'mix_direct', d.mixDirect),
      mixPhrase: _d(s, 'mix_phrase', d.mixPhrase),
      maxSameTypeRun: _i(s, 'max_same_type_run', d.maxSameTypeRun),
      stageAdvanceRatio: _d(s, 'stage_advance_ratio', d.stageAdvanceRatio),
      flashLimitAnchorMs:
          _i(s, 'flash_limit_anchor_ms', d.flashLimitAnchorMs),
      flashLimitAnchorMinMs:
          _i(s, 'flash_limit_anchor_min_ms', d.flashLimitAnchorMinMs),
      flashLimitDirectMs:
          _i(s, 'flash_limit_direct_ms', d.flashLimitDirectMs),
      flashLimitDirectMinMs:
          _i(s, 'flash_limit_direct_min_ms', d.flashLimitDirectMinMs),
      slowCorrectRtMs: _i(s, 'slow_correct_rt_ms', d.slowCorrectRtMs),
      keyLimitGraceMs: _i(s, 'key_limit_grace_ms', d.keyLimitGraceMs),
      phraseLenStage4: _i(s, 'phrase_len_stage4', d.phraseLenStage4),
      phraseLenStage5Min:
          _i(s, 'phrase_len_stage5_min', d.phraseLenStage5Min),
      phraseLenStage5Max:
          _i(s, 'phrase_len_stage5_max', d.phraseLenStage5Max),
      phraseStepMinRatio:
          _d(s, 'phrase_step_min_ratio', d.phraseStepMinRatio),
      phraseMaxLeapSteps:
          _i(s, 'phrase_max_leap_steps', d.phraseMaxLeapSteps),
      phraseDedupWindow: _i(s, 'phrase_dedup_window', d.phraseDedupWindow),
      wrongPhraseThreshold:
          _d(s, 'wrong_phrase_threshold', d.wrongPhraseThreshold),
      phrasePlayIntervalMs:
          _i(s, 'phrase_play_interval_ms', d.phrasePlayIntervalMs),
      wrongAnswerGapMs: _i(s, 'wrong_answer_gap_ms', d.wrongAnswerGapMs),
      diagAnchorTrials: _i(s, 'diag_anchor_trials', d.diagAnchorTrials),
      diagAnchorPassAcc: _d(s, 'diag_anchor_pass_acc', d.diagAnchorPassAcc),
      diagStrategyTrials:
          _i(s, 'diag_strategy_trials', d.diagStrategyTrials),
      diagStrategyPassAcc:
          _d(s, 'diag_strategy_pass_acc', d.diagStrategyPassAcc),
      diagStrategyMaxHints:
          _i(s, 'diag_strategy_max_hints', d.diagStrategyMaxHints),
      diagConfusionTrials:
          _i(s, 'diag_confusion_trials', d.diagConfusionTrials),
      anchorCandidates: _il(s, 'anchor_candidates', d.anchorCandidates),
      sessionDefaultCount:
          _i(s, 'session_default_count', d.sessionDefaultCount),
      warmupCount: _i(s, 'warmup_count', d.warmupCount),
      interTrialBlankMs: _i(s, 'inter_trial_blank_ms', d.interTrialBlankMs),
      anchorPreludeMs: _i(s, 'anchor_prelude_ms', d.anchorPreludeMs),
      microLessonAnchorMs:
          _i(s, 'micro_lesson_anchor_ms', d.microLessonAnchorMs),
      inputMode: switch (s['input_mode']) {
        'virtual_key' => InputMode.virtualKey,
        'piano' => InputMode.piano,
        _ => InputMode.nameButtons,
      },
      audioEnabled: (s['audio_enabled'] ?? '1') == '1',
      relaxedTiming: (s['relaxed_timing'] ?? '0') == '1',
      dailyCount: _i(s, 'daily_count', d.dailyCount),
    );
  }
}