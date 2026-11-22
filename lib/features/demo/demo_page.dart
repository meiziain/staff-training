// 规格: 09 M2 退出标准 —— 演示页：呈现任意音位 → 两种模式作答 → 播音，事件字段完整。
// M2 验证脚手架；正式会话流程在 M3+ 接入（06 S3）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/rng.dart';
import '../../domain/models/answer_event.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/note_position.dart';
import '../../ui/answer_input.dart';
import '../../ui/name_buttons.dart';
import '../../ui/staff_view.dart';
import '../../ui/virtual_keyboard.dart';

class DemoPage extends ConsumerStatefulWidget {
  const DemoPage({super.key});

  @override
  ConsumerState<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends ConsumerState<DemoPage> {
  final Rng _rng = rng(7);
  int _target = 4; // G4
  int _jitterSeed = 1;
  InputMode _mode = InputMode.nameButtons;
  AnswerEvent? _lastEvent;
  int? _onsetMono;
  bool _audioReady = false;
  String? _audioError;

  @override
  void initState() {
    super.initState();
    _initAudio();
    _markOnset(); // 首题 onset（post-frame，03 §2）。
  }

  Future<void> _initAudio() async {
    try {
      await ref.read(audioServiceProvider).init();
      if (mounted) setState(() => _audioReady = true);
    } catch (e) {
      // 音频初始化失败静默降级（06 §6），视觉照常。
      if (mounted) setState(() => _audioError = '$e');
    }
  }

  void _nextNote() {
    setState(() {
      _target = poolMin + _rng.nextInt(poolMax - poolMin + 1);
      _jitterSeed = _rng.nextInt(1 << 30);
      _lastEvent = null;
      _onsetMono = null;
    });
    _markOnset();
  }

  /// post-frame 记录 onset（03 §2：不用按钮构建时间）。
  void _markOnset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _onsetMono = ref.read(clockProvider).monotonicMs();
      });
    });
  }

  Clef get _clef => canClef(_target, Clef.bass) && !canClef(_target, Clef.treble)
      ? Clef.bass
      : Clef.treble;

  Future<void> _onAnswer(AnswerEvent e) async {
    final clock = ref.read(clockProvider);
    final rt = _onsetMono == null ? 0 : clock.monotonicMs() - _onsetMono!;
    final event = AnswerEvent(
      itemId: 1000 + _target,
      pitchClass: e.pitchClass,
      octave: e.octave,
      rtMs: rt,
      source: e.source,
      timestamp: clock.nowUtcMs(),
    );
    setState(() => _lastEvent = event);

    final audio = ref.read(audioServiceProvider);
    final correctMidi = midiOf(_target);
    final answerIdx = _answerIndex(e.pitchClass);
    final isCorrect = e.pitchClass == pitchClassOf(_target) &&
        (_mode == InputMode.nameButtons || e.octave == octaveOf(_target));
    if (isCorrect) {
      await audio.playNote(correctMidi);
    } else {
      await audio.playComparison(
        answerMidi: midiOf(answerIdx),
        correctMidi: correctMidi,
      );
    }
  }

  /// 与 target 同八度区域内 pitchClass 匹配的最近音位（05 §5 口径）。
  int _answerIndex(String pc) {
    const pcs = 'CDEFGAB';
    final d0 = pcs.indexOf(pc) - mod(_target, 7);
    var d = d0;
    if (d > 3) d -= 7;
    if (d < -3) d += 7;
    return _target + d;
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('识谱训练 · M2 演示'),
        actions: [
          IconButton(
            icon: const Icon(Icons.shuffle),
            onPressed: _nextNote,
            tooltip: '随机音位',
          ),
        ],
      ),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('配置加载失败：$e')),
        data: (config) => _body(config),
      ),
    );
  }

  Widget _body(Config config) {
    final pos = NotePosition.of(_target);
    return Column(
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: StaffView(
              clef: _clef,
              positions: [_target],
              jitterSeed: _jitterSeed,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('目标：${pos.displayName}（${_clef == Clef.treble ? "高音" : "低音"}谱表）'),
              const Spacer(),
              SegmentedButton<InputMode>(
                segments: const [
                  ButtonSegment(
                      value: InputMode.nameButtons, label: Text('音名')),
                  ButtonSegment(
                      value: InputMode.virtualKey, label: Text('键盘')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_mode == InputMode.nameButtons)
          NameButtons(
            enabled: _onsetMono != null,
            onAnswer: (pc) => _onAnswer(buildNameButtonAnswer(
              itemId: 1000 + _target,
              pitchClass: pc,
              timestamp: 0,
            )),
          )
        else
          VirtualKeyboard(
            onAnswer: (midi) => _onAnswer(buildKeyAnswer(
              itemId: 1000 + _target,
              midi: midi,
              timestamp: 0,
            )),
          ),
        const SizedBox(height: 8),
        if (_audioError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('音频不可用（视觉照常）：$_audioError',
                style: const TextStyle(fontSize: 12)),
          ),
        if (_lastEvent != null)
          Container(
            width: double.infinity,
            color: const Color(0xFFF0F0EE),
            padding: const EdgeInsets.all(8),
            child: Text(
              'AnswerEvent: ${const JsonEncoder.withIndent("  ").convert({
                'itemId': _lastEvent!.itemId,
                'pitchClass': _lastEvent!.pitchClass,
                'octave': _lastEvent!.octave,
                'rtMs': _lastEvent!.rtMs,
                'source': _lastEvent!.source.wire,
                'hintUsed': _lastEvent!.hintUsed,
                'timestamp': _lastEvent!.timestamp,
              })}',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        if (!_audioReady && _audioError == null)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('音频预加载中…', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}