// 规格: 06 §4 VirtualKeyboard / §2 S3 / §3 平板适配；02 §1.3 键盘模式。
// C3–C6 共 22 白键（无黑键，MVP 无变音）；抬起且未滑动才提交（避免横滑找音误答）；
// 八度标签标在 C 键下方。
// 键列表由 domain 音位池 pool + midiOf 生成（midi 48..84）。
//
// 音域参数（11 §3.4）：视奏模式需要的音域比 22 音位池宽（C2–C6），通过
// [rangeMin]/[rangeMax]（diatonicIndex，闭区间）生成键列表；默认值即
// poolMin..poolMax，既有调用的键数与 C3–C6 chip 完全不变。
//
// 裁决（键盘找音体验）：手机上 22 键横向滚动，找八度耗时导致闪现超时。
// 1) 键盘上方加 C3/C4/C5/C6 快捷跳转（平板全宽可见时隐藏）；
// 2) 滚动位置由调用方注入 ScrollController 持久化——会话页上方部件增减
//    会导致本组件重建，内部持有的滚动位置会丢，外部 controller 不受影响；
// 3) onNavigateStart/onNavigateEnd：导航起止回调，供会话页"定位完成才
//    开始倒计时"并把导航耗时从 RT 中扣除（导航是 UI 开销不是认谱反应）。
//    按下不触发（滑动也从按键开始，按下无法区分意图）；位移超阈值判定
//    为滑动 → start；最后一个滑动指针抬手 → end；点按不触发（抬手即作答）；
//    八度跳转 chip：start → 动画 → end。
//    不自动滚到目标八度——键盘模式考察八度辨别（02 §1.3），自动定位泄题。
//    例外：会话首题由 SessionPage 把初始视口移到目标所在八度的 C（左留一键），
//    避免从 C3 盲找第一题；仍不居中目标键，八度内的定位练习保留。
library;

import 'package:material_ui/material_ui.dart';

import '../domain/models/note_position.dart';

class VirtualKeyboard extends StatefulWidget {
  const VirtualKeyboard({
    super.key,
    required this.onAnswer,
    this.enabled = true,
    this.controller,
    this.onNavigateStart,
    this.onNavigateEnd,
    this.rangeMin = poolMin,
    this.rangeMax = poolMax,
  }) : assert(rangeMin <= rangeMax, '键位音域下界不得大于上界');

  final ValueChanged<int> onAnswer;
  final bool enabled;

  /// 键位音域（diatonicIndex，闭区间）。默认沿用 C3–C6 的 22 音位池。
  final int rangeMin;
  final int rangeMax;

  /// 外部持久化滚动位置；不传则内部自建（随组件销毁丢失）。
  final ScrollController? controller;

  /// 导航开始：首次判定为滑动（位移超阈值）或八度跳转 chip 点击。
  final VoidCallback? onNavigateStart;

  /// 导航结束：最后一个滑动指针抬手，或八度跳转动画完成。
  /// 按键按下/点按不触发。
  final VoidCallback? onNavigateEnd;

  static const double minKeyWidth = 44;
  static const double tabletBreakpoint = 600;
  static const double _keyHeight = 120;
  static const double _labelHeight = 20;

  @override
  State<VirtualKeyboard> createState() => _VirtualKeyboardState();
}

class _VirtualKeyboardState extends State<VirtualKeyboard> {
  ScrollController? _own;
  ScrollController get _scroll => widget.controller ?? (_own ??= ScrollController());

  /// 最近一次布局的键宽，供八度跳转换算偏移。
  double _keyWidth = VirtualKeyboard.minKeyWidth;

  /// 滑动判定（与 _WhiteKey 同阈值）：按下不计时，抬手确认为滑动才算定位完成。
  final Map<int, Offset> _downs = {};
  final Set<int> _sliding = {};
  static const double _touchSlop = 18;

  void _pointerDown(PointerDownEvent e) {
    _downs[e.pointer] = e.position;
    _sliding.remove(e.pointer);
  }

  void _pointerMove(PointerMoveEvent e) {
    final start = _downs[e.pointer];
    if (start == null) return;
    if ((e.position - start).distance > _touchSlop) {
      _sliding.add(e.pointer);
      if (_sliding.length == 1) widget.onNavigateStart?.call();
    }
  }

  void _pointerEnd(PointerEvent e) {
    final wasSliding = _sliding.remove(e.pointer);
    _downs.remove(e.pointer);
    if (wasSliding && _sliding.isEmpty) widget.onNavigateEnd?.call();
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  Future<void> _jumpToOctave(int diatonicIndex) async {
    widget.onNavigateStart?.call();
    final c = _scroll;
    if (!c.hasClients) {
      widget.onNavigateEnd?.call();
      return;
    }
    final offset = ((diatonicIndex - widget.rangeMin) * _keyWidth)
        .clamp(0.0, c.position.maxScrollExtent);
    await c.animateTo(offset,
        duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    if (mounted) widget.onNavigateEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final keys = <NotePosition>[
      for (var i = widget.rangeMin; i <= widget.rangeMax; i++)
        NotePosition.of(i),
    ];
    // 八度跳转只列落在当前音域内的 C（默认 C3/C4/C5/C6，顺序不变）。
    final octaveChips = <int>[
      for (var i = widget.rangeMin; i <= widget.rangeMax; i++)
        if (mod(i, 7) == 0) i,
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;
      final tablet = available >= VirtualKeyboard.tabletBreakpoint;
      final keyWidth =
          tablet ? available / keys.length : VirtualKeyboard.minKeyWidth;
      _keyWidth = keyWidth;
      final row = Row(
        mainAxisSize: tablet ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final note in keys)
            SizedBox(
              width: keyWidth,
              child: _WhiteKey(
                key: ValueKey('key_${note.midi}'),
                note: note,
                enabled: widget.enabled,
                onAnswer: widget.onAnswer,
              ),
            ),
        ],
      );
      final keyboard = tablet
          ? row
          : SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: row);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!tablet)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in octaveChips)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _OctaveJumpChip(
                        key: ValueKey(
                            'octave_jump_${NotePosition.of(c).displayName}'),
                        label: NotePosition.of(c).displayName,
                        onTap: () => _jumpToOctave(c),
                      ),
                    ),
                ],
              ),
            ),
          Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerEnd,
            onPointerCancel: _pointerEnd,
            child: keyboard,
          ),
        ],
      );
    });
  }
}

/// 八度快捷跳转 chip：反馈/空屏期间也可点（提前定位下一题区域）。
class _OctaveJumpChip extends StatelessWidget {
  const _OctaveJumpChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class _WhiteKey extends StatefulWidget {
  const _WhiteKey({
    super.key,
    required this.note,
    required this.enabled,
    required this.onAnswer,
  });

  final NotePosition note;
  final bool enabled;
  final ValueChanged<int> onAnswer;

  @override
  State<_WhiteKey> createState() => _WhiteKeyState();
}

class _WhiteKeyState extends State<_WhiteKey> {
  bool _pressed = false;
  Offset? _downPos;
  bool _moved = false;

  /// 手指在键上按下：只做视觉高亮，不提交。
  /// 键盘可横向滚动（22 键超出屏宽），若按下即提交，用户滑动找音时会误答第一个碰到的键。
  void _down(PointerDownEvent event) {
    if (!widget.enabled) return;
    _downPos = event.position;
    _moved = false;
    setState(() => _pressed = true);
  }

  void _move(PointerMoveEvent event) {
    final start = _downPos;
    if (start == null) return;
    if ((event.position - start).distance > _touchSlop) _moved = true;
  }

  /// 抬手：位移小于触摸阈值才算"点选"，此时才提交（并播音）。
  void _up(PointerUpEvent event) {
    final submit = _pressed && !_moved && widget.enabled;
    setState(() => _pressed = false);
    _downPos = null;
    if (submit) widget.onAnswer(widget.note.midi);
  }

  /// 滚动/手势被父级接管时取消按压态，不提交。
  void _cancel(PointerEvent event) {
    if (_pressed) setState(() => _pressed = false);
    _downPos = null;
    _moved = false;
  }

  static const double _touchSlop = 18; // 与 kTouchSlop 同量级；超过即视为滑动

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
      background = scheme.surface;
      foreground = scheme.onSurfaceVariant;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _cancel,
          child: Container(
            height: VirtualKeyboard._keyHeight,
            alignment: Alignment.bottomCenter,
            padding: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: background,
              border: Border.all(color: scheme.outline),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(4)),
            ),
            child: Text(
              widget.note.pitchClass,
              style: TextStyle(fontSize: 11, color: foreground),
            ),
          ),
        ),
        SizedBox(
          height: VirtualKeyboard._labelHeight,
          child: widget.note.pitchClass == 'C'
              ? Center(
                  child: Text(
                    widget.note.displayName,
                    key: ValueKey('octave_label_${widget.note.displayName}'),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}
