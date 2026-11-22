// 测试辅助：ffi 内存库（03 §4.3 纯 Dart API；工厂注入）。
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sight_reading/data/db.dart';
import 'package:sight_reading/data/repositories/app_state_repo.dart';
import 'package:sight_reading/data/repositories/item_repo.dart';
import 'package:sight_reading/data/repositories/mastery_repo.dart';
import 'package:sight_reading/data/repositories/phrase_repo.dart';
import 'package:sight_reading/data/repositories/session_repo.dart';
import 'package:sight_reading/data/repositories/settings_repo.dart';
import 'package:sight_reading/data/repositories/trial_repo.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/mastery.dart';
import 'package:sight_reading/domain/models/phrase_session.dart';
import 'package:sight_reading/domain/models/trial.dart';

export 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show
        Database,
        DatabaseFactory,
        inMemoryDatabasePath,
        databaseFactoryFfi,
        sqfliteFfiInit;

/// 打开一个已建表+种子的内存库。
Future<Database> openTestDb() =>
    openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);

/// 构造覆盖全部业务表的样例数据（备份/事务测试用）。
Future<void> seedSampleData(Database db) async {
  final items = ItemRepo(db);
  final anchorId = await items.insert(Item(
    id: 0,
    type: ItemType.anchor,
    payload: const AnchorPayload(diatonicIndex: 4),
    createdAt: 1000,
  ));
  final phraseId = await items.insert(Item(
    id: 0,
    type: ItemType.phrase,
    payload: PhrasePayload(
      noteSequence: const [0, 1, 2],
      clefSequence: const [Clef.treble, Clef.treble, Clef.treble],
    ),
    createdAt: 1001,
  ));
  final sessionId = await SessionRepo(db).insert(const Session(
    date: '2026-11-19',
    startedAt: 2000,
    plannedCount: 40,
  ));
  await MasteryRepo(db).upsert(Mastery(
    itemId: anchorId,
    state: ItemState.learning,
    ease: 2.5,
    reps: 1,
    dueAt: 90000,
    lastResults: const [
      TrialResult(correct: false, rtMs: 1800, hintLevel: 3, ts: 3000),
    ],
    contextTags: const ['treble:isolated'],
  ));
  await TrialRepo(db).recordTrial(
    trial: Trial(
      sessionId: sessionId,
      itemId: anchorId,
      presentedAt: 2500,
      answeredAt: 3000,
      rtMs: 1800,
      correct: false,
      errorType: ErrorType.distance,
      answerPitchClass: 'E',
      inputSource: InputSource.nameButton,
      contextSnapshot: const ContextSnapshot(clef: Clef.treble, jitterSeed: 7),
    ),
    mastery: Mastery(
      itemId: anchorId,
      state: ItemState.learning,
      reps: 2,
      lapses: 1,
      dueAt: 90000,
      lastResults: const [
        TrialResult(correct: false, rtMs: 1800, hintLevel: 3, ts: 3000),
      ],
    ),
    seedPair: (4, 2),
  );
  await PhraseRepo(db).insert(PhraseRecord(
    itemId: phraseId,
    noteSequence: const [0, 1, 2],
    resetCount: 1,
    perNoteRt: const [900, 800, 700],
    overallCorrect: 2 / 3,
    createdAt: 4000,
  ));
  await SettingsRepo(db).set('daily_count', '30');
  await AppStateRepo(db).set('course_stage', '2');
  await AppStateRepo(db).set('active_anchors', '[0,4]');
}