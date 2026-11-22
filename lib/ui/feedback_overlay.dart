// 规格: 06 §4 FeedbackOverlay / §2 S3 反馈时序 —— ✓/✗ + 正确答案标注。
// 600ms 时长由调用方控制；IgnorePointer 纯覆盖层，不阻塞作答与播音。
// 图标形状 + 文字双编码，颜色非唯一通道（色觉无障碍）。
library;

import 'package:material_ui/material_ui.dart';

class FeedbackOverlay extends StatelessWidget {
  const FeedbackOverlay({
    super.key,
    required this.correct,
    required this.correctAnswer,
    this.visible = true,
    this.answerGiven = false,
    this.rtLabel,
  });

  final bool correct;

  /// 正确答案标注，如 "G4"。
  final String correctAnswer;
  final bool visible;

  /// 提示级 5（直接给答案）时的反馈：按规格本题"记为提示完成、不计正确"，
  /// 不能显示 ✗（用户会以为答错了），改显示中性的"已给答案 · 本题不计分"。
  final bool answerGiven;

  /// 本题反应时标注（如 "反应 1.8s" / "超时未答"），null 不显示。
  final String? rtLabel;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final color = answerGiven
        ? scheme.onSurfaceVariant
        : (correct ? scheme.primary : scheme.error);
    final icon = answerGiven
        ? Icons.lightbulb_outline
        : (correct ? Icons.check : Icons.close);
    final label = answerGiven
        ? '已给答案：$correctAnswer · 本题不计分'
        : '正确答案：$correctAnswer';
    return IgnorePointer(
      child: Semantics(
        label: answerGiven
            ? '已给出答案 $correctAnswer，本题不计分'
            : (correct ? '回答正确' : '回答错误，正确答案 $correctAnswer'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.92),
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            if (rtLabel != null) ...[
              const SizedBox(height: 2),
              Text(
                rtLabel!,
                key: const Key('feedback_rt'),
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}