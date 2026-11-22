// 规格: 06 §2 S4/S5 展示口径 —— 条目 → 中文短标签（总结页、掌握地图共用）。
library;

import 'models/item.dart';
import 'models/note_position.dart';

String _stepName(int steps) => switch (steps) {
      2 => '二度',
      3 => '三度',
      _ => '$steps 度',
    };

/// 条目展示名：
/// ANCHOR → "锚点 C4"；DIRECT → "直认 G4"；
/// RELATION → "关系 C4↑二度"（链式逐段拼接）；
/// PHRASE → "短句 C4 D4 E4"。
String itemLabel(Item item) => switch (item.payload) {
      AnchorPayload p => '锚点 ${NotePosition.of(p.diatonicIndex).displayName}',
      DirectPayload p => '直认 ${NotePosition.of(p.diatonicIndex).displayName}',
      RelationPayload p => '关系 ${_relationLabel(p)}',
      PhrasePayload p => '短句 ${p.noteSequence.map(_name).join(' ')}',
    };

String _name(int diatonicIndex) => NotePosition.of(diatonicIndex).displayName;

String _relationLabel(RelationPayload p) {
  final buf = StringBuffer(_name(p.first.anchorIndex));
  for (final step in p.chain) {
    buf
      ..write(step.direction > 0 ? '↑' : '↓')
      ..write(_stepName(step.steps));
  }
  return buf.toString();
}
