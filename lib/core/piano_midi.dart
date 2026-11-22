// 规格: 02 §10.2 —— 蓝牙电钢琴（BLE-MIDI / USB-MIDI）输入接口。
// UI 层把设备按键转换为 AnswerEvent；规则层仍只消费 AnswerEvent，不感知输入源。
library;

/// 连接状态（UI 状态条 / 断连回退用）。
enum PianoConnectionState {
  disconnected,
  scanning,

  /// 扫描窗口结束且没有发现任何 BLE-MIDI 设备。
  scanTimedOut,
  connecting,
  connected,
  bluetoothOff,
  permissionDenied,
  error,
}

/// 连接方式。
enum PianoTransport { ble, usb, other }

/// 可连接的电钢琴设备。
class PianoDevice {
  const PianoDevice({
    required this.id,
    required this.name,
    required this.transport,
    this.profileId,
    this.profileLabel,
  });

  final String id;

  /// 设备广播名（如 "FP-18"）。
  final String name;
  final PianoTransport transport;

  /// 命中的型号档案（如 roland_fp18）；未知型号为 null。
  final String? profileId;
  final String? profileLabel;

  String get displayName => profileLabel ?? name;

  String get transportLabel => switch (transport) {
        PianoTransport.ble => '蓝牙',
        PianoTransport.usb => 'USB',
        PianoTransport.other => '其他',
      };
}

/// 一次按键（note-on，velocity > 0）。
class PianoNoteEvent {
  const PianoNoteEvent({
    required this.midiNote,
    required this.velocity,
    required this.deviceName,
  });

  /// MIDI 音高（C4 = 60）。
  final int midiNote;
  final int velocity;
  final String deviceName;
}

/// 电钢琴 MIDI 服务。生产实现见 data/piano_midi_command.dart。
abstract interface class PianoMidiService {
  /// 当前平台是否提供 MIDI 能力（桌面/测试环境的空实现为 false）。
  bool get isSupported;

  PianoConnectionState get connectionState;
  PianoDevice? get connectedDevice;
  List<PianoDevice> get devices;

  /// 最近一次失败原因（权限被拒、连接超时等）。
  String? get lastError;

  /// 插件诊断日志（扫描过滤、连接握手等），供设置页排查。
  List<String> get logLines;

  Stream<PianoConnectionState> get connectionStateChanges;
  Stream<List<PianoDevice>> get deviceChanges;
  Stream<PianoNoteEvent> get noteEvents;

  /// 初始化蓝牙并开始扫描（幂等）。失败时 [connectionState] 给出原因。
  Future<void> startScan();

  /// 停止扫描（保持已建立连接）。
  void stopScan();

  Future<void> connect(PianoDevice device);

  Future<void> disconnect();

  /// 重连最近一次成功连接的设备（会话中断连时用）。
  Future<void> reconnect();

  Future<void> dispose();
}

/// 未装配 / 测试环境：始终未连接，事件流为空。
class NoopPianoMidiService implements PianoMidiService {
  @override
  bool get isSupported => false;

  @override
  PianoConnectionState get connectionState => PianoConnectionState.disconnected;

  @override
  PianoDevice? get connectedDevice => null;

  @override
  List<PianoDevice> get devices => const [];

  @override
  String? get lastError => null;

  @override
  List<String> get logLines => const [];

  @override
  Stream<PianoConnectionState> get connectionStateChanges =>
      const Stream.empty();

  @override
  Stream<List<PianoDevice>> get deviceChanges => const Stream.empty();

  @override
  Stream<PianoNoteEvent> get noteEvents => const Stream.empty();

  @override
  Future<void> startScan() async {}

  @override
  void stopScan() {}

  @override
  Future<void> connect(PianoDevice device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> reconnect() async {}

  @override
  Future<void> dispose() async {}
}
