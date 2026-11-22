// 规格: 06 §2 S2（首页）/ 02 §6.4 §7.4。今日会话卡片 + 开始练习 + 掌握地图/设置入口。
// 阶段进度卡：展示解锁条件与达标进度（02 §2.2 三条件 / §3.1 阶段表）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/rng.dart';
import '../../data/repositories/app_state_repo.dart';
import '../../data/repositories/mastery_repo.dart';
import '../../data/session_service.dart';
import '../../domain/course.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/item.dart';
import '../../domain/models/mastery.dart';
import '../../domain/models/note_position.dart';
import '../../domain/stage_progress.dart';
import '../progress/mastery_map_page.dart';
import '../session/session_page.dart';
import '../settings/settings_page.dart';
import '../sight/sight_mode_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomeData {
  final int stage;
  final int dueCount;
  final int newLearn;
  final int automatedDirect;
  final int todayDone;
  final int streak;
  final List<AnchorAutomationProgress> anchorProgress;
  final StageCoreProgress coreProgress;
  final List<CoreItemStableProgress> coreItems;
  const _HomeData(this.stage, this.dueCount, this.newLearn,
      this.automatedDirect, this.todayDone, this.streak,
      this.anchorProgress, this.coreProgress, this.coreItems);
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _building = false;

  Future<_HomeData> _load() async {
    final db = await ref.read(databaseProvider.future);
    final clock = ref.read(clockProvider);
    final appState = AppStateRepo(db);
    final stage = int.tryParse(await appState.get('course_stage') ?? '') ?? 0;
    final endOfDay = clock.localEndOfDayUtcMs(clock.localDate());
    final due = await MasteryRepo(db).dueBefore(endOfDay);
    final dueCount = due
        .where((m) =>
            m.state == ItemState.learning ||
            m.state == ItemState.reviewing ||
            m.state == ItemState.automated)
        .length;
    // 直认自动化数：DIRECT 条目需联查 item 类型。
    final directAutomated = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM mastery m JOIN item i ON m.item_id=i.id "
        "WHERE i.type='DIRECT' AND m.state='automated'");
    final automatedDirect = (directAutomated.first['c'] as int?) ?? 0;
    // 今日新学：learning 且未作答过（reps=0）的关系条目（06 §2 S2「新学 N」）。
    final newLearnRows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM mastery m JOIN item i ON m.item_id=i.id "
        "WHERE i.type='RELATION' AND m.state='learning' AND m.reps=0");
    final newLearn = (newLearnRows.first['c'] as int?) ?? 0;
    final sessions = await db.query('session', orderBy: 'date DESC');
    final today = _dateStr(clock.localDate());
    final todayDone = sessions
        .where((s) => s['date'] == today)
        .fold<int>(0, (s, r) => s + (r['done_count'] as int));
    // 连续练习天数（含今天或昨天起算）。
    final dates = sessions.map((s) => s['date'] as String).toSet();
    var streak = 0;
    var d = clock.localDate();
    if (!dates.contains(_dateStr(d))) {
      d = d.subtract(const Duration(days: 1));
    }
    while (dates.contains(_dateStr(d))) {
      streak++;
      d = d.subtract(const Duration(days: 1));
    }
    // ---- 阶段进度（解锁条件 + 达标进度）。
    final config = await ref.read(configProvider.future);
    final source = await DbSessionDataSource.load(db);
    final anchorsRaw = await appState.get('active_anchors');
    final parsedAnchors = <int>{
      for (final e in jsonDecode(anchorsRaw ?? '[]') as List) e as int,
    };
    // 与 SessionSetup 同口径：无锚点按跳过诊断默认 [C4,G4]。
    final activeAnchors = parsedAnchors.isEmpty ? {0, 4} : parsedAnchors;
    final masteries = {
      for (final it in source.items) it.id: source.masteryOf(it.id),
    };
    final coreProgress = StageCoreProgress.of(
      stage: stage,
      items: source.items,
      masteries: masteries,
      activeAnchors: activeAnchors,
      config: config,
    );
    final anchorProgress = <AnchorAutomationProgress>[];
    if (stage == 0) {
      for (final a in activeAnchors.toList()..sort()) {
        Item? anchorItem;
        for (final it in source.items) {
          if (it.type == ItemType.anchor &&
              (it.payload as AnchorPayload).diatonicIndex == a) {
            anchorItem = it;
            break;
          }
        }
        anchorProgress.add(AnchorAutomationProgress.of(
          diatonicIndex: a,
          mastery: anchorItem == null
              ? Mastery(itemId: 0)
              : source.masteryOf(anchorItem.id),
          history: anchorItem == null
              ? const []
              : source.recentResults(anchorItem.id, config.anchorAutoWindow),
          config: config,
        ));
      }
    }
    // 阶段1–4：逐核心条目的稳定条件进度（未稳定在前，已稳定在后）。
    final coreItems = <CoreItemStableProgress>[];
    if (stage >= 1 && stage <= 4) {
      for (final it in coreItemsOf(stage, source.items, activeAnchors)) {
        coreItems.add(CoreItemStableProgress.of(
          item: it,
          mastery: source.masteryOf(it.id),
          config: config,
        ));
      }
      coreItems.sort((a, b) {
        final c = (a.stable ? 1 : 0).compareTo(b.stable ? 1 : 0);
        return c != 0 ? c : a.label.compareTo(b.label);
      });
    }
    return _HomeData(stage, dueCount, newLearn, automatedDirect, todayDone,
        streak, anchorProgress, coreProgress, coreItems);
  }

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _startSession(Config config,
      {int? dailyCount, bool extraPractice = false}) async {
    setState(() => _building = true);
    try {
      final db = await ref.read(databaseProvider.future);
      final clock = ref.read(clockProvider);
      final bundle = await SessionSetup.build(
        db: db,
        config: config,
        clock: clock,
        rng: rng(clock.nowUtcMs() & 0x7fffffff),
        dailyCount: dailyCount,
        extraPractice: extraPractice,
      );      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SessionPage(bundle: bundle),
      ));
      if (mounted) setState(() {}); // 刷新计数
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    final configAsync = ref.watch(configProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('识谱训练'),
        actions: [
          IconButton(
            key: const Key('settings_entry'),
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库错误：$e')),
        data: (db) => configAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('配置错误：$e')),
          data: (config) => FutureBuilder<_HomeData>(
            future: _load(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final d = snap.data!;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('连续练习 ${d.streak} 天 · 阶段 ${d.stage}',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('今日会话',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text('${config.dailyCount} 题 · 约 12 分钟'),
                          Text(d.dueCount > 0
                              ? '到期复习 ${d.dueCount} · 新学 ${d.newLearn}'
                              : '今天没有到期复习，学点新的'),
                          if (d.todayDone > 0)
                            Text('今日已练 ${d.todayDone} 题'),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              key: const Key('start_session'),
                              onPressed: _building
                                  ? null
                                  : () => _startSession(config,
                                      dailyCount:
                                          d.todayDone > 0 ? 20 : null,
                                      // 今日已练过 → 「再练一组」按加练口径：
                                      // 未到期条目也参与（02 §6.4 练得太勤给新内容）。
                                      extraPractice: d.todayDone > 0),
                              child: _building
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : Text(d.todayDone > 0
                                      ? '再练一组（20 题）'
                                      : '开始练习'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StageProgressCard(
                    stage: d.stage,
                    anchors: d.anchorProgress,
                    core: d.coreProgress,
                    coreItems: d.coreItems,
                    config: config,
                  ),
                  const SizedBox(height: 16),
                  Text('直认自动化 ${d.automatedDirect}/22'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                      value: d.automatedDirect / 22),
                  const SizedBox(height: 16),
                  // 视奏训练入口（11 §6.1）：独立练习场，不进今日会话与排程。
                  Card(
                    key: const Key('sight_mode_entry'),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SightModePage()),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('视奏训练',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 4),
                                  const Text('无倒计时 · 点一个音走一步'),
                                  if (d.stage < 2)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        '建议先练熟更多音位再视奏',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                                color: Theme.of(context)
                                                    .hintColor),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    key: const Key('mastery_map_entry'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const MasteryMapPage()),
                    ),
                    child: const Text('掌握地图'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 阶段进度卡：当前阶段解锁条件 + 达标进度。
/// 阶段0 逐锚点展示自动化三条件；阶段1–4 展示核心条目稳定比例；阶段5 已到顶。
class _StageProgressCard extends StatelessWidget {
  final int stage;
  final List<AnchorAutomationProgress> anchors;
  final StageCoreProgress core;
  final List<CoreItemStableProgress> coreItems;
  final Config config;

  const _StageProgressCard({
    required this.stage,
    required this.anchors,
    required this.core,
    required this.coreItems,
    required this.config,
  });

  static const _stageNames = [
    '锚点建立',
    '锚点±二度',
    '锚点±三度',
    '两步推导 · 低音谱表',
    '短句阅读',
    '跨谱表短句',
  ];

  String get _unlockText {
    final pct = (core.requiredRatio * 100).round();
    return switch (stage) {
      0 => '全部锚点自动化后，解锁阶段 1：锚点±二度推导',
      1 => '二度关系条目稳定率 ≥$pct% 后，解锁阶段 2：锚点±三度',
      2 => '三度关系条目稳定率 ≥$pct% 后，解锁阶段 3：两步推导 + 低音谱表',
      3 => '关系条目稳定率 ≥$pct% 后，解锁阶段 4：短句阅读',
      4 => '短句稳定率 ≥$pct% 后，解锁阶段 5：跨谱表短句',
      _ => '已是最高阶段，继续巩固短句阅读',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('stage_progress_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('阶段 $stage · ${_stageNames[stage]}',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_unlockText, style: theme.textTheme.bodySmall),
            Text('推进按达标判定，与练习天数无关',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
            if (stage == 0) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  _Legend(icon: Icons.track_changes, text: '正确率'),
                  SizedBox(width: 12),
                  _Legend(icon: Icons.bolt, text: '反应'),
                  SizedBox(width: 12),
                  _Legend(icon: Icons.lightbulb_outline, text: '提示'),
                  Spacer(),
                  _Legend(icon: Icons.touch_app, text: '点按看明细'),
                ],
              ),
              for (final p in anchors) _AnchorProgress(p: p),
              if (core.met)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('全部锚点已自动化，完成会话后进入下一阶段',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.green.shade700)),
                ),
            ] else if (stage < 5) ...[
              const SizedBox(height: 12),
              Text(
                  '稳定条目 ${core.okCount}/${core.coreCount}'
                  '（需 ≥${(core.requiredRatio * 100).round()}%）',
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: core.ratio),
              const SizedBox(height: 4),
              Text(
                  '稳定 = 复习间隔 ≥${config.stableMinIntervalDays} 天、'
                  '低提示依赖、最近 ${config.stableStreak} 次全对',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
              if (coreItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Row(
                  children: [
                    _Legend(icon: Icons.calendar_today, text: '间隔'),
                    SizedBox(width: 12),
                    _Legend(icon: Icons.lightbulb_outline, text: '提示'),
                    SizedBox(width: 12),
                    _Legend(icon: Icons.repeat, text: '连对'),
                    Spacer(),
                    _Legend(icon: Icons.touch_app, text: '点按看明细'),
                  ],
                ),
                for (final p in coreItems) _CoreItemProgress(p: p),
              ],
              if (core.met)
                Text('已达标，完成会话后进入下一阶段',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.green.shade700)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单锚点一行：音名 + 三条件状态徽章 + 窗口进度圆环；点按展开数值明细。
class _AnchorProgress extends StatefulWidget {
  final AnchorAutomationProgress p;
  const _AnchorProgress({required this.p});

  @override
  State<_AnchorProgress> createState() => _AnchorProgressState();
}

class _AnchorProgressState extends State<_AnchorProgress> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.p;
    final name = NotePosition.of(p.diatonicIndex).displayName;
    final acc = p.accuracy;
    final rt = p.rtMedianMs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('anchor_row_$name'),
          onTap: p.automated
              ? null
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(name, style: theme.textTheme.titleSmall),
                ),
                if (p.automated)
                  Expanded(
                    child: Text('已自动化',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.green.shade700)),
                  )
                else ...[
                  _StatusChip(
                    ok: p.accOk,
                    icon: Icons.track_changes,
                    label: acc == null ? '—' : '${(acc * 100).round()}%',
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(
                    ok: p.rtOk,
                    icon: Icons.bolt,
                    label: rt == null
                        ? '—'
                        : '${(rt / 1000).toStringAsFixed(1)}s',
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(
                    ok: p.hintOk,
                    icon: Icons.lightbulb_outline,
                    label: '${p.hintCount}次',
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.hintColor,
                  ),
                ],
                const SizedBox(width: 8),
                _WindowRing(p: p),
              ],
            ),
          ),
        ),
        if (_expanded && !p.automated)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: p.windowCount / p.window),
                const SizedBox(height: 4),
                Text(
                    '判定窗口 ${p.windowCount}/${p.window} 题 · '
                    '取最近 ${p.window} 次作答，加练也计入',
                    style: theme.textTheme.bodySmall),
                _Condition(
                  ok: p.accOk,
                  text: '正确率 '
                      '${acc == null ? '—' : '${(acc * 100).round()}%'}'
                      '（需 ≥${(p.accMin * 100).round()}%）',
                ),
                _Condition(
                  ok: p.rtOk,
                  text: '无提示反应中位 '
                      '${rt == null ? '—' : '${(rt / 1000).toStringAsFixed(1)}s'}'
                      '（需 ≤${(p.rtMaxMs / 1000).toStringAsFixed(1)}s）',
                ),
                _Condition(
                  ok: p.hintOk,
                  text: '提示使用 ${p.hintCount} 次（需 0）',
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 单核心条目一行：标签 + 稳定三条件徽章 + 连对圆环；点按展开四条件明细。
class _CoreItemProgress extends StatefulWidget {
  final CoreItemStableProgress p;
  const _CoreItemProgress({required this.p});

  @override
  State<_CoreItemProgress> createState() => _CoreItemProgressState();
}

class _CoreItemProgressState extends State<_CoreItemProgress> {
  bool _expanded = false;

  static String _days(double d) =>
      d < 1 ? d.toStringAsFixed(1) : d.round().toString();

  static String _stateName(ItemState s) => switch (s) {
        ItemState.learning => '学习中',
        ItemState.reviewing => '复习中',
        ItemState.automated => '已自动化',
        ItemState.inactive => '未激活',
        ItemState.relapsed => '已回退',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.p;
    final m = p.mastery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('core_row_${p.item.id}'),
          onTap: p.stable ? null : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    p.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (p.stable)
                  Expanded(
                    child: Text('已稳定',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.green.shade700)),
                  )
                else ...[
                  _StatusChip(
                    ok: p.intervalOk,
                    icon: Icons.calendar_today,
                    label: '${_days(m.intervalDays)}天',
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(
                    ok: p.hintDepOk,
                    icon: Icons.lightbulb_outline,
                    label: '${(m.hintDependency * 100).round()}%',
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(
                    ok: p.streakOk,
                    icon: Icons.repeat,
                    label: '${p.streakCorrect}/${p.streakWindow}',
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.hintColor,
                  ),
                ],
                const SizedBox(width: 8),
                _StreakRing(p: p),
              ],
            ),
          ),
        ),
        if (_expanded && !p.stable)
          Padding(
            padding: const EdgeInsets.only(left: 76, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.fullLabel != p.label)
                  Text(p.fullLabel, style: theme.textTheme.bodySmall),
                _Condition(
                  ok: p.stateOk,
                  text: '已进入间隔复习（当前：${_stateName(m.state)}）',
                ),
                _Condition(
                  ok: p.intervalOk,
                  text: '复习间隔 ${_days(m.intervalDays)} 天'
                      '（需 ≥${p.minIntervalDays} 天）',
                ),
                _Condition(
                  ok: p.hintDepOk,
                  text: '提示依赖 ${(m.hintDependency * 100).round()}%'
                      '（需 ≤${(p.hintDepMax * 100).round()}%）',
                ),
                _Condition(
                  ok: p.streakOk,
                  text: '最近 ${p.streakWindow} 次全对'
                      '（当前 ${p.streakCorrect}/${p.streakWindow}'
                      '${p.resultCount < p.streakWindow ? '，已积累 ${p.resultCount} 次' : ''}）',
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 连对圆环：中心数字=最近窗口内答对数；稳定后换成绿色对勾。
class _StreakRing extends StatelessWidget {
  final CoreItemStableProgress p;
  const _StreakRing({required this.p});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (p.stable) {
      return Icon(Icons.check_circle, size: 28, color: Colors.green.shade700);
    }
    final filled = p.resultCount < p.streakWindow
        ? p.resultCount / p.streakWindow
        : 1.0;
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: filled,
            strokeWidth: 3,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          Text('${p.streakCorrect}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontSize: 9, color: theme.hintColor)),
        ],
      ),
    );
  }
}

/// 达标徽章：绿色=满足，灰色=未满足；数值直接写在徽章上。
class _StatusChip extends StatelessWidget {
  final bool ok;
  final IconData icon;
  final String label;
  const _StatusChip(
      {required this.ok, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ok ? Colors.green.shade700 : theme.hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: ok
            ? Colors.green.withValues(alpha: 0.12)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// 窗口进度圆环：中心数字=已积累题数；自动化后换成绿色对勾。
class _WindowRing extends StatelessWidget {
  final AnchorAutomationProgress p;
  const _WindowRing({required this.p});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (p.automated) {
      return Icon(Icons.check_circle, size: 28, color: Colors.green.shade700);
    }
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: p.windowCount / p.window,
            strokeWidth: 3,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          Text('${p.windowCount}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontSize: 9, color: theme.hintColor)),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Legend({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: theme.hintColor),
        const SizedBox(width: 3),
        Text(text,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.hintColor)),
      ],
    );
  }
}

class _Condition extends StatelessWidget {
  final bool ok;
  final String text;
  const _Condition({required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: ok ? Colors.green.shade700 : theme.hintColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}