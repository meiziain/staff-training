// 规格: 06 §4 ProgressHeader / §2 S3 顶部 —— 段标签 + 三态进度点 + 退出。
// 退出确认弹窗由调用方负责；index 为 0 基当前题下标。
library;

import 'package:material_ui/material_ui.dart';

/// 会话段标签（06 §2 S3）。调度层 QueueSegment 由调用方映射到本枚举。
enum SessionSegment {
  warmup('热身'),
  microLesson('微课'),
  mixed('混合'),
  phrase('短句'),
  summary('总结');

  final String label;
  const SessionSegment(this.label);
}

class ProgressHeader extends StatelessWidget {
  const ProgressHeader({
    super.key,
    required this.segment,
    required this.index,
    required this.total,
    required this.onExit,
  })  : assert(index >= 0),
        assert(total > 0);

  final SessionSegment segment;

  /// 当前题下标（0 基）；显示为 index+1/total。
  final int index;
  final int total;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dots = <Widget>[];
    for (var i = 0; i < total; i++) {
      final String state;
      final double size;
      final Color? fill;
      final BoxBorder? border;
      if (i < index) {
        state = 'done';
        size = 8;
        fill = scheme.onSurfaceVariant;
        border = null;
      } else if (i == index) {
        state = 'current';
        size = 10;
        fill = scheme.primary;
        border = null;
      } else {
        state = 'todo';
        size = 8;
        fill = null;
        border = Border.all(color: scheme.outline);
      }
      dots.add(Container(
        key: ValueKey('progress_dot_${state}_$i'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill,
          border: border,
        ),
      ));
    }
    return Row(children: [
      IconButton(
        key: const ValueKey('session_exit'),
        icon: const Icon(Icons.arrow_back),
        tooltip: '退出',
        onPressed: onExit,
      ),
      Text(
        segment.label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        '${index + 1 > total ? total : index + 1}/$total',
        style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Wrap(spacing: 4, runSpacing: 4, children: dots),
      ),
    ]);
  }
}