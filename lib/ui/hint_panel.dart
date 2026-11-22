// 规格: 06 §4 HintPanel / 02 §3.4 提示层级 / 05 §7 —— 级0..5 分层提示渲染。
// 灰阶克制 + 单强调色；级4 谱表常亮由 StaffView.anchorOverlay 负责，此处渲染文字卡片。
library;

import 'package:material_ui/material_ui.dart';

import '../domain/models/item.dart';
import '../domain/models/note_position.dart';

class HintPanel extends StatelessWidget {
  const HintPanel({
    super.key,
    required this.level,
    required this.relation,
    this.visible = true,
  }) : assert(level >= 0 && level <= 5);

  final int level;
  final RelationPayload relation;
  final bool visible;

  static String _lineSpace(int i) => isLine(i) ? '线' : '间';
  static String _intervalName(int steps) => steps == 2 ? '二度' : '三度';

  @override
  Widget build(BuildContext context) {
    if (!visible || level == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final baseStyle = TextStyle(fontSize: 16, color: scheme.onSurface);
    final anchor = relation.anchorIndex;
    final target = relation.targetIndex;
    final anchorName = NotePosition.of(anchor).displayName;
    final targetName = NotePosition.of(target).displayName;

    final Widget content;
    switch (level) {
      case 1:
        final up = target != anchor
            ? target > anchor
            : relation.first.direction > 0;
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
              color: scheme.primary),
          const SizedBox(width: 8),
          Text(up ? '往上' : '往下', style: baseStyle),
        ]);
      case 2:
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in relation.chain)
              Text(
                '${_lineSpace(s.anchorIndex)}→${_lineSpace(s.targetIndex)}'
                '＝${_intervalName(s.steps)}',
                style: baseStyle,
              ),
          ],
        );
      case 3:
        content = relation.isChain
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('两步推导', style: baseStyle),
                  Text(
                    relation.chain
                        .map((s) => _intervalName(s.steps))
                        .join(' → '),
                    style: baseStyle.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            : Text(_intervalName(relation.first.steps), style: baseStyle);
      case 4:
        content = Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.primary),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              anchorName,
              style: baseStyle.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text('复位到最近锚点，再推导一次', style: baseStyle),
          ),
        ]);
      default:
        content = Text(
          '答案：$targetName',
          style: baseStyle.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: content,
    );
  }
}