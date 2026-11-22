// 规格: 03 §3 —— 生产装配：重依赖（sqflite 插件/path_provider/flutter_soloud）
// 只在本文件引入，经 ProviderScope.overrides 注入轻量抽象 providers。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../data/audio_soloud.dart';
import '../data/db.dart';
import '../data/piano_midi_command.dart';
import '../data/soloud_backend.dart';
import 'providers.dart';

/// 应用入口使用的生产 overrides。
List<Override> productionOverrides() => [
      databaseProvider.overrideWith((ref) async {
        final dir = await getApplicationDocumentsDirectory();
        return openAppDatabase(
            sqflite.databaseFactory, '${dir.path}/sight_reading.db');
      }),
      databaseFactoryProvider.overrideWithValue(sqflite.databaseFactory),
      audioServiceProvider.overrideWith((ref) {
        final svc = SoloudAudioService(backend: SoloudBackend());
        ref.onDispose(svc.dispose);
        // 22 个采样预加载（02 §1.4）。初始化失败静默降级为无声，
        // 不阻塞 UI（06 §6：音频异常时视觉反馈照常）。
        unawaited(svc.init().catchError((Object e, StackTrace st) {
          debugPrint('音频初始化失败（静默降级）：$e');
        }));
        return svc;
      }),
      pianoMidiServiceProvider.overrideWith((ref) {
        final svc = MidiCommandPianoService();
        ref.onDispose(svc.dispose);
        return svc;
      }),
    ];