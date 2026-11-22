// 规格: 02 §6.1 §8.2 / 04 item.payload JSON 口径 / 05 §1 条目生成。
library;

import 'dart:convert';

import 'enums.dart';

/// 条目 payload（sealed，按类型区分）。
sealed class ItemPayload {
  const ItemPayload();
  Map<String, dynamic> toJson();

  /// 条目涉及的目标音位（用于去重/晋升/回退关联）。
  /// ANCHOR/DIRECT=自身；RELATION=终点；PHRASE=全部音位。
  List<int> get targetIndices;

  static ItemPayload fromJson(ItemType type, Map<String, dynamic> j) =>
      switch (type) {
        ItemType.anchor =>
          AnchorPayload(diatonicIndex: j['diatonicIndex'] as int),
        ItemType.direct =>
          DirectPayload(diatonicIndex: j['diatonicIndex'] as int),
        ItemType.relation => j.containsKey('chain')
            ? RelationPayload.chain(
                (j['chain'] as List)
                    .map((e) => RelationStep.fromJson(e as Map<String, dynamic>))
                    .toList())
            : RelationPayload.single(
                anchorIndex: j['anchorIndex'] as int,
                direction: j['direction'] as int,
                steps: j['steps'] as int),
        ItemType.phrase => PhrasePayload(
            noteSequence:
                (j['noteSequence'] as List).map((e) => e as int).toList(),
            clefSequence: (j['clefSequence'] as List)
                .map((e) => Clef.fromWire(e as String))
                .toList()),
      };
}

class AnchorPayload extends ItemPayload {
  final int diatonicIndex;
  const AnchorPayload({required this.diatonicIndex});
  @override
  Map<String, dynamic> toJson() => {'diatonicIndex': diatonicIndex};
  @override
  List<int> get targetIndices => [diatonicIndex];
}

class DirectPayload extends ItemPayload {
  final int diatonicIndex;
  const DirectPayload({required this.diatonicIndex});
  @override
  Map<String, dynamic> toJson() => {'diatonicIndex': diatonicIndex};
  @override
  List<int> get targetIndices => [diatonicIndex];
}

/// 单步关系：{anchorIndex, direction(±1), steps(2=二度,3=三度)}。
/// 目标 = anchorIndex + direction * (steps - 1)。
class RelationStep {
  final int anchorIndex;
  final int direction;
  final int steps;
  const RelationStep({
    required this.anchorIndex,
    required this.direction,
    required this.steps,
  });
  int get targetIndex => anchorIndex + direction * (steps - 1);
  Map<String, dynamic> toJson() =>
      {'anchorIndex': anchorIndex, 'direction': direction, 'steps': steps};
  factory RelationStep.fromJson(Map<String, dynamic> j) => RelationStep(
        anchorIndex: j['anchorIndex'] as int,
        direction: j['direction'] as int,
        steps: j['steps'] as int,
      );
}

class RelationPayload extends ItemPayload {
  /// 单步为单元素链；两步推导为双元素链（05 §1 阶段3）。
  final List<RelationStep> chain;
  // 链非空由生成器保证（const 构造无法 assert .length）。
  const RelationPayload.chain(this.chain);
  RelationPayload.single({
    required int anchorIndex,
    required int direction,
    required int steps,
  }) : chain = [
          RelationStep(
              anchorIndex: anchorIndex, direction: direction, steps: steps)
        ];

  bool get isChain => chain.length > 1;
  RelationStep get first => chain.first;
  int get anchorIndex => chain.first.anchorIndex;
  int get targetIndex => chain.last.targetIndex;

  @override
  Map<String, dynamic> toJson() => chain.length == 1
      ? chain.first.toJson()
      : {'chain': chain.map((e) => e.toJson()).toList()};

  @override
  List<int> get targetIndices => [targetIndex];
}

class PhrasePayload extends ItemPayload {
  final List<int> noteSequence;
  final List<Clef> clefSequence;
  // 长度一致性由生成器保证（const 构造无法 assert .length）。
  const PhrasePayload({
    required this.noteSequence,
    required this.clefSequence,
  });

  @override
  Map<String, dynamic> toJson() => {
        'noteSequence': noteSequence,
        'clefSequence': clefSequence.map((e) => e.wire).toList(),
      };

  @override
  List<int> get targetIndices => noteSequence;
}

/// 条目（02 §8.2）。
class Item {
  final int id;
  final ItemType type;
  final ItemPayload payload;
  final int createdAt;

  const Item({
    required this.id,
    required this.type,
    required this.payload,
    required this.createdAt,
  });

  List<int> get targetIndices => payload.targetIndices;

  String payloadJson() => jsonEncode(payload.toJson());

  factory Item.fromRow(Map<String, Object?> row) {
    final type = ItemType.fromWire(row['type'] as String);
    return Item(
      id: row['id'] as int,
      type: type,
      payload: ItemPayload.fromJson(
          type, jsonDecode(row['payload'] as String) as Map<String, dynamic>),
      createdAt: row['created_at'] as int,
    );
  }
}