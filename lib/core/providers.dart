// 规格: 03 §3 —— Riverpod 依赖注入（轻量抽象层）。
// 重依赖（sqflite 插件/path_provider/flutter_soloud）隔离在 production_providers.dart，
// 由应用入口 override 注入；测试 override 轻量假实现，避免重编译链。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../data/repositories/settings_repo.dart';
import 'audio_service.dart';
import 'clock.dart';
import 'config.dart';
import 'piano_midi.dart';

/// 应用数据库（04 DDL，user_version=2）。生产 override 见 production_providers.dart。
final databaseProvider = FutureProvider<Database>((ref) async {
  throw StateError('databaseProvider 未装配：请在入口使用 productionOverrides()');
});

/// 数据库工厂（试玩模式用它在内存库上建临时会话）。
final databaseFactoryProvider = Provider<DatabaseFactory>((ref) {
  throw StateError('databaseFactoryProvider 未装配：请在入口使用 productionOverrides()');
});

/// 启动加载的不可变配置（02 §8.6 阈值）。
final configProvider = FutureProvider<Config>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return SettingsRepo(db).loadConfig();
});

/// 音频服务。生产 override 见 production_providers.dart。
final audioServiceProvider = Provider<AudioService>((ref) {
  throw StateError('audioServiceProvider 未装配：请在入口使用 productionOverrides()');
});

/// 蓝牙电钢琴输入。默认空实现（测试/未装配），生产 override 注入插件实现。
final pianoMidiServiceProvider = Provider<PianoMidiService>((ref) {
  return NoopPianoMidiService();
});

/// 时钟（RT 单调钟 + 本地日期）。
final clockProvider = Provider<Clock>((ref) => SystemClock());