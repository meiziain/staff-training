// 规格: 05 §0 坐标与基本函数 / 02 §1.1 音位池 / 04 note_position 种子。
// diatonicIndex: C4=0，自然音级计数（C3=-7 … C6=14）。
library;

import 'enums.dart';

const List<String> _pitchClasses = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const List<int> _semitones = [0, 2, 4, 5, 7, 9, 11];

/// 非负模（05 §0：mod 取非负）。
int mod(int a, int b) => ((a % b) + b) % b;

String pitchClassOf(int i) => _pitchClasses[mod(i, 7)];
// 规格: 05 §0 octave(i)=4+floor(i/7)。注意负数必须 floor（~/ 向零取整会错）。
int octaveOf(int i) => 4 + (i / 7).floor();
int midiOf(int i) => 60 + 12 * (i / 7).floor() + _semitones[mod(i, 7)];

/// 偶数=线，奇数=间（两谱表通用；C4=0 为加线）。
bool isLine(int i) => mod(i, 2) == 0;

/// 音位池 [-7..14] 共 22 个。
const int poolMin = -7;
const int poolMax = 14;
bool inPool(int i) => i >= poolMin && i <= poolMax;
Iterable<int> get pool => Iterable<int>.generate(poolMax - poolMin + 1, (k) => poolMin + k);

bool inTrebleRange(int i) => i >= 0 && i <= 14;
bool inBassRange(int i) => i >= -7 && i <= 0;
bool canClef(int i, Clef clef) =>
    clef == Clef.treble ? inTrebleRange(i) : inBassRange(i);

/// 加线音位（02 §1.1：C4/A5/C6；C4 在两谱表均为加线）。
bool isLedger(int i) => i == 0 || i == 12 || i == 14;

/// 静态音位（与 04 note_position 行对应）。
class NotePosition {
  final int diatonicIndex;
  final String displayName;
  final String pitchClass;
  final int octave;
  final int midi;
  final bool inTreble;
  final bool inBass;
  final bool ledgerTreble;
  final bool ledgerBass;

  const NotePosition({
    required this.diatonicIndex,
    required this.displayName,
    required this.pitchClass,
    required this.octave,
    required this.midi,
    required this.inTreble,
    required this.inBass,
    required this.ledgerTreble,
    required this.ledgerBass,
  });

  /// 由坐标构造（与 04 种子一致的推导口径）。
  factory NotePosition.of(int i) {
    final pc = pitchClassOf(i);
    final oct = octaveOf(i);
    return NotePosition(
      diatonicIndex: i,
      displayName: '$pc$oct',
      pitchClass: pc,
      octave: oct,
      midi: midiOf(i),
      inTreble: inTrebleRange(i),
      inBass: inBassRange(i),
      ledgerTreble: i == 0 || i == 12 || i == 14,
      ledgerBass: i == 0,
    );
  }

  bool get isLedger => ledgerTreble || ledgerBass;

  /// 该音位可用的谱表列表。
  List<Clef> get clefs => [
        if (inTreble) Clef.treble,
        if (inBass) Clef.bass,
      ];
}