// 规格: 02 §6.1 §8 / 04 —— 条目类型、状态、错误类型、输入源枚举。
library;

/// 谱表。
enum Clef {
  treble,
  bass;

  String get wire => name; // 'treble' / 'bass'（04 payload 口径）
  static Clef fromWire(String s) =>
      s == 'bass' ? Clef.bass : Clef.treble;
}

/// 条目类型（02 §6.1；PATTERN 二期）。
enum ItemType {
  anchor('ANCHOR'),
  relation('RELATION'),
  direct('DIRECT'),
  phrase('PHRASE');

  final String wire;
  const ItemType(this.wire);
  static ItemType fromWire(String s) =>
      ItemType.values.firstWhere((e) => e.wire == s);
}

/// 掌握度状态（04 mastery.state）。
enum ItemState {
  inactive,
  learning,
  reviewing,
  automated,
  relapsed;

  String get wire => name;
  static ItemState fromWire(String s) =>
      ItemState.values.firstWhere((e) => e.name == s);
}

/// 错误类型（05 §5 唯一优先级枚举）。
enum ErrorType {
  timeout('TIMEOUT'),
  octave('OCTAVE'),
  crossClef('CROSS_CLEF'),
  anchorError('ANCHOR_ERROR'),
  direction('DIRECTION'),
  lineSpace('LINE_SPACE'),
  distance('DISTANCE'),
  slowCorrect('SLOW_CORRECT'),
  other('OTHER');

  final String wire;
  const ErrorType(this.wire);
  static ErrorType fromWire(String s) =>
      ErrorType.values.firstWhere((e) => e.wire == s);
}

/// 输入源（02 §10.1）。规则层只消费 AnswerEvent，不得按此分支。
enum InputSource {
  nameButton('NAME_BUTTON'),
  virtualKey('VIRTUAL_KEY'),
  midi('MIDI');

  final String wire;
  const InputSource(this.wire);
  static InputSource fromWire(String s) =>
      InputSource.values.firstWhere((e) => e.wire == s);
}