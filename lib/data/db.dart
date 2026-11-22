// 规格: 04-数据库设计.sql（DDL 与种子唯一权威，逐字嵌入）/ 03 §4.3 / 02 §8。
// 纯 Dart sqflite_common API；DatabaseFactory 由外部注入
// （生产: sqflite.databaseFactory；测试: sqflite_common_ffi.databaseFactoryFfi）。
library;

import 'package:sqflite_common/sqlite_api.dart';

/// schema version（03 §4.3：PRAGMA user_version 管理迁移）。
///
/// v2：新增视奏记录表 `sight_read_log`（11 §7）。
/// 升级策略：不写增量 ALTER，而是把 v2 全量 DDL（全部 `CREATE TABLE IF NOT EXISTS`
/// + `INSERT OR IGNORE`）在老库上重放一遍——已存在的表与种子行原样保留，
/// 只补建缺失的新表，因此升级无损且可重复执行。
const int schemaVersion = 2;

/// 04-数据库设计.sql 全文（逐字复制）。
const String schemaSql = r'''
-- ============================================================
-- 04 数据库设计（SQLite，MVP schema version = 2）
-- 权威：02-MVP功能规格 §8；音位坐标：C4 = diatonic_index 0
-- 执行方式：应用首次启动时整体执行；PRAGMA user_version = 2
-- 全部幂等（IF NOT EXISTS / INSERT OR IGNORE）
-- ============================================================

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------- 音位（静态，22 行） ----------
-- in_treble/in_bass：该音位可在哪些谱表呈现（C4 双谱表）
-- ledger_*：在该谱表是否为加线音位
CREATE TABLE IF NOT EXISTS note_position (
  id              INTEGER PRIMARY KEY,
  diatonic_index  INTEGER NOT NULL UNIQUE,  -- C4=0，自然音级计数
  display_name    TEXT    NOT NULL,         -- 如 G4
  pitch_class     TEXT    NOT NULL,         -- C D E F G A B
  octave          INTEGER NOT NULL,
  midi            INTEGER NOT NULL,         -- C4=60
  in_treble       INTEGER NOT NULL DEFAULT 0,
  in_bass         INTEGER NOT NULL DEFAULT 0,
  ledger_treble   INTEGER NOT NULL DEFAULT 0,
  ledger_bass     INTEGER NOT NULL DEFAULT 0
);

-- ---------- 条目 ----------
-- type: ANCHOR / RELATION / DIRECT / PHRASE
-- payload JSON：
--   ANCHOR/DIRECT: {"diatonicIndex":4}
--   RELATION:      {"anchorIndex":4,"direction":1,"steps":2}  steps=2二度/3三度；两步推导 {"chain":[{"anchorIndex":4,"direction":1,"steps":2},...]}
--   PHRASE:        {"noteSequence":[0,1,2],"clefSequence":["treble","treble","treble"]}
CREATE TABLE IF NOT EXISTS item (
  id          INTEGER PRIMARY KEY,
  type        TEXT NOT NULL CHECK (type IN ('ANCHOR','RELATION','DIRECT','PHRASE')),
  payload     TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_item_type ON item(type);

-- ---------- 掌握度（与 item 一对一） ----------
-- state: inactive / learning / reviewing / automated / relapsed
CREATE TABLE IF NOT EXISTS mastery (
  item_id          INTEGER PRIMARY KEY REFERENCES item(id),
  state            TEXT NOT NULL DEFAULT 'inactive'
                   CHECK (state IN ('inactive','learning','reviewing','automated','relapsed')),
  ease             REAL    NOT NULL DEFAULT 2.5,
  interval_days    REAL    NOT NULL DEFAULT 0,
  due_at           INTEGER,                 -- UTC ms；learning 阶段为会话末时间戳
  reps             INTEGER NOT NULL DEFAULT 0,
  lapses           INTEGER NOT NULL DEFAULT 0,
  hint_level       INTEGER NOT NULL DEFAULT 3,
  hint_dependency  REAL    NOT NULL DEFAULT 0,
  rt_median        INTEGER,                 -- 无提示作答 RT 中位数 ms
  last_results     TEXT    NOT NULL DEFAULT '[]',  -- 最近10次 [{correct,rtMs,hintLevel,ts}]
  context_tags     TEXT    NOT NULL DEFAULT '[]'   -- 最近呈现上下文，用于换上下文判定
);
CREATE INDEX IF NOT EXISTS idx_mastery_due ON mastery(due_at);
CREATE INDEX IF NOT EXISTS idx_mastery_state ON mastery(state);

-- ---------- 试次日志（只增不改） ----------
CREATE TABLE IF NOT EXISTS trial_log (
  id                INTEGER PRIMARY KEY,
  session_id        INTEGER NOT NULL REFERENCES session(id),
  item_id           INTEGER NOT NULL REFERENCES item(id),
  presented_at      INTEGER NOT NULL,       -- 刺激 onset（帧渲染完成）UTC ms
  answered_at       INTEGER,
  rt_ms             INTEGER,
  correct           INTEGER NOT NULL,       -- 0/1；提示级5完成记0
  timeout           INTEGER NOT NULL DEFAULT 0,
  hint_level_used   INTEGER NOT NULL DEFAULT 0,
  hint_requested    INTEGER NOT NULL DEFAULT 0,
  error_type        TEXT,                   -- 05 §5 枚举，正确且非慢时为 NULL
  answer_pitch_class TEXT,
  answer_octave     INTEGER,                -- 键盘/MIDI 模式才有
  input_source      TEXT NOT NULL,          -- NAME_BUTTON / VIRTUAL_KEY / MIDI
  context_snapshot  TEXT NOT NULL           -- {clef,jitterSeed,phraseSlot,neighbors,...}
);
CREATE INDEX IF NOT EXISTS idx_trial_session ON trial_log(session_id);
CREATE INDEX IF NOT EXISTS idx_trial_item ON trial_log(item_id);

-- ---------- 会话 ----------
CREATE TABLE IF NOT EXISTS session (
  id             INTEGER PRIMARY KEY,
  date           TEXT    NOT NULL,          -- 本地 YYYY-MM-DD
  started_at     INTEGER NOT NULL,
  planned_count  INTEGER NOT NULL,
  done_count     INTEGER NOT NULL DEFAULT 0,
  stage_summary  TEXT                       -- 结束时写入 JSON
);

-- ---------- 短句明细 ----------
CREATE TABLE IF NOT EXISTS phrase (
  id             INTEGER PRIMARY KEY,
  item_id        INTEGER NOT NULL REFERENCES item(id),
  note_sequence  TEXT    NOT NULL,          -- [diatonicIndex,...]
  reset_count    INTEGER NOT NULL DEFAULT 0,
  per_note_rt    TEXT,                      -- [ms,...]
  overall_correct REAL,                     -- 逐音正确率 0..1
  created_at     INTEGER NOT NULL
);

-- ---------- 混淆种子（MVP 只写不读，二期消费） ----------
CREATE TABLE IF NOT EXISTS confusion_seed (
  id         INTEGER PRIMARY KEY,
  pair_a     INTEGER NOT NULL,              -- diatonic_index，约定 pair_a < pair_b
  pair_b     INTEGER NOT NULL,
  count      INTEGER NOT NULL DEFAULT 1,
  last_seen  INTEGER NOT NULL,
  UNIQUE (pair_a, pair_b)
);

-- ---------- 配置（阈值，02 §8.6；启动加载为 Config） ----------
CREATE TABLE IF NOT EXISTS settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);

-- ---------- 应用状态（用户进度，区别于配置） ----------
CREATE TABLE IF NOT EXISTS app_state (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);

-- ============================================================
-- 种子：22 音位
-- ============================================================
INSERT OR IGNORE INTO note_position
  (id, diatonic_index, display_name, pitch_class, octave, midi, in_treble, in_bass, ledger_treble, ledger_bass)
VALUES
  (1,  -7, 'C3', 'C', 3, 48, 0, 1, 0, 0),
  (2,  -6, 'D3', 'D', 3, 50, 0, 1, 0, 0),
  (3,  -5, 'E3', 'E', 3, 52, 0, 1, 0, 0),
  (4,  -4, 'F3', 'F', 3, 53, 0, 1, 0, 0),
  (5,  -3, 'G3', 'G', 3, 55, 0, 1, 0, 0),
  (6,  -2, 'A3', 'A', 3, 57, 0, 1, 0, 0),
  (7,  -1, 'B3', 'B', 3, 59, 0, 1, 0, 0),
  (8,   0, 'C4', 'C', 4, 60, 1, 1, 1, 1),
  (9,   1, 'D4', 'D', 4, 62, 1, 0, 0, 0),
  (10,  2, 'E4', 'E', 4, 64, 1, 0, 0, 0),
  (11,  3, 'F4', 'F', 4, 65, 1, 0, 0, 0),
  (12,  4, 'G4', 'G', 4, 67, 1, 0, 0, 0),
  (13,  5, 'A4', 'A', 4, 69, 1, 0, 0, 0),
  (14,  6, 'B4', 'B', 4, 71, 1, 0, 0, 0),
  (15,  7, 'C5', 'C', 5, 72, 1, 0, 0, 0),
  (16,  8, 'D5', 'D', 5, 74, 1, 0, 0, 0),
  (17,  9, 'E5', 'E', 5, 76, 1, 0, 0, 0),
  (18, 10, 'F5', 'F', 5, 77, 1, 0, 0, 0),
  (19, 11, 'G5', 'G', 5, 79, 1, 0, 0, 0),
  (20, 12, 'A5', 'A', 5, 81, 1, 0, 1, 0),
  (21, 13, 'B5', 'B', 5, 83, 1, 0, 0, 0),
  (22, 14, 'C6', 'C', 6, 84, 1, 0, 1, 0);

-- ============================================================
-- 种子：配置默认值（02 §8.6 + 会话/生成器参数）
-- ============================================================
INSERT OR IGNORE INTO settings (key, value) VALUES
  ('schema_version',                '2'),
  -- 锚点自动化（F1）
  ('anchor_auto_acc',               '0.95'),
  ('anchor_auto_rt_ms',             '1200'),
  ('anchor_auto_window',            '20'),
  -- 直认自动化（F3）
  ('direct_auto_acc',               '0.95'),
  ('direct_auto_rt_ms',             '1500'),
  ('direct_auto_window',            '20'),
  -- 直认晋升/回退（F3）
  ('promote_streak',                '5'),
  ('promote_rt_ms',                 '2000'),
  ('promote_rt_ledger_ms',          '2500'),
  ('relapse_direct_streak',         '3'),
  -- 提示（F2）
  ('hint_initial_level',            '3'),
  ('micro_lesson_level',            '5'),
  ('hint_downgrade_streak',         '3'),
  ('hint_downgrade_rt_ms',          '2000'),
  ('hint_dep_stable_max',           '0.3'),
  ('hint_dep_weights',              '0.2,0.4,0.6,0.8,1.0'),  -- 级1..5
  -- 调度（F5）
  ('interval_ladder_days',          '0,1,3,7,14,30'),
  ('ease_init',                     '2.5'),
  ('ease_min',                      '1.3'),
  ('ease_max',                      '2.8'),
  ('stable_min_interval_days',      '7'),
  ('stable_streak',                 '5'),
  ('dedup_gap',                     '4'),
  ('lapse_reexpose_min',            '2'),
  ('lapse_reexpose_max',            '4'),
  ('mix_review',                    '0.4'),
  ('mix_new',                       '0.2'),
  ('mix_direct',                    '0.2'),
  ('mix_phrase',                    '0.2'),
  ('max_same_type_run',             '2'),
  ('stage_advance_ratio',           '0.8'),
  -- 限时
  ('flash_limit_anchor_ms',         '3000'),
  ('flash_limit_anchor_min_ms',     '1500'),
  ('flash_limit_direct_ms',         '2500'),
  ('flash_limit_direct_min_ms',     '1200'),
  ('slow_correct_rt_ms',            '4000'),
  ('key_limit_grace_ms',            '5000'),
  -- 短句（F4）
  ('phrase_len_stage4',             '3'),
  ('phrase_len_stage5_min',         '4'),
  ('phrase_len_stage5_max',         '5'),
  ('phrase_step_min_ratio',         '0.6'),
  ('phrase_max_leap_steps',         '3'),
  ('phrase_dedup_window',           '20'),
  ('wrong_phrase_threshold',        '0.4'),
  ('phrase_play_interval_ms',       '500'),
  ('wrong_answer_gap_ms',           '400'),
  -- 诊断（F1）
  ('diag_anchor_trials',            '6'),
  ('diag_anchor_pass_acc',          '0.8'),
  ('diag_strategy_trials',          '6'),
  ('diag_strategy_pass_acc',        '0.8'),
  ('diag_strategy_max_hints',       '1'),
  ('diag_confusion_trials',         '8'),
  ('anchor_candidates',             '0,4,-4,7,-7'),  -- C4,G4,F3,C5,C3
  -- 会话
  ('session_default_count',         '40'),
  ('warmup_count',                  '8'),
  ('inter_trial_blank_ms',          '800'),
  ('anchor_prelude_ms',             '1000'),
  ('micro_lesson_anchor_ms',        '1500'),
  -- 用户偏好（可改）
  ('input_mode',                    'name_buttons'), -- name_buttons / virtual_key
  ('audio_enabled',                 '1'),
  ('relaxed_timing',                '0'),            -- 1=所有时限×1.5
  ('daily_count',                   '40');

-- ---------- 应用状态初始 ----------
INSERT OR IGNORE INTO app_state (key, value) VALUES
  ('course_stage',        '0'),
  ('active_anchors',      '[]'),      -- 诊断后写入 diatonicIndex 数组
  ('diagnosis_done',      '0'),
  ('diagnosis_result',    '{}'),
  ('onboarded',           '0');

-- ============================================================
-- v2：视奏训练记录（11 §7）
-- 只读回显用，不进入 mastery / trial_log / phrase，不影响排程与掌握地图。
-- error_positions 存 JSON 对象 {diatonicIndex: 次数}，聚合口径见完成页 top3。
-- 老库升级依赖本文件「全量 IF NOT EXISTS 幂等重放」：v1 库执行到这里只会
-- 补建本表，原有 note_position / item / mastery / session 等数据一行不动。
-- ============================================================
CREATE TABLE IF NOT EXISTS sight_read_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mode TEXT NOT NULL,              -- trebleOnly | bassOnly | grand
  source TEXT NOT NULL,            -- generated | score
  score_ref TEXT,                  -- 生成时 NULL，曲目时存曲目 id
  column_count INTEGER NOT NULL,
  total_notes INTEGER NOT NULL,
  correct_notes INTEGER NOT NULL,
  error_count INTEGER NOT NULL,
  error_positions TEXT,
  duration_ms INTEGER NOT NULL,
  finished_at INTEGER NOT NULL
);
''';

/// 按分号拆分 SQL 语句（sqflite execute 不支持多语句）。
/// 跳过单引号字符串与 `--` 行注释内的分号。
List<String> splitSqlStatements(String sql) {
  final statements = <String>[];
  final buf = StringBuffer();
  var inString = false;
  var inComment = false;
  for (var i = 0; i < sql.length; i++) {
    final c = sql[i];
    if (inComment) {
      if (c == '\n') {
        inComment = false;
        buf.write(c);
      }
      continue;
    }
    if (inString) {
      buf.write(c);
      if (c == "'") {
        if (i + 1 < sql.length && sql[i + 1] == "'") {
          buf.write("'");
          i++;
        } else {
          inString = false;
        }
      }
      continue;
    }
    if (c == "'") {
      inString = true;
      buf.write(c);
      continue;
    }
    if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      inComment = true;
      continue;
    }
    if (c == ';') {
      final s = buf.toString().trim();
      if (s.isNotEmpty) statements.add(s);
      buf.clear();
      continue;
    }
    buf.write(c);
  }
  final tail = buf.toString().trim();
  if (tail.isNotEmpty) statements.add(tail);
  return statements;
}

/// 执行 DDL+种子并管理迁移（03 §4.3）。幂等，可在同一连接重复调用。
Future<void> applySchema(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  final version = (rows.first.values.first as int?) ?? 0;
  if (version > schemaVersion) {
    throw StateError('数据库版本 $version 高于应用支持的 $schemaVersion，拒绝降级');
  }
  // 全量重放：v1 库执行到 sight_read_log 时只会补建新表，老数据不受影响；
  // 已是 v2 的库重复执行同样幂等（IF NOT EXISTS / INSERT OR IGNORE）。
  for (final stmt in splitSqlStatements(schemaSql)) {
    await db.execute(stmt);
  }
  if (version < schemaVersion) {
    await db.execute('PRAGMA user_version = $schemaVersion');
  }
}

/// 打开/创建应用数据库。factory 注入：生产 sqflite.databaseFactory，
/// 测试 databaseFactoryFfi。
Future<Database> openAppDatabase(DatabaseFactory factory, String path) async {
  final db = await factory.openDatabase(path);
  try {
    await applySchema(db);
  } catch (_) {
    await db.close();
    rethrow;
  }
  return db;
}