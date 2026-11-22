// 规格: 11 §2 / 视奏训练改进 P0 T01 —— 视奏谱面模型。零 Flutter、零数据库依赖。
//
// 与掌握度体系的关系（11 §0 §7）：视奏只用 diatonicIndex 计算几何与音高，
// 不落 note_position / item / mastery。低音 C2–B2（-14..-8）7 个音位只在本
// 命名空间存在，不进入「22 音位池」，避免污染掌握地图与阶段进度。
//
// T01 扩展：列带 onsetBeat / durationBeats（0-based，>=1），谱面带 beatsPerBar /
// chunkRanges / motiveIds。旧 JSON（列 1–2 元素、map 无新键）全部兼容。
library;

import 'dart:math' as math;

/// 三种视奏模式（11 §1）。
enum SightMode {
  trebleOnly('trebleOnly'),
  bassOnly('bassOnly'),
  grand('grand');

  final String wire;
  const SightMode(this.wire);
  static SightMode fromWire(String s) =>
      SightMode.values.firstWhere((e) => e.wire == s);

  /// 是否有上声部（高音谱表）。
  bool get hasUpper => this != SightMode.bassOnly;

  /// 是否有下声部（低音谱表）。
  bool get hasLower => this != SightMode.trebleOnly;

  String get displayName => switch (this) {
        SightMode.trebleOnly => '右手 · 高音谱表',
        SightMode.bassOnly => '左手 · 低音谱表',
        SightMode.grand => '双手 · 大谱表',
      };
}

/// 声部。单手模式下只用 upper 或 lower 之一。
enum SightVoice {
  upper,
  lower;

  String get wire => name;
  static SightVoice fromWire(String s) =>
      SightVoice.values.firstWhere((e) => e.name == s);
}

/// 视奏音域（11 §1，diatonicIndex，C4=0）。
const int sightBassMin = -14; // C2
const int sightBassMax = 0; // C4
const int sightTrebleMin = 0; // C4
const int sightTrebleMax = 14; // C6
const int sightAllMin = sightBassMin;
const int sightAllMax = sightTrebleMax;

/// 某声部的音域下界（闭区间）。音域只由声部决定，与模式无关。
int sightVoiceMin(SightVoice voice) =>
    voice == SightVoice.upper ? sightTrebleMin : sightBassMin;

/// 某声部的音域上界（闭区间）。
int sightVoiceMax(SightVoice voice) =>
    voice == SightVoice.upper ? sightTrebleMax : sightBassMax;

/// 动机 id 的轻量别名：P0 直接用动机 wire。
typedef SightMotiveId = String;

/// 一段连续拍区间（P0 预留给分块视读，startBeat 含、endBeat 不含）。
class SightChunkRange {
  final int startBeat;
  final int endBeat;

  const SightChunkRange(this.startBeat, this.endBeat);

  List<int> toJson() => [startBeat, endBeat];

  factory SightChunkRange.fromJson(List<dynamic> raw) => SightChunkRange(
        (raw[0] as num).toInt(),
        (raw[1] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is SightChunkRange &&
      other.startBeat == startBeat &&
      other.endBeat == endBeat;

  @override
  int get hashCode => Object.hash(startBeat, endBeat);

  @override
  String toString() => 'SightChunkRange($startBeat,$endBeat)';
}

/// 一列：上/下声部各至多一个音，null 表示该声部此列休止（11 §2）。
class SightColumn {
  final int? upper;
  final int? lower;

  /// 本列音的起始拍（0-based）。旧谱例默认 0。
  final int onsetBeat;

  /// 本列音持续拍数（四分=1）。旧谱例默认 1，恒 >=1。
  final int durationBeats;

  const SightColumn({
    this.upper,
    this.lower,
    this.onsetBeat = 0,
    this.durationBeats = 1,
  }) : assert(durationBeats >= 1, 'durationBeats 必须 >=1');

  /// 单手模式便捷构造。
  SightColumn.single(
    SightVoice voice,
    int index, {
    this.onsetBeat = 0,
    this.durationBeats = 1,
  })  : upper = voice == SightVoice.upper ? index : null,
        lower = voice == SightVoice.lower ? index : null;

  bool get isEmpty => upper == null && lower == null;

  int? noteIn(SightVoice voice) =>
      voice == SightVoice.upper ? upper : lower;

  /// 兼容旧 1/2 元素格式（缺项默认 onset=0、duration=1）。
  factory SightColumn.fromJson(List<dynamic> raw) => SightColumn(
        upper: raw.isNotEmpty ? raw[0] as int? : null,
        lower: raw.length > 1 ? raw[1] as int? : null,
        onsetBeat: raw.length > 2 ? (raw[2] as num?)?.toInt() ?? 0 : 0,
        durationBeats: raw.length > 3 ? (raw[3] as num?)?.toInt() ?? 1 : 1,
      );

  /// 序列化为 `[upper, lower, onset, duration]`。
  List<int?> toJson() => [upper, lower, onsetBeat, durationBeats];

  Map<String, Object?> toJsonObject() => {
        'upper': upper,
        'lower': lower,
        'onsetBeat': onsetBeat,
        'durationBeats': durationBeats,
      };

  factory SightColumn.fromJsonObject(Map<String, dynamic> raw) => SightColumn(
        upper: raw['upper'] as int?,
        lower: raw['lower'] as int?,
        onsetBeat: (raw['onsetBeat'] as num?)?.toInt() ?? 0,
        durationBeats: (raw['durationBeats'] as num?)?.toInt() ?? 1,
      );

  @override
  bool operator ==(Object other) =>
      other is SightColumn &&
      other.upper == upper &&
      other.lower == lower &&
      other.onsetBeat == onsetBeat &&
      other.durationBeats == durationBeats;

  @override
  int get hashCode => Object.hash(upper, lower, onsetBeat, durationBeats);

  @override
  String toString() =>
      'SightColumn($upper,$lower,onset=$onsetBeat,dur=$durationBeats)';
}

/// 一条视奏谱例（11 §2）。
class SightScore {
  final SightMode mode;
  final List<SightColumn> columns;

  /// 内置曲目 id；生成练习为 null。
  final String? scoreId;
  final String? title;

  /// 每小节拍数（默认 4）。
  final int beatsPerBar;

  /// 分块视读区间（P0 预留，默认空）。
  final List<SightChunkRange> chunkRanges;

  /// 使用的动机 id 序列（legacy 谱例为 null）。
  final List<SightMotiveId>? motiveIds;

  const SightScore({
    required this.mode,
    required this.columns,
    this.scoreId,
    this.title,
    this.beatsPerBar = 4,
    this.chunkRanges = const <SightChunkRange>[],
    this.motiveIds,
  });

  int get columnCount => columns.length;

  /// 全谱拍数：max(onsetBeat + durationBeats)，空谱为 0。
  int get beatCount => columns.isEmpty
      ? 0
      : columns.map((c) => c.onsetBeat + c.durationBeats).reduce(math.max);

  /// 全谱音数（上下声部合计）。
  int get noteCount =>
      columns.fold(0, (s, c) => s + (c.upper != null ? 1 : 0) + (c.lower != null ? 1 : 0));

  /// 某声部的音数。
  int noteCountOf(SightVoice voice) =>
      columns.where((c) => c.noteIn(voice) != null).length;

  /// 某声部是否完全不参与（该声部全为休止）。
  bool voiceAbsent(SightVoice voice) => noteCountOf(voice) == 0;

  /// 逐列音位序列（供去重与测试断言）。
  List<int?> sequenceOf(SightVoice voice) =>
      columns.map((c) => c.noteIn(voice)).toList();

  /// 音域校验：所有音位在对应声部音域内。
  bool get inRange {
    for (final c in columns) {
      final u = c.upper;
      if (u != null && (u < sightTrebleMin || u > sightTrebleMax)) return false;
      final l = c.lower;
      if (l != null && (l < sightBassMin || l > sightBassMax)) return false;
    }
    return true;
  }

  Map<String, Object?> toJsonObject() => {
        'mode': mode.wire,
        'scoreId': scoreId,
        'title': title,
        'beatsPerBar': beatsPerBar,
        'chunkRanges': [for (final r in chunkRanges) r.toJson()],
        if (motiveIds != null) 'motiveIds': motiveIds,
        'columns': [for (final c in columns) c.toJsonObject()],
      };

  factory SightScore.fromJsonObject(Map<String, dynamic> raw) => SightScore(
        mode: SightMode.fromWire(raw['mode'] as String),
        scoreId: raw['scoreId'] as String?,
        title: raw['title'] as String?,
        beatsPerBar: (raw['beatsPerBar'] as num?)?.toInt() ?? 4,
        chunkRanges: [
          for (final r in (raw['chunkRanges'] as List?) ?? const <dynamic>[])
            SightChunkRange.fromJson((r as List).cast<dynamic>()),
        ],
        motiveIds: (raw['motiveIds'] as List?)?.map((e) => e as String).toList(),
        columns: [
          for (final c in (raw['columns'] as List))
            SightColumn.fromJsonObject(c as Map<String, dynamic>),
        ],
      );

  /// 内置曲目紧凑格式：`[[0],[2],[-7,4]]`（11 §5）。
  ///
  /// 单手曲目的列一律写成单元素（如 `[[0],[2]]` / `[[-7],[-6]]`）：单元素
  /// 列按 mode 归位——trebleOnly 记上声部、bassOnly 记下声部。方向判断放在
  /// 这里而不是 [SightColumn.fromJson]（后者不知道模式，只能默认 upper）。
  factory SightScore.fromCompactJson(Map<String, dynamic> raw) {
    final mode = SightMode.fromWire(raw['mode'] as String);
    return SightScore(
      mode: mode,
      scoreId: raw['id'] as String?,
      title: raw['name'] as String?,
      beatsPerBar: (raw['beatsPerBar'] as num?)?.toInt() ?? 4,
      columns: [
        for (final c in (raw['columns'] as List))
          _columnFromCompact(mode, (c as List).cast<dynamic>()),
      ],
    );
  }

  static SightColumn _columnFromCompact(SightMode mode, List<dynamic> raw) {
    if (mode != SightMode.grand && raw.length == 1) {
      final index = raw[0] as int?;
      return mode == SightMode.bassOnly
          ? SightColumn(lower: index)
          : SightColumn(upper: index);
    }
    return SightColumn.fromJson(raw);
  }
}
