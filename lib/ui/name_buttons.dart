// 规格: 06 §4 NameButtons / §3 平板适配；02 §1.3 音名按钮模式。
// 7 键等宽单行；按下即触发（onPointerDown，不用 onTapUp 延迟）；禁用置灰。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

const List<String> _pitchClasses = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];

class NameButtons extends StatelessWidget {
  const NameButtons({super.key, required this.onAnswer, this.enabled = true});

  final ValueChanged<String> onAnswer;
  final bool enabled;

  static const double _gapMax = 8;
  static const double _gapMin = 4;
  static const double _minKeyWidth = 44;
  static const double _tabletKeyWidth = 64;
  static const double _tabletBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;
      final tablet = available >= _tabletBreakpoint;
      // 手机窄屏优先保证「单行 7 键全部可见」（02 §1.3 / 06 §3）：
      // 先压缩间距（8→4dp），再按可用宽度均分；44dp 是下限，屏宽不足才横向滚动。
      final gap = available >= _minKeyWidth * 7 + _gapMax * 6 ? _gapMax : _gapMin;
      final keyWidth =
          tablet ? _tabletKeyWidth : math.max(_minKeyWidth, (available - gap * 6) / 7);
      final children = <Widget>[];
      for (var i = 0; i < _pitchClasses.length; i++) {
        if (i > 0) children.add(SizedBox(width: gap));
        children.add(SizedBox(
          width: keyWidth,
          child: _NameKey(
            key: ValueKey('name_button_${_pitchClasses[i]}'),
            pitchClass: _pitchClasses[i],
            enabled: enabled,
            onAnswer: onAnswer,
          ),
        ));
      }
      final totalWidth = keyWidth * 7 + gap * 6;
      final overflow = totalWidth > available;
      final row = Row(
        mainAxisSize: overflow ? MainAxisSize.min : MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      );
      return overflow
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal, child: row)
          : row;
    });
  }
}

class _NameKey extends StatefulWidget {
  const _NameKey({
    super.key,
    required this.pitchClass,
    required this.enabled,
    required this.onAnswer,
  });

  final String pitchClass;
  final bool enabled;
  final ValueChanged<String> onAnswer;

  @override
  State<_NameKey> createState() => _NameKeyState();
}

class _NameKeyState extends State<_NameKey> {
  bool _pressed = false;

  /// 只认一根手指：多指同时按下时避免一次点击提交多次（重复播音）。
  int? _activePointer;

  void _down(PointerDownEvent event) {
    if (!widget.enabled || _activePointer != null) return;
    _activePointer = event.pointer;
    setState(() => _pressed = true);
    widget.onAnswer(widget.pitchClass);
  }

  void _release(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    if (!widget.enabled) {
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurface.withValues(alpha: 0.38);
    } else if (_pressed) {
      background = scheme.primary;
      foreground = scheme.onPrimary;
    } else {
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurface;
    }
    return Listener(
      onPointerDown: _down,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          widget.pitchClass,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
        ),
      ),
    );
  }
}