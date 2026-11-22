// 规格: 02 §10.2 / 03 §3 —— 重依赖隔离：flutter_midi_command（BLE-MIDI + 系统 MIDI）。
// 仅本文件与 production_providers 引用插件；UI 只依赖 core/piano_midi.dart。
library;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

import '../core/piano_midi.dart';
import '../domain/piano_profile.dart';

class MidiCommandPianoService implements PianoMidiService {
  MidiCommandPianoService() : _midi = MidiCommand();

  final MidiCommand _midi;
  final StreamController<PianoConnectionState> _stateCtrl =
      StreamController<PianoConnectionState>.broadcast();
  final StreamController<List<PianoDevice>> _deviceCtrl =
      StreamController<List<PianoDevice>>.broadcast();
  final StreamController<PianoNoteEvent> _noteCtrl =
      StreamController<PianoNoteEvent>.broadcast();

  PianoConnectionState _state = PianoConnectionState.disconnected;
  PianoDevice? _connected;
  PianoDevice? _lastDevice;
  List<PianoDevice> _devices = const [];
  String? _lastError;
  bool _started = false;
  bool _wantScan = false;
  bool _disposed = false;
  Timer? _scanTimeout;
  Timer? _scanPoll;
  final List<String> _logLines = [];
  int _lastLoggedDeviceCount = -1;

  static const Duration _scanWindow = Duration(seconds: 20);
  static const Duration _scanPollInterval = Duration(milliseconds: 1500);

  StreamSubscription<MidiSetupChange>? _setupSub;
  StreamSubscription<MidiDataReceivedEvent>? _rxSub;
  StreamSubscription<BluetoothState>? _btSub;

  @override
  bool get isSupported => true;

  @override
  PianoConnectionState get connectionState => _state;

  @override
  PianoDevice? get connectedDevice => _connected;

  @override
  List<PianoDevice> get devices => _devices;

  @override
  String? get lastError => _lastError;

  @override
  List<String> get logLines => List.unmodifiable(_logLines);

  void _log(String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _logLines.add('[$ts] $message');
    if (_logLines.length > 40) _logLines.removeAt(0);
  }

  @override
  Stream<PianoConnectionState> get connectionStateChanges =>
      _stateCtrl.stream;

  @override
  Stream<List<PianoDevice>> get deviceChanges => _deviceCtrl.stream;

  @override
  Stream<PianoNoteEvent> get noteEvents => _noteCtrl.stream;

  Future<void> _ensureStarted() async {
    if (_started || _disposed) return;
    // 配置 BLE 传输必须早于读取事件流（插件 1.x 约定）。
    final transport = UniversalBleMidiTransport()..logHandler = _log;
    _midi.logHandler = _log;
    _midi.configureBleTransport(transport);
    _log('BLE MIDI transport configured');
    _setupSub = _midi.onMidiSetupChanged?.listen((_) {
      unawaited(_refreshDevices());
    });
    _rxSub = _midi.onMidiDataReceived?.listen(_onMidiReceived);
    _btSub = _midi.onBluetoothStateChanged.listen(_onBluetoothState);
    await _midi.startBluetooth();
    await _midi.waitUntilBluetoothIsInitialized();
    _started = true;
  }

  void _onBluetoothState(BluetoothState bt) {
    _log('bluetooth state: ${bt.name}');
    switch (bt) {
      case BluetoothState.poweredOn:
        if (_state == PianoConnectionState.bluetoothOff ||
            _state == PianoConnectionState.permissionDenied) {
          _setState(_connected != null
              ? PianoConnectionState.connected
              : PianoConnectionState.disconnected);
        }
        if (_wantScan && _connected == null) {
          unawaited(_resumeScan());
        }
      case BluetoothState.poweredOff:
        _setState(PianoConnectionState.bluetoothOff);
      case BluetoothState.unauthorized:
        _lastError = '蓝牙权限被拒绝';
        _setState(PianoConnectionState.permissionDenied);
      default:
        break;
    }
  }

  void _onMidiReceived(MidiDataReceivedEvent event) {
    final msg = event.message;
    // 力度忽略（02 §10.2）；note-on velocity 0 视作 note-off。
    if (msg is! NoteOnMessage || msg.velocity <= 0) return;
    if (msg.note < 0 || msg.note > 127) return;
    _noteCtrl.add(PianoNoteEvent(
      midiNote: msg.note,
      velocity: msg.velocity,
      deviceName: _connected?.displayName ?? event.device.name,
    ));
  }

  Future<void> _resumeScan() async {
    if (_disposed || !_started) return;
    try {
      await _midi.startScanningForBluetoothDevices();
      await _refreshDevices();
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Future<void> startScan() async {
    _wantScan = true;
    _lastError = null;
    _cancelScanTimers();
    try {
      await _ensureStarted();
      _log('startScan: bt=${_midi.bluetoothState.name}');
      if (_midi.bluetoothState == BluetoothState.unauthorized) {
        _lastError = '蓝牙权限被拒绝';
        _setState(PianoConnectionState.permissionDenied);
        return;
      }
      if (_midi.bluetoothState != BluetoothState.poweredOn) {
        _setState(PianoConnectionState.bluetoothOff);
        return;
      }
      _setState(PianoConnectionState.scanning);
      await _midi.startScanningForBluetoothDevices();
      await _refreshDevices();
      _scanPoll = Timer.periodic(
          _scanPollInterval, (_) => unawaited(_refreshDevices()));
      _scanTimeout = Timer(_scanWindow, _onScanWindowElapsed);
    } catch (e) {
      _fail(e);
    }
  }

  /// 扫描窗口结束：停止扫描；零结果时给 UI 一个明确的终态。
  void _onScanWindowElapsed() {
    _log('scan window elapsed: ${_devices.length} device(s)');
    stopScan();
    if (_connected == null && _devices.isEmpty) {
      _setState(PianoConnectionState.scanTimedOut);
    }
  }

  void _cancelScanTimers() {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    _scanPoll?.cancel();
    _scanPoll = null;
  }

  @override
  void stopScan() {
    _wantScan = false;
    _cancelScanTimers();
    if (!_started) return;
    _log('stopScan');
    _midi.stopScanningForBluetoothDevices();
    if (_state == PianoConnectionState.scanning) {
      _setState(_connected != null
          ? PianoConnectionState.connected
          : PianoConnectionState.disconnected);
    }
  }

  @override
  Future<void> connect(PianoDevice device) async {
    _lastError = null;
    try {
      await _ensureStarted();
      final raw = await _midi.devices ?? const <MidiDevice>[];
      final target = _rawById(raw, device.id);
      if (target == null) {
        _lastError = '设备已不可见，请重新扫描';
        _setState(PianoConnectionState.error);
        return;
      }
      _setState(PianoConnectionState.connecting);
      await _midi.connectToDevice(target);
      _connected = _asPianoDevice(target) ?? device;
      _lastDevice = _connected;
      _log('connected: ${_connected!.name}');
      _setState(PianoConnectionState.connected);
    } catch (e) {
      _connected = null;
      _fail(e);
    }
  }

  @override
  Future<void> disconnect() async {
    final raw = await _midi.devices ?? const <MidiDevice>[];
    final current = _connected;
    if (current != null) {
      final target = _rawById(raw, current.id);
      if (target != null) _midi.disconnectDevice(target);
    }
    _connected = null;
    _setState(PianoConnectionState.disconnected);
  }

  @override
  Future<void> reconnect() async {
    final last = _lastDevice ?? _connected;
    if (last == null) {
      await startScan();
      return;
    }
    try {
      await _ensureStarted();
      var raw = await _midi.devices ?? const <MidiDevice>[];
      var target = _rawById(raw, last.id);
      if (target == null) {
        if (_midi.bluetoothState != BluetoothState.poweredOn) {
          _setState(PianoConnectionState.bluetoothOff);
          return;
        }
        await _midi.startScanningForBluetoothDevices();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        raw = await _midi.devices ?? const <MidiDevice>[];
        target = _rawById(raw, last.id);
      }
      if (target == null) {
        _lastError = '未找到上次连接的电钢琴，请重新扫描';
        _setState(PianoConnectionState.error);
        return;
      }
      await connect(_asPianoDevice(target) ?? last);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _refreshDevices() async {
    if (_disposed || !_started) return;
    try {
      final raw = await _midi.devices ?? const <MidiDevice>[];
      final list = raw
          .map(_asPianoDevice)
          .whereType<PianoDevice>()
          .toList()
        ..sort((a, b) {
          final byTransport = a.transport.index.compareTo(b.transport.index);
          return byTransport != 0 ? byTransport : a.name.compareTo(b.name);
        });
      _devices = list;
      _deviceCtrl.add(list);
      if (list.length != _lastLoggedDeviceCount) {
        _lastLoggedDeviceCount = list.length;
        _log('visible MIDI devices: ${list.length}'
            '${list.isEmpty ? '' : ' (${list.map((d) => d.name).join(', ')})'}');
      }
      // 已连接设备消失（关机/走远）→ 标记断连，由 UI 回退屏幕键盘。
      final current = _connected;
      if (current != null) {
        final still = _rawById(raw, current.id);
        if (still == null || !still.connected) {
          _connected = null;
          _setState(PianoConnectionState.disconnected);
        }
      }
    } catch (e) {
      _fail(e);
    }
  }

  MidiDevice? _rawById(List<MidiDevice> raw, String id) {
    for (final d in raw) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 虚拟设备（本应用创建的端口）不列入可连接设备。
  PianoDevice? _asPianoDevice(MidiDevice d) {
    if (d.type == MidiDeviceType.virtual ||
        d.type == MidiDeviceType.ownVirtual) {
      return null;
    }
    final profile = matchPianoProfile(d.name);
    return PianoDevice(
      id: d.id,
      name: d.name,
      transport: switch (d.type) {
        MidiDeviceType.ble => PianoTransport.ble,
        MidiDeviceType.serial => PianoTransport.usb,
        _ => PianoTransport.other,
      },
      profileId: profile?.id,
      profileLabel: profile?.displayName,
    );
  }

  void _setState(PianoConnectionState next) {
    if (_disposed) return;
    _state = next;
    _stateCtrl.add(next);
  }

  void _fail(Object error) {
    _log('error: $error');
    _lastError = switch (error) {
      PlatformException(code: final code) when code.toLowerCase().contains(
          'permission') =>
        '蓝牙权限被拒绝',
      _ => '$error',
    };
    _setState(_lastError == '蓝牙权限被拒绝'
        ? PianoConnectionState.permissionDenied
        : PianoConnectionState.error);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantScan = false;
    _cancelScanTimers();
    if (_started) {
      _midi.stopScanningForBluetoothDevices();
      _midi.teardown();
    }
    await _setupSub?.cancel();
    await _rxSub?.cancel();
    await _btSub?.cancel();
    _midi.dispose();
    await _stateCtrl.close();
    await _deviceCtrl.close();
    await _noteCtrl.close();
  }
}
