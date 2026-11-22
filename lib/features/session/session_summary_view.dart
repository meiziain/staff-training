// 规格: 06 §2 S4 会话总结 —— 稳定条目列表、直认激活/回退、错误类型分布（小条形）、
// 明日到期预告；按钮「返回首页 / 查看掌握地图」。
library;

import 'package:material_ui/material_ui.dart';

import '../../data/session_summary.dart';
import '../../domain/models/note_position.dart';

class SessionSummaryView extends StatelessWidget {
  const SessionSummaryView({
    super.key,
    required this.data,
    required this.onHome,
    this.onMasteryMap,
  });

  final SessionSummaryData data;
  final VoidCallback onHome;
  final VoidCallback? onMasteryMap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxErr = data.errors.isEmpty ? 1 : data.errors.first.count;
    return Scaffold(
      key: const Key('summary_page'),
      appBar: AppBar(title: const Text('本次会话')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '完成 ${data.doneCount} 题 · 音级正确率 ${(data.accuracy * 100).round()}%',
            style: theme.textTheme.titleMedium,
          ),
          Text(
            '试次 ${data.trialCount} · 正确 ${data.correctCount}'
            '${data.timeoutCount > 0 ? ' · 超时 ${data.timeoutCount}' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),

          // ---- 今天稳定 ----
          Text('今天稳定', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (data.stable.isEmpty)
            Text('本次暂无新稳定条目（稳定需间隔 ≥7 天且零提示）',
                style: theme.textTheme.bodySmall)
          else
            for (final s in data.stable.take(8))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(s.label)),
                    Text('间隔 ${s.intervalDays} 天',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          const SizedBox(height: 20),

          // ---- 直认激活 / 回退 ----
          if (data.promoted.isNotEmpty || data.relapsed.isNotEmpty) ...[
            Text('直认变化', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final i in data.promoted)
                  Chip(
                    key: Key('summary_promoted_$i'),
                    avatar: const Icon(Icons.arrow_upward, size: 16),
                    label: Text('激活 ${NotePosition.of(i).displayName}'),
                  ),
                for (final i in data.relapsed)
                  Chip(
                    key: Key('summary_relapsed_$i'),
                    avatar: const Icon(Icons.arrow_downward, size: 16),
                    label: Text('回退 ${NotePosition.of(i).displayName}'),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],

          // ---- 错误类型分布 ----
          Text('错误类型', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (data.errors.isEmpty)
            Text('本次没有错误', style: theme.textTheme.bodySmall)
          else
            for (final e in data.errors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                        width: 96,
                        child: Text(errorTypeLabel(e.type),
                            style: theme.textTheme.bodySmall)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: e.count / maxErr,
                        minHeight: 6,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 24,
                      child: Text('${e.count}',
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 20),

          Text(
            data.dueTomorrow > 0
                ? '明日到期 ${data.dueTomorrow} 条'
                : '明日暂无到期复习',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('summary_home'),
                  onPressed: onHome,
                  child: const Text('返回首页'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('summary_map'),
                  onPressed: onMasteryMap,
                  child: const Text('查看掌握地图'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
