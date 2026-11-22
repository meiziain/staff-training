// 规格: 02 §10.1 统一作答事件 / §10.2 MIDI 映射预留；03 §2 规则2。
// UI 层唯一 AnswerEvent 构造点；规则层只消费事件，不感知输入源。
library;

import '../domain/models/answer_event.dart';
import '../domain/models/enums.dart';

const List<String> _pitchClasses = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const List<String> _midiNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'
];
const Map<int, int> _naturalSemitoneIndex = {
  0: 0,
  2: 1,
  4: 2,
  5: 3,
  7: 4,
  9: 5,
  11: 6,
};

/// MIDI → {pitchClass, octave} 映射（02 §10.2 预留，二期 MIDI 接入复用）。
/// 约定：中央 C = MIDI 60 = C4，octave = midi ~/ 12 - 1。
/// MVP 仅自然音（无变音）；变音键抛 ArgumentError。不实现任何蓝牙代码。
({String pitchClass, int octave}) midiToPitchClassOctave(int midi) {
  final index = _naturalSemitoneIndex[midi % 12];
  if (index == null) {
    throw ArgumentError.value(midi, 'midi', 'MVP 仅支持自然音（无变音）');
  }
  return (pitchClass: _pitchClasses[index], octave: midi ~/ 12 - 1);
}

/// 音名按钮作答事件：octave 恒为 null（02 §1.3 八度不在此模式考察）。
/// rtMs 为 0 占位——RT 由会话引擎用单调钟重算（02 §9 计时精度）。
AnswerEvent buildNameButtonAnswer({
  required int itemId,
  required String pitchClass,
  int hintUsed = 0,
  bool hintRequested = false,
  required int timestamp,
}) {
  return AnswerEvent(
    itemId: itemId,
    pitchClass: pitchClass,
    octave: null,
    rtMs: 0,
    source: InputSource.nameButton,
    hintUsed: hintUsed,
    hintRequested: hintRequested,
    timestamp: timestamp,
  );
}

/// 电钢琴作答事件（02 §10.2）：力度忽略，只取 note-on。
/// 黑键返回升号音名（如 C#），因此绝不会与自然音目标判为相同；
/// 原始 [midi] 随事件携带，用于答错时播放真实按下的键。
AnswerEvent buildPianoAnswer({
  required int itemId,
  required int midi,
  int hintUsed = 0,
  bool hintRequested = false,
  required int timestamp,
}) {
  if (midi < 0 || midi > 127) {
    throw ArgumentError.value(midi, 'midi', 'MIDI note 超出 0..127');
  }
  return AnswerEvent(
    itemId: itemId,
    pitchClass: _midiNames[midi % 12],
    octave: midi ~/ 12 - 1, // C4 = 60
    midi: midi,
    rtMs: 0,
    source: InputSource.midi,
    hintUsed: hintUsed,
    hintRequested: hintRequested,
    timestamp: timestamp,
  );
}

/// 虚拟键盘作答事件：pitchClass/octave 由 midi 反查（含八度，02 §1.3）。
/// rtMs 为 0 占位——RT 由会话引擎用单调钟重算。
AnswerEvent buildKeyAnswer({
  required int itemId,
  required int midi,
  int hintUsed = 0,
  bool hintRequested = false,
  required int timestamp,
}) {
  final mapped = midiToPitchClassOctave(midi);
  return AnswerEvent(
    itemId: itemId,
    pitchClass: mapped.pitchClass,
    octave: mapped.octave,
    rtMs: 0,
    source: InputSource.virtualKey,
    hintUsed: hintUsed,
    hintRequested: hintRequested,
    timestamp: timestamp,
  );
}