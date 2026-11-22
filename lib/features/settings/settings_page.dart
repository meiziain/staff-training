// 规格: 06 §2 S6 / 02 §8.6 §8.7 —— 设置页（偏好、备份、重置、关于）。
//
// 裁决记录（MVP）:
// 1) 作答模式会话内不可切换（02 §1.3 反应时口径一致），设置项常驻可改，
//    说明文字标注"会话中不可切换"，不额外禁用（设置页本身不在会话内）。
// 2) 音频开关同步写 settings.audio_enabled 并立即作用于 AudioService.muted。
// 3) 导入为覆盖式（02 §8.7）：文件选择后必须二次确认；BackupException
//    原文提示，importBackupJson 内部先校验后写，失败时原数据不动。
// 4) 重置清空 trial_log/phrase/mastery/session/confusion_seed/item/app_state，
//    保留 settings 与 note_position（静态音位表 + 用户偏好不属进度）。
// 5) 版本号取 pubspec.yaml（version 1.0.0+1），MVP 不引 package_info_plus。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart'
    show AssetManifest, Clipboard, ClipboardData, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/piano_midi.dart';
import '../../core/providers.dart';
import '../../data/backup.dart';
import '../../data/backup_io.dart';
import '../../data/playground.dart';
import '../../data/repositories/settings_repo.dart';
import '../session/session_page.dart';

/// 重置需清空的表（子表优先，保留 settings / note_position）。
const List<String> _resetTables = [
  'trial_log',
  'phrase',
  'mastery',
  'confusion_seed',
  'session',
  'item',
  'app_state',
];

const String _appVersion = 'v1.0.0';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.io});

  /// 测试注入假实现；生产走 PlatformBackupIo。
  final BackupIo? io;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;
  late Future<List<String>> _licenseNames;

  BackupIo get _io => widget.io ?? const PlatformBackupIo();

  @override
  void initState() {
    super.initState();
    _licenseNames = _loadLicenseNames();
  }

  Future<List<String>> _loadLicenseNames() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final names =
          manifest
              .listAssets()
              .where((p) => p.startsWith('assets/licenses/'))
              .map((p) => p.split('/').last)
              .toList()
            ..sort();
      return names;
    } catch (_) {
      // 测试/无资源包环境：回退到"见应用内许可页"文案。
      return const [];
    }
  }

  Future<void> _set(String key, String value) async {
    final db = await ref.read(databaseProvider.future);
    await SettingsRepo(db).set(key, value);
    if (key == 'audio_enabled') {
      ref.read(audioServiceProvider).muted = value != '1';
    }
    ref.invalidate(configProvider);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final db = await ref.read(databaseProvider.future);
      final backup = await exportBackup(db, clock: ref.read(clockProvider));
      final json = jsonEncode(backup);
      final date = ref.read(clockProvider).localDate();
      final stamp =
          '${date.year}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';
      await _io.shareJson('sight_reading_backup_$stamp.json', json);
      _snack('备份已生成，请选择保存位置');
    } catch (e) {
      _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    String? source;
    try {
      source = await _io.pickJson();
    } catch (e) {
      _snack('读取文件失败：$e');
      return;
    }
    if (source == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text(
          '导入为覆盖式：当前全部训练记录将被备份文件替换，'
          '且不可撤销。确定继续？',
        ),
        actions: [
          TextButton(
            key: const Key('import_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('import_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final db = await ref.read(databaseProvider.future);
      await importBackupJson(db, source);
      ref.invalidate(configProvider);
      _snack('导入成功，数据已覆盖');
    } on BackupException catch (e) {
      _snack('导入失败：${e.message}（原有数据未改变）');
    } catch (e) {
      _snack('导入失败：$e（原有数据未改变）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 试玩：在内存库上构建目标阶段的会话，完全不触碰正式进度数据
  /// （交付报告「实现偏差」#19）。退出即销毁内存库。
  Future<void> _openPlayground(int stage) async {
    setState(() => _busy = true);
    PlaygroundSession? session;
    try {
      final factory = ref.read(databaseFactoryProvider);
      final cfg = ref.read(configProvider).value ?? Config.defaults;
      session = await buildPlaygroundSession(
        factory: factory,
        config: cfg,
        clock: ref.read(clockProvider),
        stage: stage,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SessionPage(bundle: session!.bundle, dbOverride: session.db),
      ));
    } catch (e) {
      _snack('试玩启动失败：$e');
    } finally {
      try {
        await session?.dispose();
      } catch (_) {
        // 会话内已 close 过则忽略。
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _ResetDialog(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final db = await ref.read(databaseProvider.future);
      await db.transaction((txn) async {
        for (final table in _resetTables) {
          await txn.delete(table);
        }
      });
      ref.invalidate(configProvider);
      _snack('已重置，下次启动重新诊断');
    } catch (e) {
      _snack('重置失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configAsync = ref.watch(configProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('配置读取失败：$e')),
        data: (config) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _sectionTitle(theme, '练习'),
            _countSection(theme, config),
            _modeSection(theme, config),
            SwitchListTile(
              key: const Key('audio_switch'),
              title: const Text('答题音效'),
              subtitle: const Text('静音不影响视觉反馈'),
              value: config.audioEnabled,
              onChanged: (v) => _set('audio_enabled', v ? '1' : '0'),
            ),
            SwitchListTile(
              key: const Key('relaxed_switch'),
              title: const Text('限时宽松模式'),
              subtitle: const Text('所有时限 ×1.5（降低速度压力）'),
              value: config.relaxedTiming,
              onChanged: (v) => _set('relaxed_timing', v ? '1' : '0'),
            ),
            const Divider(),
            _sectionTitle(theme, '蓝牙电钢琴'),
            const _PianoMidiSection(),
            const Divider(),
            _sectionTitle(theme, '试玩（不影响训练进度）'),
            ListTile(
              key: const Key('playground_short_phrase'),
              title: const Text('试玩：3 音短句'),
              subtitle: const Text('阶段 4 内容 · 逐音作答 + 整句连播'),
              trailing: const Icon(Icons.play_circle_outline),
              enabled: !_busy,
              onTap: () => _openPlayground(4),
            ),
            ListTile(
              key: const Key('playground_cross_clef'),
              title: const Text('试玩：跨谱表短句'),
              subtitle: const Text('阶段 5 内容 · 4–5 音，含高低音谱表切换'),
              trailing: const Icon(Icons.play_circle_outline),
              enabled: !_busy,
              onTap: () => _openPlayground(5),
            ),
            const Divider(),
            _sectionTitle(theme, '数据'),
            ListTile(
              key: const Key('export_btn'),
              title: const Text('导出备份'),
              subtitle: const Text('生成 JSON 并通过系统分享保存'),
              trailing: const Icon(Icons.ios_share),
              enabled: !_busy,
              onTap: _export,
            ),
            ListTile(
              key: const Key('import_btn'),
              title: const Text('导入备份'),
              subtitle: const Text('从 JSON 文件恢复（覆盖当前数据）'),
              trailing: const Icon(Icons.file_open_outlined),
              enabled: !_busy,
              onTap: _import,
            ),
            ListTile(
              key: const Key('reset_btn'),
              title: const Text('重置进度'),
              subtitle: const Text('清空训练记录，保留设置；下次启动重新诊断'),
              trailing: const Icon(Icons.restart_alt),
              enabled: !_busy,
              onTap: _reset,
            ),
            const Divider(),
            _sectionTitle(theme, '关于'),
            const ListTile(
              key: Key('about_version'),
              title: Text('版本'),
              trailing: Text(_appVersion),
            ),
            _licenseTile(theme),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.primary,
      ),
    ),
  );

  Widget _countSection(ThemeData theme, Config config) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每日题量', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final n in [20, 40, 60])
                ChoiceChip(
                  key: Key('daily_$n'),
                  label: Text('$n 题'),
                  selected: config.dailyCount == n,
                  onSelected: (_) => _set('daily_count', '$n'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeSection(ThemeData theme, Config config) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('作答模式', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const Key('mode_names'),
                label: const Text('音名按钮'),
                selected: config.inputMode == InputMode.nameButtons,
                onSelected: (_) => _set('input_mode', 'name_buttons'),
              ),
              ChoiceChip(
                key: const Key('mode_keyboards'),
                label: const Text('虚拟键盘'),
                selected: config.inputMode == InputMode.virtualKey,
                onSelected: (_) => _set('input_mode', 'virtual_key'),
              ),
              ChoiceChip(
                key: const Key('mode_piano'),
                label: const Text('电钢琴'),
                selected: config.inputMode == InputMode.piano,
                onSelected: (_) => _set('input_mode', 'piano'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '会话中不可切换（保证反应时口径一致）；电钢琴未连接或断连时自动回退屏幕键盘',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _licenseTile(ThemeData theme) {
    return FutureBuilder<List<String>>(
      future: _licenseNames,
      builder: (context, snap) {
        final names = snap.data ?? const <String>[];
        return ListTile(
          key: const Key('license_tile'),
          title: const Text('素材许可'),
          subtitle: names.isEmpty
              ? const Text('素材许可见应用内许可页')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final name in names)
                      Text(name, key: Key('license_$name')),
                  ],
                ),
        );
      },
    );
  }
}

/// 重置二次确认：必须输入"重置"二字才能确认。
class _ResetDialog extends StatefulWidget {
  const _ResetDialog();

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _controller = TextEditingController();
  bool _matches = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重置进度'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '将清空全部训练记录（题量设置保留），不可撤销。\n'
            '请输入「重置」以确认。',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('reset_input'),
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '重置'),
            onChanged: (v) => setState(() => _matches = v.trim() == '重置'),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('reset_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('reset_confirm'),
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('重置'),
        ),
      ],
    );
  }
}

/// 蓝牙电钢琴：扫描/连接/断开（Roland FP-18 等 BLE-MIDI 设备）。
/// 扫描保持到离开设置页（插件在 Android 上不宜在连接前后反复停启扫描）。
class _PianoMidiSection extends ConsumerStatefulWidget {
  const _PianoMidiSection();

  @override
  ConsumerState<_PianoMidiSection> createState() => _PianoMidiSectionState();
}

class _PianoMidiSectionState extends ConsumerState<_PianoMidiSection> {
  late final PianoMidiService _service;
  PianoConnectionState _state = PianoConnectionState.disconnected;
  List<PianoDevice> _devices = const [];
  StreamSubscription<PianoConnectionState>? _stateSub;
  StreamSubscription<List<PianoDevice>>? _deviceSub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(pianoMidiServiceProvider);
    _state = _service.connectionState;
    _devices = _service.devices;
    _stateSub = _service.connectionStateChanges.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _deviceSub = _service.deviceChanges.listen((d) {
      if (mounted) setState(() => _devices = d);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _deviceSub?.cancel();
    _service.stopScan(); // 只停扫描，保持已建立的连接
    super.dispose();
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.startScan();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(PianoDevice device) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.connect(device);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _statusText => switch (_state) {
        PianoConnectionState.disconnected => '未连接',
        PianoConnectionState.scanning => _devices.isEmpty
            ? '正在扫描…'
            : '正在扫描…（已发现 ${_devices.length} 台）',
        PianoConnectionState.scanTimedOut => '未发现蓝牙 MIDI 设备',
        PianoConnectionState.connecting => '正在连接…',
        PianoConnectionState.connected =>
          '已连接：${_service.connectedDevice?.displayName ?? 'MIDI 设备'}',
        PianoConnectionState.bluetoothOff => '手机蓝牙未开启',
        PianoConnectionState.permissionDenied => '蓝牙权限被拒绝（请在系统设置中允许）',
        PianoConnectionState.error => '连接失败：${_service.lastError ?? '未知错误'}',
      };

  String get _scanButtonLabel => switch (_state) {
        PianoConnectionState.scanning => '扫描中…',
        PianoConnectionState.scanTimedOut => '重新扫描',
        _ => '扫描设备',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _state == PianoConnectionState.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: connected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_statusText, style: theme.textTheme.bodyMedium),
              ),
              if (connected)
                TextButton(
                  key: const Key('piano_disconnect'),
                  onPressed: _busy ? null : _disconnect,
                  child: const Text('断开'),
                )
              else
                FilledButton.tonal(
                  key: const Key('piano_scan'),
                  onPressed: _busy ||
                          !_service.isSupported ||
                          _state == PianoConnectionState.scanning
                      ? null
                      : _scan,
                  child: Text(_scanButtonLabel),
                ),
            ],
          ),
          if (!_service.isSupported)
            Text(
              '当前环境未启用蓝牙 MIDI（需 Android / iOS 真机）',
              style: theme.textTheme.bodySmall,
            ),
          for (var i = 0; i < _devices.length; i++)
            ListTile(
              key: Key('piano_device_$i'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_devices[i].displayName),
              subtitle: Text(
                '${_devices[i].transportLabel} · ${_devices[i].name}'
                '${_devices[i].profileId != null ? ' · 已识别型号' : ' · 通用 MIDI 设备'}',
              ),
              trailing: connected &&
                      _service.connectedDevice?.id == _devices[i].id
                  ? const Text('已连接')
                  : TextButton(
                      key: Key('piano_connect_$i'),
                      onPressed: _busy ? null : () => _connect(_devices[i]),
                      child: const Text('连接'),
                    ),
            ),
          const SizedBox(height: 4),
          Text(
            'FP-18：开机后按功能键（CC7 旁）开启蓝牙 MIDI；首次连接会弹系统配对框。'
            '请关闭电钢琴移调（Transpose），否则音高会整体偏移。',
            style: theme.textTheme.bodySmall,
          ),
          if (!connected &&
              (_state == PianoConnectionState.scanning ||
                  _state == PianoConnectionState.scanTimedOut)) ...[
            const SizedBox(height: 4),
            Text(
              '这里只显示蓝牙 MIDI 乐器：耳机、音箱、手表不会出现。'
              '若 20 秒内没有发现设备，请确认电钢琴已开机、蓝牙 MIDI 已开启，'
              '且没有同时连接其他手机或 App。',
              style: theme.textTheme.bodySmall,
            ),
          ],
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('piano_diagnostics'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text('扫描诊断', style: theme.textTheme.bodySmall),
              subtitle: Text(
                '蓝牙状态：${_state.name} · 已发现 ${_devices.length} 台',
                style: theme.textTheme.bodySmall,
              ),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _service.logLines.isEmpty
                        ? '（暂无日志，先点「扫描设备」）'
                        : _service.logLines.join('\n'),
                    key: const Key('piano_logs'),
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const Key('piano_log_refresh'),
                        onPressed: () => setState(() {}),
                        child: const Text('刷新'),
                      ),
                      TextButton(
                        key: const Key('piano_log_copy'),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: _service.logLines.join('\n')));
                        },
                        child: const Text('复制诊断'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
