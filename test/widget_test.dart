// M3 冒烟：应用入口 → 首次启动显示 S0 诊断引导（06 §1）。
@Tags(['widget'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// Database 类型来自 sqflite_common（ffi 包导出）。

import 'package:sight_reading/app.dart';
import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/db.dart';

class _NoopAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async {}
  @override
  Future<void> playComparison(
      {required int answerMidi,
      required int correctMidi,
      Duration gap = const Duration(milliseconds: 400)}) async {}
  @override
  Future<void> playSequence(List<int> midis,
      {Duration interval = const Duration(milliseconds: 500)}) async {}
  @override
  void stop() {}
  @override
  bool muted = false;
  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('first launch shows diagnosis welcome (S0)', (tester) async {
    late final Database db;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        configProvider.overrideWith((ref) async => Config.defaults),
        audioServiceProvider.overrideWithValue(_NoopAudio()),
      ],
      child: const SightReadingApp(),
    ));
    // 根门 FutureBuilder 走真实 ffi 异步：先 pump 让其创建，再 runAsync 推进。
    await tester.pump();
    await tester.runAsync(
        () async => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('开始诊断'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
  });
}