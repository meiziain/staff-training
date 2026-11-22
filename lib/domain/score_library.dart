// 规格: 11 §5 —— 内置曲目解析。零 Flutter 依赖（asset 读取由 Widget 层用
// rootBundle 完成，domain 只处理字符串）。
//
// 曲目格式与 SightScore 同构（紧凑列数组）：
// {"id":"sr_treble_01","name":"...","mode":"trebleOnly","columns":[[0],[2]]}
library;

import 'dart:convert';

import 'models/sight_score.dart';

/// 内置曲目资源清单（与 assets/scores/ 一一对应）。
/// 放常量而非 index.json，避免「清单与文件内容两处维护」的漂移。
const List<String> builtinScoreAssetPaths = [
  'assets/scores/sr_treble_01.json',
  'assets/scores/sr_treble_02.json',
  'assets/scores/sr_bass_01.json',
  'assets/scores/sr_bass_02.json',
  'assets/scores/sr_grand_01.json',
  'assets/scores/sr_grand_02.json',
];

/// 解析单条曲目 JSON。任何格式问题都统一抛 [FormatException]，
/// 便于上层把「资源损坏」与「代码错误」区分开。
SightScore scoreFromJsonString(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    throw FormatException('曲目 JSON 不是合法 JSON：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('曲目 JSON 根节点必须是对象');
  }
  return _scoreFromMap(decoded);
}

/// 解析根为数组的曲目库 JSON。
List<SightScore> parseScoreLibrary(String rootJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rootJson);
  } on FormatException catch (e) {
    throw FormatException('曲目库 JSON 不是合法 JSON：${e.message}');
  }
  if (decoded is! List) {
    throw const FormatException('曲目库 JSON 根节点必须是数组');
  }
  final scores = <SightScore>[];
  for (var i = 0; i < decoded.length; i++) {
    final item = decoded[i];
    if (item is! Map<String, dynamic>) {
      throw FormatException('曲目库第 ${i + 1} 项不是对象');
    }
    try {
      scores.add(_scoreFromMap(item));
    } on FormatException catch (e) {
      throw FormatException('曲目库第 ${i + 1} 项解析失败：${e.message}');
    }
  }
  return scores;
}

SightScore _scoreFromMap(Map<String, dynamic> raw) {
  final mode = raw['mode'];
  if (mode is! String || !SightMode.values.any((m) => m.wire == mode)) {
    throw FormatException('曲目 mode 非法：$mode');
  }
  final columns = raw['columns'];
  if (columns is! List || columns.isEmpty) {
    throw const FormatException('曲目 columns 必须是非空数组');
  }
  try {
    return SightScore.fromCompactJson(raw);
  } on FormatException {
    rethrow;
  } catch (e) {
    // fromWire 的 StateError、类型转换的 TypeError 等统一收口。
    throw FormatException('曲目字段解析失败：$e');
  }
}
