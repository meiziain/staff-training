// 规格: 02 §10.1 统一作答事件。规则层只消费本事件，不感知输入源。
library;

import 'enums.dart';

/// 所有输入源（音名按钮/虚拟键盘/未来 MIDI）产出的同一事件。
class AnswerEvent {
  final int itemId;
  final String pitchClass; // C D E F G A B
  final int? octave; // 键盘/MIDI 才有；音名按钮为 null
  final int? midi; // 电钢琴原始音高（对比音播放用；音名/虚拟键盘为 null）
  final int rtMs;
  final InputSource source;
  final int hintUsed; // 实际使用的提示层级 0..5
  final bool hintRequested; // 是否主动请求（02 §3.4）
  final int timestamp; // UTC ms

  const AnswerEvent({
    required this.itemId,
    required this.pitchClass,
    this.octave,
    this.midi,
    required this.rtMs,
    required this.source,
    this.hintUsed = 0,
    this.hintRequested = false,
    required this.timestamp,
  });
}