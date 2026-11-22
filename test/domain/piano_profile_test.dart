// 规格: 02 §10.2 —— 型号档案匹配（Roland FP-18 广播名族）。
import 'package:test/test.dart';

import 'package:sight_reading/domain/piano_profile.dart';

void main() {
  test('FP-18 常见广播名命中 roland_fp18', () {
    for (final name in ['FP-18', 'FP18', 'Roland FP-18', 'Roland FP18', 'fp-18 MIDI']) {
      expect(matchPianoProfile(name)?.id, 'roland_fp18', reason: name);
    }
  });

  test('未知型号与近似名不误判', () {
    expect(matchPianoProfile('FP-30X'), isNull);
    expect(matchPianoProfile('Piano'), isNull);
    expect(matchPianoProfile('FP-180'), isNull);
  });

  test('FP-18 档案为 88 键、忽略力度', () {
    expect(rolandFp18.minMidiNote, 21);
    expect(rolandFp18.maxMidiNote, 108);
    expect(rolandFp18.ignoresVelocity, isTrue);
  });
}
