// 规格: 11 §2 §5 —— 谱面模型与曲目 JSON 往返。
import 'dart:convert';

import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_score.dart';

void main() {
  test('音域常量与声部映射', () {
    expect(sightBassMin, -14); // C2
    expect(sightBassMax, 0); // C4
    expect(sightTrebleMin, 0);
    expect(sightTrebleMax, 14); // C6
    expect(sightVoiceMin(SightVoice.upper), 0);
    expect(sightVoiceMax(SightVoice.lower), 0);
    expect(SightMode.trebleOnly.hasLower, false);
    expect(SightMode.bassOnly.hasUpper, false);
    expect(SightMode.grand.hasUpper && SightMode.grand.hasLower, true);
  });

  test('SightColumn.single 只填对应声部', () {
    final u = SightColumn.single(SightVoice.upper, 4);
    expect(u.upper, 4);
    expect(u.lower, isNull);
    final l = SightColumn.single(SightVoice.lower, -7);
    expect(l.upper, isNull);
    expect(l.lower, -7);
    expect(u.isEmpty, false);
    expect(const SightColumn().isEmpty, true);
  });

  test('inRange 校验上下声部各自音域', () {
    const ok = SightScore(mode: SightMode.grand, columns: [
      SightColumn(upper: 14, lower: -14),
      SightColumn(upper: 0, lower: 0),
    ]);
    expect(ok.inRange, true);
    const badUpper = SightScore(mode: SightMode.grand, columns: [
      SightColumn(upper: 15),
    ]);
    expect(badUpper.inRange, false);
    const badLower = SightScore(mode: SightMode.grand, columns: [
      SightColumn(lower: -15),
    ]);
    expect(badLower.inRange, false);
  });

  test('noteCount / noteCountOf / voiceAbsent', () {
    const s = SightScore(mode: SightMode.grand, columns: [
      SightColumn(upper: 2, lower: -5),
      SightColumn(upper: 4),
      SightColumn(lower: -7),
    ]);
    expect(s.noteCount, 4);
    expect(s.noteCountOf(SightVoice.upper), 2);
    expect(s.noteCountOf(SightVoice.lower), 2);
    expect(s.voiceAbsent(SightVoice.upper), false);
    expect(
      const SightScore(mode: SightMode.trebleOnly, columns: [
        SightColumn(upper: 2),
      ]).voiceAbsent(SightVoice.lower),
      true,
    );
  });

  test('内置曲目紧凑 JSON 往返', () {
    const raw = '''
    {"id":"sr_c_01","name":"C 大调练习","mode":"grand",
     "columns":[[0,-7],[2,-5],[4,null],[null,-7]]}
    ''';
    final score = SightScore.fromCompactJson(
        jsonDecode(raw) as Map<String, dynamic>);
    expect(score.mode, SightMode.grand);
    expect(score.scoreId, 'sr_c_01');
    expect(score.title, 'C 大调练习');
    expect(score.columnCount, 4);
    expect(score.columns[0], const SightColumn(upper: 0, lower: -7));
    expect(score.columns[3], const SightColumn(lower: -7));
    expect(score.inRange, true);
  });

  test('对象 JSON 往返保持等值', () {
    const s = SightScore(
      mode: SightMode.bassOnly,
      scoreId: 'x',
      title: 't',
      columns: [SightColumn(lower: -14), SightColumn(lower: -10)],
    );
    final round = SightScore.fromJsonObject(
        jsonDecode(jsonEncode(s.toJsonObject())) as Map<String, dynamic>);
    expect(round.mode, s.mode);
    expect(round.scoreId, s.scoreId);
    expect(round.columns, s.columns);
  });

  test('mode wire 往返', () {
    for (final m in SightMode.values) {
      expect(SightMode.fromWire(m.wire), m);
    }
    for (final v in SightVoice.values) {
      expect(SightVoice.fromWire(v.wire), v);
    }
  });
}
