// 规格: 06 §1 导航补充 —— 试玩模式（超出 02 MVP 范围，已记入交付报告「实现偏差」）。
// 目的：让用户在阶段 0 就能看到后续训练（短句阅读器等），不改变任何真实进度数据。
// 做法：整个试玩会话跑在**内存数据库**里（':memory:'），退出即销毁，
// 不触碰 app_flutter/sight_reading.db，因此 mastery/trial 与正式进度完全隔离。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../core/clock.dart';
import '../core/config.dart';
import '../core/rng.dart';
import '../domain/models/enums.dart';
import '../domain/models/item.dart';
import '../domain/models/mastery.dart';
import '../domain/phrase_generator.dart';
import 'db.dart';
import 'repositories/app_state_repo.dart';
import 'repositories/item_repo.dart';
import 'repositories/mastery_repo.dart';
import 'session_service.dart';

/// 试玩会话：bundle 用于驱动 [SessionPage]，db 是内存库（退出时 close）。
class PlaygroundSession {
  final SessionBundle bundle;
  final Database db;

  const PlaygroundSession({required this.bundle, required this.db});

  Future<void> dispose() => db.close();
}

/// 构建一个「看起来像老用户」的内存库，并按 [stage] 生成完整队列。
///
/// [stage] 仅支持 4（3 音短句）与 5（4–5 音 + 跨谱表）。
Future<PlaygroundSession> buildPlaygroundSession({
  required DatabaseFactory factory,
  required Config config,
  required Clock clock,
  required int stage,
  int dailyCount = 20,
}) async {
  assert(stage == 4 || stage == 5, '试玩仅开放短句阶段（4/5）');
  final db = await openAppDatabase(factory, ':memory:');
  final appState = AppStateRepo(db);
  await appState.set('onboarded', '1');
  await appState.set('diagnosis_done', '1');
  await appState.set('active_anchors', '[0,4]');
  await appState.set('course_stage', '$stage');

  // 第一遍：生成锚点 / 直认 / 关系条目。
  await SessionSetup.build(
    db: db,
    config: config,
    clock: clock,
    rng: rng(1),
    dailyCount: 6,
  );

  // 造出"已练熟"的状态：短句生成器的起点只取已自动化音位。
  final itemRepo = ItemRepo(db);
  final masteryRepo = MasteryRepo(db);
  final items = await itemRepo.all();
  final automated = <int>{
    for (final it in items)
      if (it.type == ItemType.direct || it.type == ItemType.anchor)
        it.payload.targetIndices.first,
  };
  for (final it in items) {
    final m = await masteryRepo.byItemId(it.id);
    if (m == null) continue;
    final next = switch (it.type) {
      ItemType.anchor || ItemType.direct => m.copyWith(
          state: ItemState.automated,
          intervalDays: 14,
          dueAt: () => clock.nowUtcMs(),
        ),
      ItemType.relation || ItemType.phrase => m.copyWith(
          state: ItemState.reviewing,
          intervalDays: 7,
          dueAt: () => clock.nowUtcMs(),
        ),
    };
    await masteryRepo.upsert(next);
  }

  // 预生成 3 条短句：保证试玩队列里短句足够多（build 每次只新增 1 条）。
  final recent = <List<int>>[];
  for (var i = 0; i < 3; i++) {
    final gen = generatePhrase(
      stage: stage,
      rng: rng(100 + i),
      recentSequences: recent,
      automatedIndices: automated,
      anchorIndices: const {0, 4},
      config: config,
    );
    final id = await itemRepo.insert(Item(
      id: 0,
      type: ItemType.phrase,
      payload: gen.payload,
      createdAt: clock.nowUtcMs(),
    ));
    await masteryRepo.upsert(Mastery(
      itemId: id,
      state: ItemState.learning,
      ease: config.easeInit,
      dueAt: clock.nowUtcMs(),
      hintLevel: 0,
    ));
    recent.add(gen.payload.noteSequence);
  }

  // 第二遍：按目标阶段构建完整队列（含短句段）。
  final bundle = await SessionSetup.build(
    db: db,
    config: config,
    clock: clock,
    rng: rng(7),
    dailyCount: dailyCount,
    phrasesOnly: true,
  );
  return PlaygroundSession(bundle: bundle, db: db);
}
