// 规格: 11 §6.1 —— 视奏训练模式选择页（S7）。
//
// 结构：模式（右手/左手/双手）→ 两个 tab（生成练习 / 曲目）。
// - 生成练习：单手滑杆 4–32 音，双手滑杆 4–12 列（默认均 8）。
// - 曲目：读 assets/scores/ 下的 6 条内置曲目（domain 只解析字符串，
//   asset 读取留在本层）。
// - 阶段 < 2 只在顶部提示「建议先练熟更多音位再视奏」，不锁入口（11 §10 裁决 3）。
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/providers.dart';
import '../../core/rng.dart';
import '../../data/repositories/app_state_repo.dart';
import '../../domain/models/sight_level.dart';
import '../../domain/models/sight_score.dart';
import '../../domain/models/sight_time_signature.dart';
import '../../domain/score_library.dart';
import '../../domain/sight_generator.dart';
import 'sight_session_page.dart';

class SightModePage extends ConsumerStatefulWidget {
  const SightModePage({super.key});

  @override
  ConsumerState<SightModePage> createState() => _SightModePageState();
}

class _SightModePageState extends ConsumerState<SightModePage>
    with SingleTickerProviderStateMixin {
  /// 阶段低于此值时提示先补音位（11 §6.1）。
  static const int _recommendedStage = 2;

  SightMode _mode = SightMode.trebleOnly;

  /// 生成练习难度档，默认 L1（Q2 裁决：一个下拉即可）。
  SightLevel _level = SightLevel.L1;

  /// 拍号：只调控节奏结构（每小节拍数 + 一拍的时值 + 重音），不改音高生成。
  SightTimeSignature _timeSignature = SightTimeSignature.common4_4;

  /// 速度：每分钟四分音符数（♩=N），独立选项，不随难度档/拍号改变。
  int _quartersPerMinute = 60;

  /// 速度档位：四分音符/分钟。
  static const List<int> _tempoChoices = [40, 50, 60, 72, 84, 96, 108, 120];

  /// 单手生成音数（4–32）与双手列数（4–12），各模式独立记忆，默认都是 8。
  int _singleLength = sightDefaultLength;
  int _grandColumns = sightDefaultLength;

  late final TabController _tabs;
  late final Future<int> _stage;
  late final Future<List<SightScore>> _library;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _stage = _loadStage();
    _library = _loadLibrary();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// 课程阶段：读不到（数据库未就绪）时按 0 处理，只影响提示不影响入口。
  Future<int> _loadStage() async {
    try {
      final db = await ref.read(databaseProvider.future);
      final raw = await AppStateRepo(db).get('course_stage');
      return int.tryParse(raw ?? '') ?? 0;
    } catch (e) {
      debugPrint('读取课程阶段失败（视奏入口提示降级）：$e');
      return 0;
    }
  }

  /// 逐条读内置曲目；单条损坏只跳过该条，不让整页失败。
  Future<List<SightScore>> _loadLibrary() async {
    final scores = <SightScore>[];
    for (final path in builtinScoreAssetPaths) {
      try {
        scores.add(scoreFromJsonString(await rootBundle.loadString(path)));
      } catch (e) {
        debugPrint('内置曲目 $path 解析失败：$e');
      }
    }
    return scores;
  }

  void _startGenerated() {
    final clock = ref.read(clockProvider);
    // 档位与用户所选模式冲突时模式优先：回退 legacy 生成，不吞掉已选的双手/左手。
    final level = _level.spec.mode == _mode ? _level : null;
    final generated = generateSightScore(
      mode: _mode,
      rng: rng(clock.nowUtcMs() & 0x7fffffff),
      columnCount: _mode == SightMode.grand ? _grandColumns : _singleLength,
      level: level,
    );
    _open(
      generated.score,
      source: 'generated',
      level: _level,
      timeSignature: _timeSignature,
      quartersPerMinute: _quartersPerMinute,
    );
  }

  void _open(
    SightScore score, {
    required String source,
    SightLevel? level,
    SightTimeSignature? timeSignature,
    int? quartersPerMinute,
  }) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SightSessionPage(
        score: score,
        source: source,
        scoreRef: source == 'score' ? score.scoreId : null,
        level: level ?? SightLevel.L1,
        timeSignature: timeSignature ?? SightTimeSignature.common4_4,
        quartersPerMinute: quartersPerMinute ?? 60,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('视奏训练')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<SightMode>(
                  key: const Key('sight_mode_selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: SightMode.trebleOnly,
                      label: Text('右手'),
                      icon: Icon(Icons.music_note),
                    ),
                    ButtonSegment(
                      value: SightMode.bassOnly,
                      label: Text('左手'),
                      icon: Icon(Icons.library_music),
                    ),
                    ButtonSegment(
                      value: SightMode.grand,
                      label: Text('双手'),
                      icon: Icon(Icons.piano),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selected) =>
                      setState(() => _mode = selected.first),
                ),
              ),
            ),
            FutureBuilder<int>(
              future: _stage,
              builder: (context, snap) {
                final stage = snap.data;
                if (stage == null || stage >= _recommendedStage) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: theme.hintColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '建议先练熟更多音位再视奏',
                          key: const Key('sight_stage_hint'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(key: Key('sight_tab_generated'), text: '生成练习'),
                Tab(key: Key('sight_tab_scores'), text: '曲目'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildGenerateTab(theme),
                  _buildLibraryTab(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateTab(ThemeData theme) {
    final isGrand = _mode == SightMode.grand;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildLevelControl(theme),
        const SizedBox(height: 16),
        _buildLengthControl(theme, isGrand: isGrand),
        const SizedBox(height: 16),
        _buildTempoControl(theme),
        const SizedBox(height: 16),
        _buildTimeSignatureControl(theme),
        const SizedBox(height: 28),
        FilledButton.icon(
          key: const Key('sight_start'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
          onPressed: _startGenerated,
          icon: const Icon(Icons.play_arrow),
          label: const Text('开始'),
        ),
        const SizedBox(height: 12),
        Text(
          '无倒计时 · 跟着脉搏走',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  /// 拍号下拉：分母 8 一拍时长减半 → 同 BPM 下整体流速翻倍。
  Widget _buildTimeSignatureControl(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('拍号', style: theme.textTheme.titleSmall),
            const Spacer(),
            DropdownButton<SightTimeSignature>(
              key: const Key('sight_timesig_selector'),
              value: _timeSignature,
              items: [
                for (final sig in SightTimeSignature.presets)
                  DropdownMenuItem(
                    value: sig,
                    child: Text(sig.displayName),
                  ),
              ],
              onChanged: (sig) {
                if (sig == null) return;
                setState(() => _timeSignature = sig);
              },
            ),
          ],
        ),
        Text(
          '分子=每小节拍数，分母=以什么音符为一拍',
          key: const Key('sight_timesig_hint'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  /// 速度下拉：♩=N 是每分钟四分音符数，是与拍号无关的统一标尺。
  Widget _buildTempoControl(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('速度', style: theme.textTheme.titleSmall),
            const Spacer(),
            DropdownButton<int>(
              key: const Key('sight_tempo_selector'),
              value: _quartersPerMinute,
              items: [
                for (final tempo in _tempoChoices)
                  DropdownMenuItem(
                    value: tempo,
                    child: Text('♩ = $tempo'),
                  ),
              ],
              onChanged: (tempo) {
                if (tempo == null) return;
                setState(() => _quartersPerMinute = tempo);
              },
            ),
          ],
        ),
        Text(
          '♩ = $_quartersPerMinute 每分钟四分音符',
          key: const Key('sight_tempo_label'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
        Text(
          '速度以每分钟四分音符计，不随拍号变化',
          key: const Key('sight_tempo_hint'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  /// 难度档下拉（L1–L7）：UI 从简，只影响生成练习，不动内置曲目。
  Widget _buildLevelControl(ThemeData theme) {
    return Row(
      children: [
        Text('难度', style: theme.textTheme.titleSmall),
        const Spacer(),
        DropdownButton<SightLevel>(
          key: const Key('sight_level_selector'),
          value: _level,
          items: [
            for (final level in SightLevel.values)
              DropdownMenuItem(value: level, child: Text(level.wire)),
          ],
          onChanged: (level) {
            if (level == null) return;
            setState(() => _level = level);
          },
        ),
      ],
    );
  }

  /// 长度滑杆：单手 4–32 音、双手 4–12 列（11 §6.1 自定义入口）。
  Widget _buildLengthControl(ThemeData theme, {required bool isGrand}) {
    final value = isGrand ? _grandColumns : _singleLength;
    final min = isGrand ? sightGrandMinColumns : sightSingleMinCount;
    final max = isGrand ? sightGrandMaxColumns : sightSingleMaxCount;
    final unit = isGrand ? '列' : '音';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('长度', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              '$value $unit',
              key: const Key('sight_length_value'),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        Slider(
          key: const Key('sight_length_slider'),
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value $unit',
          onChanged: (v) => setState(() {
            if (isGrand) {
              _grandColumns = v.round();
            } else {
              _singleLength = v.round();
            }
          }),
        ),
        Text(
          isGrand ? '列数越多，单声部段落越多' : '一屏约 8–12 音，更多可横向滚动',
          key: const Key('sight_length_hint'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  Widget _buildLibraryTab(ThemeData theme) {
    return FutureBuilder<List<SightScore>>(
      future: _library,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final scores = snap.data ?? const <SightScore>[];
        if (scores.isEmpty) {
          return Center(
            child: Text('曲目加载失败', style: theme.textTheme.bodyMedium),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: scores.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final score = scores[i];
            return ListTile(
              key: Key('sight_score_${score.scoreId}'),
              leading: Icon(
                score.mode == SightMode.grand ? Icons.piano : Icons.music_note,
              ),
              title: Text('${score.title ?? '未命名'} · ${score.noteCount} 音'),
              subtitle: Text(
                '${score.mode.displayName} · ${score.columnCount} 列',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(
                    score,
                    source: 'score',
                    timeSignature: _timeSignature,
                    quartersPerMinute: _quartersPerMinute,
                  ),
            );
          },
        );
      },
    );
  }
}
