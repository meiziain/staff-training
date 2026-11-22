// 规格: 02 §10.2 —— 电钢琴型号档案。
// 型号差异只体现在传输方式与广播名；MIDI 音符编号统一 C4=60，力度忽略。
library;

/// 已知型号档案。新增型号时只需追加一条登记。
class PianoProfile {
  const PianoProfile({
    required this.id,
    required this.displayName,
    required this.namePatterns,
    this.minMidiNote = 21,
    this.maxMidiNote = 108,
    this.ignoresVelocity = true,
  });

  final String id;
  final String displayName;

  /// 广播名匹配正则（大小写不敏感）。FP-18 同时兼容 "FP-18" / "FP18"。
  final List<String> namePatterns;

  /// 88 键 A0..C8。
  final int minMidiNote;
  final int maxMidiNote;
  final bool ignoresVelocity;
}

/// Roland FP-18：Bluetooth 4.0 MIDI（BLE-MIDI）+ USB MIDI，无蓝牙音频。
const PianoProfile rolandFp18 = PianoProfile(
  id: 'roland_fp18',
  displayName: 'Roland FP-18',
  namePatterns: [r'\bfp-?18(?!\d)'],
);

const List<PianoProfile> knownPianoProfiles = [rolandFp18];

/// 按广播名匹配型号档案；未知型号返回 null（按通用 MIDI 设备处理）。
PianoProfile? matchPianoProfile(String deviceName) {
  for (final profile in knownPianoProfiles) {
    for (final pattern in profile.namePatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(deviceName)) {
        return profile;
      }
    }
  }
  return null;
}
