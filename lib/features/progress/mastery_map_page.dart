// 规格: 06 §2 S5 / 02 §7.4 —— 轻量掌握地图。
//
// 裁决记录（MVP）:
// 1) 音位状态来源 = 该音位 DIRECT 条目的 mastery.state；无 DIRECT 条目或无
//    mastery 行 → 未激活（02 §7.4 仅定义五状态，不引入额外口径）。
// 2) 提示依赖度周均 = Σ config.hintDepWeights[level-1]（level 0 记 0）/
//    该自然周试次数；权重表来自 settings（02 §8.6）。
// 3) 间隔后保持率周均 = 「correct && hint_level_used==0」占比，分母只统计
//    所属 item 的 mastery.interval_days >= 3 的试次。mastery 无历史间隔快照，
//    用当前 interval_days 近似归属，属 MVP 口径裁决（02 §7.4 未给历史快照）。
// 4) 直认自动化数无历史快照（mastery 仅存当前值），故画当前值水平参考线，
//    不伪造时间序列。
// 5) 明确不展示「今日刷题正确率」作为主指标（02 §7.4 核心展示口径）。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../data/repositories/confusion_seed_repo.dart';
import '../../data/repositories/item_repo.dart';
import '../../data/repositories/mastery_repo.dart';
import '../../data/repositories/trial_repo.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/item.dart';
import '../../domain/models/mastery.dart';
import '../../domain/models/note_position.dart';
import '../../domain/models/trial.dart';

/// 单个音位的展示数据。
class _CellData {
  final int index;
  final Item? item;
  final Mastery? mastery;

  const _CellData(this.index, this.item, this.mastery);

  ItemState get state => mastery?.state ?? ItemState.inactive;
  String get name => NotePosition.of(index).displayName;
}

/// 单个自然周的聚合值。
class _WeekPoint {
  final DateTime weekStart;
  final double hintDependency; // 0..1
  final double? retention; // 0..1；该周无「间隔 ≥3 天」试次时为 null
  final int? retentionTrials;

  const _WeekPoint({
    required this.weekStart,
    required this.hintDependency,
    this.retention,
    this.retentionTrials,
  });
}

class _MapData {
  final Map<int, _CellData> cells;
  final List<_WeekPoint> weeks;
  final int automatedDirect;
  final int directTotal;
  final List<Map<String, Object?>> confusion;

  const _MapData({
    required this.cells,
    required this.weeks,
    required this.automatedDirect,
    required this.directTotal,
    required this.confusion,
  });
}

class MasteryMapPage extends ConsumerStatefulWidget {
  const MasteryMapPage({super.key});

  @override
  ConsumerState<MasteryMapPage> createState() => _MasteryMapPageState();
}

class _MasteryMapPageState extends ConsumerState<MasteryMapPage> {
  late Future<_MapData> _future;
  int? _selected;
  Future<List<Trial>>? _recent;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_MapData> _load() async {
    final db = await ref.read(databaseProvider.future);
    final config = ref.read(configProvider).value ?? Config.defaults;

    // 音位格网：DIRECT 条目 + 其 mastery（不新增仓库查询，读现有 API）。
    final directItems = await ItemRepo(db).byType(ItemType.direct);
    final masteries = <int, Mastery>{
      for (final m in await MasteryRepo(db).all()) m.itemId: m,
    };
    final byIndex = <int, _CellData>{};
    for (final item in directItems) {
      final payload = item.payload;
      if (payload is! DirectPayload) continue;
      byIndex[payload.diatonicIndex] = _CellData(
        payload.diatonicIndex,
        item,
        masteries[item.id],
      );
    }
    final cells = <int, _CellData>{
      for (final i in pool) i: byIndex[i] ?? _CellData(i, null, null),
    };

    final automatedDirect = directItems
        .where((i) => masteries[i.id]?.state == ItemState.automated)
        .length;

    // 趋势：按自然周聚合 trial_log（跨全部条目）。
    final rows = await db.rawQuery(
      'SELECT presented_at, correct, hint_level_used, item_id '
      'FROM trial_log ORDER BY presented_at ASC',
    );
    final aggs = <String, _WeekAgg>{};
    for (final r in rows) {
      final ts = r['presented_at'] as int;
      final local = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
      final weekStart = _weekStart(local);
      final key = '${weekStart.year}-${weekStart.month}-${weekStart.day}';
      final agg = aggs.putIfAbsent(key, () => _WeekAgg(weekStart));
      final level = r['hint_level_used'] as int;
      agg.addHintDependency(_hintWeight(config, level));
      final mastery = masteries[r['item_id'] as int];
      if (mastery != null && mastery.intervalDays >= 3) {
        agg.addRetention(correct: (r['correct'] as int) == 1 && level == 0);
      }
    }
    final sorted = aggs.values.toList()
      ..sort((a, b) => a.weekStart.compareTo(b.weekStart));
    final recentWeeks = sorted.length > 8
        ? sorted.sublist(sorted.length - 8)
        : sorted;
    final weeks = [
      for (final a in recentWeeks)
        _WeekPoint(
          weekStart: a.weekStart,
          hintDependency: a.depN == 0 ? 0 : a.depSum / a.depN,
          retention: a.retN == 0 ? null : a.retOk / a.retN,
          retentionTrials: a.retN,
        ),
    ];

    return _MapData(
      cells: cells,
      weeks: weeks,
      automatedDirect: automatedDirect,
      directTotal: directItems.length,
      confusion: await ConfusionSeedRepo(db).all(),
    );
  }

  static double _hintWeight(Config config, int level) {
    if (level <= 0) return 0;
    final weights = config.hintDepWeights;
    if (weights.isEmpty) return 0;
    final i = (level - 1).clamp(0, weights.length - 1);
    return weights[i];
  }

  static DateTime _weekStart(DateTime local) {
    final day = DateTime(local.year, local.month, local.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  void _select(_CellData cell) {
    setState(() {
      _selected = cell.index;
      _recent = cell.item == null
          ? Future.value(const <Trial>[])
          : _recentTrials(cell.item!.id);
    });
  }

  Future<List<Trial>> _recentTrials(int itemId) async {
    final db = await ref.read(databaseProvider.future);
    return TrialRepo(db).recentByItem(itemId, 10);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('掌握地图')),
      body: FutureBuilder<_MapData>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('加载失败：${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _body(context, snap.data!);
        },
      ),
    );
  }

  Widget _body(BuildContext context, _MapData data) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: Text('音位格网', style: theme.textTheme.titleMedium)),
            Text(
              '${data.directTotal}/22 已有直认条目',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('颜色 + 形状双编码，共五种状态', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        const _Legend(),
        const SizedBox(height: 12),
        _Grid(data: data, selected: _selected, onTap: _select),
        if (_selected != null) ...[
          const SizedBox(height: 12),
          _DetailPanel(
            key: ValueKey('detail_$_selected'),
            cell: data.cells[_selected]!,
            recent: _recent ?? Future.value(const <Trial>[]),
          ),
        ],
        const SizedBox(height: 24),
        Text('趋势（自然周均）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _TrendPanel(data: data),
        const SizedBox(height: 24),
        Text('易混对', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        if (data.confusion.isEmpty)
          Text('暂无易混对记录', style: theme.textTheme.bodySmall)
        else
          for (final row in data.confusion)
            _ConfusionRow(
              pairA: row['pair_a'] as int,
              pairB: row['pair_b'] as int,
              count: row['count'] as int,
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 格网与图例
// ---------------------------------------------------------------------------

const Map<ItemState, String> _stateLabels = {
  ItemState.inactive: '未激活',
  ItemState.learning: '学习中',
  ItemState.reviewing: '复习中',
  ItemState.automated: '已自动化',
  ItemState.relapsed: '已回退',
};

Color _stateColor(ItemState state, ColorScheme scheme) => switch (state) {
  ItemState.inactive => scheme.onSurfaceVariant,
  ItemState.learning => const Color(0xFFB26A00),
  ItemState.reviewing => const Color(0xFF1565C0),
  ItemState.automated => const Color(0xFF2E7D32),
  ItemState.relapsed => const Color(0xFFC62828),
};

/// 五状态形状绘制（色盲可用：空心圆/半圆/三角/方块/叉）。
class _StateShape extends StatelessWidget {
  final ItemState state;
  final double size;

  const _StateShape(this.state, {this.size = 16});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _StateShapePainter(
        state: state,
        color: _stateColor(state, Theme.of(context).colorScheme),
      ),
    );
  }
}

class _StateShapePainter extends CustomPainter {
  final ItemState state;
  final Color color;

  const _StateShapePainter({required this.state, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.32;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, size.width * 0.1)
      ..strokeCap = StrokeCap.round;
    switch (state) {
      case ItemState.inactive:
        canvas.drawCircle(c, r, stroke);
      case ItemState.learning:
        // 半圆：左半实心，整体描边。
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          math.pi / 2,
          math.pi,
          true,
          fill,
        );
        canvas.drawCircle(c, r, stroke);
      case ItemState.reviewing:
        final path = Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx + r, c.dy + r * 0.8)
          ..lineTo(c.dx - r, c.dy + r * 0.8)
          ..close();
        canvas.drawPath(path, fill);
      case ItemState.automated:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: r * 1.9, height: r * 1.9),
            const Radius.circular(1.5),
          ),
          fill,
        );
      case ItemState.relapsed:
        canvas.drawLine(
          Offset(c.dx - r, c.dy - r),
          Offset(c.dx + r, c.dy + r),
          stroke,
        );
        canvas.drawLine(
          Offset(c.dx + r, c.dy - r),
          Offset(c.dx - r, c.dy + r),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _StateShapePainter old) =>
      old.state != state || old.color != color;
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final entry in _stateLabels.entries)
          Row(
            key: Key('legend_${entry.key.name}'),
            mainAxisSize: MainAxisSize.min,
            children: [
              _StateShape(entry.key, size: 14),
              const SizedBox(width: 4),
              Text(entry.value, style: theme.textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  final _MapData data;
  final int? selected;
  final ValueChanged<_CellData> onTap;

  const _Grid({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _rowLabel(context, '高音谱表 C4–C6'),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                key: const Key('row_treble'),
                children: [
                  for (var i = 0; i <= 14; i++)
                    _Cell(
                      cell: data.cells[i]!,
                      clef: Clef.treble,
                      selected: selected == i,
                      onTap: onTap,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _rowLabel(context, '低音谱表 C3–C4（C4 双标）'),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                key: const Key('row_bass'),
                children: [
                  for (var i = -7; i <= 0; i++)
                    _Cell(
                      cell: data.cells[i]!,
                      clef: Clef.bass,
                      selected: selected == i,
                      onTap: onTap,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowLabel(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);
}

class _Cell extends StatelessWidget {
  final _CellData cell;
  final Clef clef;
  final bool selected;
  final ValueChanged<_CellData> onTap;

  const _Cell({
    required this.cell,
    required this.clef,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = cell.state;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        label:
            '${clef == Clef.treble ? '高音' : '低音'} ${cell.name} '
            '${_stateLabels[state]}',
        button: true,
        child: InkWell(
          key: Key('cell_${clef.name}_${cell.index}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => onTap(cell),
          child: Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? scheme.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StateShape(state),
                const SizedBox(height: 4),
                Text(
                  cell.name,
                  key: Key('cell_label_${clef.name}_${cell.index}'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 音位详情
// ---------------------------------------------------------------------------

class _DetailPanel extends StatelessWidget {
  final _CellData cell;
  final Future<List<Trial>> recent;

  const _DetailPanel({super.key, required this.cell, required this.recent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = cell.mastery;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StateShape(cell.state),
                const SizedBox(width: 6),
                Text('${cell.name} 详情', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  _stateLabels[cell.state]!,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (cell.item == null)
              Text('该音位尚未建立直认条目', style: theme.textTheme.bodySmall)
            else ...[
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  _metric(
                    theme,
                    'RT 中位数',
                    m?.rtMedian == null ? '—' : '${m!.rtMedian} ms',
                  ),
                  _metric(
                    theme,
                    '提示依赖',
                    m == null ? '—' : m.hintDependency.toStringAsFixed(2),
                  ),
                  _metric(
                    theme,
                    '间隔',
                    m == null ? '—' : '${m.intervalDays.toStringAsFixed(0)} 天',
                  ),
                  _metric(theme, '遗忘次数', '${m?.lapses ?? 0}'),
                ],
              ),
              const SizedBox(height: 8),
              Text('最近 10 次作答', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              FutureBuilder<List<Trial>>(
                future: recent,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final trials = snap.data!;
                  if (trials.isEmpty) {
                    return Text('暂无作答记录', style: theme.textTheme.bodySmall);
                  }
                  return Column(
                    children: [
                      for (var i = 0; i < trials.length; i++)
                        _trialRow(theme, trials[trials.length - 1 - i], i),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metric(ThemeData theme, String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$label ', style: theme.textTheme.bodySmall),
      Text(value, style: theme.textTheme.bodyMedium),
    ],
  );

  Widget _trialRow(ThemeData theme, Trial t, int i) {
    final ts = t.answeredAt ?? t.presentedAt;
    final parts = <String>[
      t.correct ? '✓' : '✗',
      '${t.rtMs ?? '—'} ms',
      _formatTs(ts),
      if (t.hintLevelUsed > 0) '提示${t.hintLevelUsed}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        key: Key('detail_trial_$i'),
        children: [
          Expanded(
            child: Text(parts.join(' · '), style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

String _formatTs(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// ---------------------------------------------------------------------------
// 趋势（周均，自绘折线，不引入图表依赖）
// ---------------------------------------------------------------------------

class _TrendPanel extends StatelessWidget {
  final _MapData data;

  const _TrendPanel({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hintValues = [for (final w in data.weeks) w.hintDependency];
    final retentionValues = [for (final w in data.weeks) w.retention];
    final latestHint = hintValues.isEmpty ? null : hintValues.last;
    final latestRetention = retentionValues.whereType<double>().isEmpty
        ? null
        : retentionValues.whereType<double>().last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TrendChart(
          key: const Key('trend_hint_dep'),
          title: '提示依赖度',
          subtitle: latestHint == null
              ? '暂无数据'
              : '最近一周 ${latestHint.toStringAsFixed(2)}（≤0.3 为稳定）',
          values: hintValues,
          maxValue: 1,
          color: scheme.primary,
          weeks: data.weeks,
        ),
        const SizedBox(height: 12),
        _TrendChart(
          key: const Key('trend_retention'),
          title: '间隔后保持率',
          subtitle: latestRetention == null
              ? '暂无间隔 ≥3 天的复习试次'
              : '最近一周 ${(latestRetention * 100).round()}%（无提示正确占比）',
          values: retentionValues,
          maxValue: 1,
          color: const Color(0xFF2E7D32),
          weeks: data.weeks,
        ),
        const SizedBox(height: 12),
        _TrendChart(
          key: const Key('trend_automated'),
          title: '直认自动化数',
          subtitle: '当前 ${data.automatedDirect}/22 · 水平参考线（无历史快照）',
          values: const [],
          maxValue: 22,
          reference: data.automatedDirect.toDouble(),
          color: const Color(0xFF1565C0),
          weeks: const [],
        ),
      ],
    );
  }
}

class _TrendChart extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<double?> values;
  final double maxValue;
  final double? reference;
  final Color color;
  final List<_WeekPoint> weeks;

  const _TrendChart({
    super.key,
    required this.title,
    required this.subtitle,
    required this.values,
    required this.maxValue,
    required this.color,
    required this.weeks,
    this.reference,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            SizedBox(
              height: 64,
              width: double.infinity,
              child: CustomPaint(
                painter: _TrendPainter(
                  values: values,
                  maxValue: maxValue,
                  reference: reference,
                  color: color,
                  gridColor: theme.colorScheme.outlineVariant,
                ),
              ),
            ),
            if (weeks.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _weekLabel(weeks.first.weekStart),
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    _weekLabel(weeks.last.weekStart),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _weekLabel(DateTime d) => '${d.month}/${d.day} 周';
}

class _TrendPainter extends CustomPainter {
  final List<double?> values;
  final double maxValue;
  final double? reference;
  final Color color;
  final Color gridColor;

  const _TrendPainter({
    required this.values,
    required this.maxValue,
    required this.color,
    required this.gridColor,
    this.reference,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 6.0;
    final rect = Rect.fromLTWH(
      pad,
      pad,
      size.width - pad * 2,
      size.height - pad * 2,
    );
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(rect.bottomLeft, rect.bottomRight, grid);
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft.translate(0, rect.height / 2),
      grid..color = gridColor.withValues(alpha: 0.4),
    );

    final ref = reference;
    if (ref != null) {
      final y = rect.bottom - rect.height * (ref / maxValue).clamp(0.0, 1.0);
      final dash = Paint()
        ..color = color
        ..strokeWidth = 1.6;
      var x = rect.left;
      while (x < rect.right) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 6, rect.right), y),
          dash,
        );
        x += 11;
      }
    }

    if (values.isEmpty) return;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = color;
    final step = values.length == 1 ? 0.0 : rect.width / (values.length - 1);
    final path = Path();
    var started = false;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      final x = rect.left + step * i;
      final y = rect.bottom - rect.height * (v / maxValue).clamp(0.0, 1.0);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 2.6, dot);
    }
    if (started) canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.maxValue != maxValue ||
      old.reference != reference ||
      old.color != color ||
      old.values.length != values.length ||
      !_sameValues(old.values, values);

  static bool _sameValues(List<double?> a, List<double?> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// 易混对
// ---------------------------------------------------------------------------

class _ConfusionRow extends StatelessWidget {
  final int pairA;
  final int pairB;
  final int count;

  const _ConfusionRow({
    required this.pairA,
    required this.pairB,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        key: Key('confusion_${pairA}_$pairB'),
        children: [
          Expanded(
            child: Text(
              '${NotePosition.of(pairA).displayName} ↔ '
              '${NotePosition.of(pairB).displayName}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text('×$count', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// 周聚合中间态。
class _WeekAgg {
  final DateTime weekStart;
  double depSum = 0;
  int depN = 0;
  int retOk = 0;
  int retN = 0;

  _WeekAgg(this.weekStart);

  void addHintDependency(double weight) {
    depSum += weight;
    depN++;
  }

  void addRetention({required bool correct}) {
    retN++;
    if (correct) retOk++;
  }
}
