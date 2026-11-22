// 规格: 06 §2 S6 / 02 §8.6 §8.7 —— 设置页 widget 测试。
// 注入 FakeBackupIo + ffi 内存库；断言设置写库、导出/导入、重置二次确认。
@Tags(['widget'])
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sight_reading/core/audio_service.dart';
import 'package:sight_reading/core/clock.dart';
import 'package:sight_reading/core/providers.dart';
import 'package:sight_reading/data/backup_io.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/settings_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';
import 'package:sight_reading/features/settings/settings_page.dart';

import '../data/test_db.dart';

class FakeAudio implements AudioService {
  @override
  Future<void> playClick({required bool accent}) async {}
  @override
  bool muted = false;
  @override
  Future<void> init() async {}
  @override
  Future<void> playNote(int midi) async {}
  @override
  Future<void> playComparison({
    required int answerMidi,
    required int correctMidi,
    Duration gap = const Duration(milliseconds: 400),
  }) async {}
  @override
  Future<void> playSequence(
    List<int> midis, {
    Duration interval = const Duration(milliseconds: 500),
  }) async {}
  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

class FakeBackupIo implements BackupIo {
  String? jsonToPick;
  String? sharedJson;
  String? sharedName;
  int shareCalls = 0;

  @override
  Future<void> shareJson(String fileName, String json) async {
    shareCalls++;
    sharedName = fileName;
    sharedJson = json;
  }

  @override
  Future<String?> pickJson() async => jsonToPick;
}

class _Env {
  final Database db;
  final FakeBackupIo io;
  final FakeAudio audio;

  const _Env(this.db, this.io, this.audio);
}

Future<_Env> _seed(WidgetTester tester) async {
  late _Env env;
  await tester.runAsync(() async {
    sqfliteFfiInit();
    final db = await openTestDb();
    // 同一 isolate 内 ffi :memory: 复用单例连接，先清业务表保证用例隔离。
    // 注意：settings 不清（种子默认值来自建库脚本）。
    for (final table in const [
      'trial_log',
      'phrase',
      'mastery',
      'confusion_seed',
      'session',
      'item',
      'app_state',
    ]) {
      await db.delete(table);
    }
    await SettingsRepo(db).set('daily_count', '40');
    await SettingsRepo(db).set('audio_enabled', '1');
    final itemId = await ItemRepo(db).insert(
      Item(
        id: 0,
        type: ItemType.anchor,
        payload: const AnchorPayload(diatonicIndex: 0),
        createdAt: 1000,
      ),
    );
    final sessionId = await SessionRepo(db).insert(
      Session(
        date: '2026-11-19',
        startedAt: 2000,
        plannedCount: 40,
        doneCount: 1,
      ),
    );
    await TrialRepo(db).insert(
      Trial(
        sessionId: sessionId,
        itemId: itemId,
        presentedAt: 3000,
        answeredAt: 4000,
        rtMs: 1000,
        correct: true,
        inputSource: InputSource.nameButton,
        contextSnapshot: const ContextSnapshot(
          clef: Clef.treble,
          jitterSeed: 1,
        ),
      ),
    );
    await SettingsRepo(db).set('daily_count', '60');
    await AppStateRepo(db).set('course_stage', '2');
    env = _Env(db, FakeBackupIo(), FakeAudio());
  });
  return env;
}

Future<void> _pump(WidgetTester tester, _Env env) async {
  // 设置页是懒加载 ListView：视口不够高时靠后的项（导出/导入/重置）不会被构建，
  // find.byKey 会直接 "No element"。用高视口一次渲染全部条目。
  tester.view.physicalSize = const Size(600, 1500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => env.db),
        audioServiceProvider.overrideWithValue(env.audio),
        clockProvider.overrideWithValue(
          FakeClock(utcMs: DateTime(2026, 11, 19, 12).millisecondsSinceEpoch),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: SettingsPage(io: env.io),
      ),
    ),
  );
  await _settle(tester);
}

/// 让真实异步（ffi/写库）推进后再重建。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump();
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() fn) async {
  final value = await tester.runAsync(fn);
  return value as T;
}

void main() {
  testWidgets('每日题量写库并重建配置', (tester) async {
    final env = await _seed(tester);
    await _pump(tester, env);

    await tester.tap(find.byKey(const Key('daily_60')));
    await _settle(tester);
    await _settle(tester);

    final stored = await _real(
      tester,
      () => SettingsRepo(env.db).get('daily_count'),
    );
    expect(stored, '60');
    expect(
      tester.widget<ChoiceChip>(find.byKey(const Key('daily_60'))).selected,
      isTrue,
    );
  });

  testWidgets('音频开关写库并同步 AudioService.muted', (tester) async {
    final env = await _seed(tester);
    await _pump(tester, env);
    expect(env.audio.muted, isFalse);

    await tester.tap(find.byKey(const Key('audio_switch')));
    await _settle(tester);

    final stored = await _real(
      tester,
      () => SettingsRepo(env.db).get('audio_enabled'),
    );
    expect(stored, '0');
    expect(env.audio.muted, isTrue);
  });

  testWidgets('导出调用 shareJson，JSON 可解析且含 schema_version', (tester) async {
    final env = await _seed(tester);
    await _pump(tester, env);

    await tester.ensureVisible(find.byKey(const Key('export_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export_btn')));
    await _settle(tester);

    expect(env.io.shareCalls, 1);
    expect(env.io.sharedName, contains('json'));
    final decoded = jsonDecode(env.io.sharedJson!) as Map<String, dynamic>;
    expect(decoded['schema_version'], 2);
    expect((decoded['tables'] as Map)['trial_log'], isA<List>());
    expect(find.text('备份已生成，请选择保存位置'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // 让 SnackBar 计时器结束
  });

  testWidgets('导入非法 JSON：提示错误且原数据不变', (tester) async {
    final env = await _seed(tester);
    env.io.jsonToPick = '{"not":"a backup"}';
    await _pump(tester, env);

    await tester.ensureVisible(find.byKey(const Key('import_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import_btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import_confirm')), findsOneWidget);
    expect(find.textContaining('覆盖式'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import_confirm')));
    await _settle(tester);

    expect(find.textContaining('导入失败'), findsOneWidget);
    final trials = await _real(tester, () => TrialRepo(env.db).count());
    expect(trials, 1); // 原数据未变
    final daily = await _real(
      tester,
      () => SettingsRepo(env.db).get('daily_count'),
    );
    expect(daily, '60');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('重置进度：必须输入「重置」，清空 trial_log 并保留 settings', (tester) async {
    final env = await _seed(tester);
    await _pump(tester, env);

    // ListView 惰性构建：重置项在首屏之下。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('reset_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset_btn')));
    await tester.pumpAndSettle();

    final disabled = tester.widget<FilledButton>(
      find.byKey(const Key('reset_confirm')),
    );
    expect(disabled.onPressed, isNull);

    await tester.enterText(find.byKey(const Key('reset_input')), '重置');
    await tester.pump();
    final enabled = tester.widget<FilledButton>(
      find.byKey(const Key('reset_confirm')),
    );
    expect(enabled.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('reset_confirm')));
    await _settle(tester);
    await _settle(tester);

    expect(find.text('已重置，下次启动重新诊断'), findsOneWidget);
    expect(await _real(tester, () => TrialRepo(env.db).count()), 0);
    expect(
      await _real(tester, () => SettingsRepo(env.db).get('daily_count')),
      '60',
    ); // settings 保留
    expect(
      await _real(tester, () => AppStateRepo(env.db).get('course_stage')),
      isNull,
    );
    final notes = await _real(
      tester,
      () => env.db.rawQuery('SELECT COUNT(*) AS c FROM note_position'),
    );
    expect((notes.first['c'] as int?) ?? 0, 22); // 静态音位表保留
    await tester.pump(const Duration(seconds: 5));
  });
}
