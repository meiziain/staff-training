// 规格: 05 §1 条目生成 / §3 会话队列 / §9 会话状态机；02 §6.4 每日队列 §7 会话编排；
// 03 §4.3（trial+mastery 同事务、退出丢弃未做队列）。
//
// 契约裁决（接口同步 vs 数据库异步）：
// 1) TrialRecorder/SessionDataSource 为同步接口（session_engine.dart），而 sqflite
//    全异步。实现采用"启动快照缓存 + 串行写队列（write-behind）"：
//    DbSessionDataSource.load 一次性载入 item/mastery/trial_log；同步读走缓存；
//    写操作先更新缓存再入队，flush() 等待落库并 surfaced 首个错误。
//    UI 须在会话结束/退后台时 await bundle.flush()（02 §7.2 已答试次即时落库口径
//    由写队列保证顺序，崩溃一致性由 recordTrial 事务保证）。
// 2) 候选分桶互斥（buildQueue 的 unused 只排除已放置条目，跨桶重复会导致同一条目
//    入队两次）：新学=RELATION learning 且 reps=0；直认=激活态 DIRECT；短句=全部
//    PHRASE；到期=dueBefore(本地今日末) 且激活态，排除前三桶。ANCHOR 可入热身池与
//    到期桶（热身先放置，unused 去重，无重复风险）。
// 3) 阶段推进在 build 末尾判定（course.evaluateAdvance）：可推进则 course_stage+1
//    并置 app_state.micro_lesson_next_session='1'；本次会话仍按读取阶段执行，
//    微课在下次会话消费（05 §10 / course.AdvanceDecision.microLessonNextSession）。
// 4) active_anchors 为空 → 跳过诊断口径 anchors={C4,G4}（05 §8）。
// 5) 阶段>=4 每次 build 生成 1 条新 PHRASE（02 §6.4 未定义每次新增数量）。
// 6) sessionEndTs 传 null：q1 到期取本地今日 23:59（scheduler.advance 口径）。
// 7) carryoverIds 持久化到 app_state.queue_carryover_ids，次日 build 读回 +1000 优先。
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../core/clock.dart';
import '../core/config.dart';
import '../core/rng.dart';
import '../domain/course.dart';
import '../domain/models/enums.dart';
import '../domain/models/item.dart';
import '../domain/models/mastery.dart';
import '../domain/models/phrase_session.dart';
import '../domain/models/trial.dart';
import '../domain/phrase_generator.dart';
import '../domain/scheduler.dart';
import '../domain/session_engine.dart';
import 'repositories/app_state_repo.dart';
import 'repositories/item_repo.dart';
import 'repositories/mastery_repo.dart';
import 'repositories/phrase_repo.dart';
import 'repositories/session_repo.dart';
import 'repositories/trial_repo.dart';

/// 串行写队列：保持调用顺序落库；错误不中断后续写，flush() 统一 surfaced。
class SessionWriteQueue {
  Future<void> _tail = Future<void>.value();
  Object? _error;
  StackTrace? _stackTrace;

  void enqueue(Future<void> Function() op) {
    _tail = _tail.then((_) async {
      try {
        await op();
      } catch (e, st) {
        _error ??= e;
        _stackTrace ??= st;
      }
    });
  }

  /// 等待已入队写全部完成；任一写失败则抛出首个错误。
  Future<void> flush() async {
    await _tail;
    final e = _error;
    if (e != null) {
      Error.throwWithStackTrace(e, _stackTrace ?? StackTrace.current);
    }
  }
}

/// TrialRecorder 数据层实现：record → recordTrial（trial+mastery+confusion 同事务）；
/// recordPhrase → phrase 表插入。注入 [source] 时同步更新其读缓存。
class DbTrialRecorder implements TrialRecorder {
  final TrialRepo _trials;
  final PhraseRepo _phrases;
  final DbSessionDataSource? _cache;
  final SessionWriteQueue _writes;

  DbTrialRecorder({
    required TrialRepo trialRepo,
    required PhraseRepo phraseRepo,
    DbSessionDataSource? source,
    SessionWriteQueue? writes,
  })  : _trials = trialRepo,
        _phrases = phraseRepo,
        _cache = source,
        _writes = writes ?? source?.writes ?? SessionWriteQueue();

  @override
  void record(Trial trial, Mastery mastery, (int, int)? seedPair) {
    _cache?._absorb(trial, mastery);
    _writes.enqueue(() =>
        _trials.recordTrial(trial: trial, mastery: mastery, seedPair: seedPair));
  }

  @override
  void recordPhrase(PhraseRecord record) {
    _writes.enqueue(() => _phrases.insert(record));
  }

  Future<void> flush() => _writes.flush();
}

/// SessionDataSource 数据层实现：启动快照缓存 + 写队列（见文件头裁决 1）。
class DbSessionDataSource implements SessionDataSource {
  final MasteryRepo _masteries;
  final SessionWriteQueue writes;

  final Map<int, Item> _items = {};
  final Map<int, Mastery> _masteryByItem = {};
  final Map<int, List<Trial>> _trialsByItem = {};

  DbSessionDataSource._(this._masteries, this.writes);

  /// 全量载入快照（MVP 数据量小，05 §3 口径允许全量取再过滤）。
  static Future<DbSessionDataSource> load(Database db,
      {SessionWriteQueue? writes}) async {
    final src =
        DbSessionDataSource._(MasteryRepo(db), writes ?? SessionWriteQueue());
    for (final it in await ItemRepo(db).all()) {
      src._items[it.id] = it;
    }
    for (final m in await MasteryRepo(db).all()) {
      src._masteryByItem[m.itemId] = m;
    }
    final rows = await db.query('trial_log', orderBy: 'id ASC');
    for (final row in rows) {
      final t = Trial.fromRow(row);
      src._trialsByItem.putIfAbsent(t.itemId, () => []).add(t);
    }
    return src;
  }

  List<Item> get items => _items.values.toList(growable: false);

  Item? itemById(int id) => _items[id];

  void _absorb(Trial trial, Mastery mastery) {
    _trialsByItem.putIfAbsent(trial.itemId, () => []).add(trial);
    _masteryByItem[mastery.itemId] = mastery;
  }

  @override
  Mastery masteryOf(int itemId) =>
      _masteryByItem[itemId] ?? Mastery(itemId: itemId);

  @override
  List<TrialResult> recentResults(int itemId, int limit) {
    final list = _trialsByItem[itemId] ?? const <Trial>[];
    final from = list.length > limit ? list.length - limit : 0;
    return [for (final t in list.sublist(from)) _toResult(t)];
  }

  @override
  List<TrialResult> relationHistoryFor(int targetIndex) {
    final ids = _items.values
        .where((it) =>
            it.type == ItemType.relation &&
            (it.payload as RelationPayload).targetIndex == targetIndex)
        .map((it) => it.id);
    final trials = <Trial>[for (final id in ids) ...?_trialsByItem[id]];
    trials.sort((a, b) => _tsOf(a).compareTo(_tsOf(b)));
    return trials.map(_toResult).toList();
  }

  @override
  Mastery? directMasteryOf(int diatonicIndex) {
    for (final it in _items.values) {
      if (it.type == ItemType.direct &&
          (it.payload as DirectPayload).diatonicIndex == diatonicIndex) {
        return masteryOf(it.id);
      }
    }
    return null;
  }

  @override
  List<int> relationItemIdsFor(int diatonicIndex) {
    final result = <int>[];
    for (final it in _items.values) {
      if (it.type != ItemType.relation) continue;
      final p = it.payload as RelationPayload;
      // 目标音位或链中间音（非末步的 step 目标）涉及 p（05 §4 回退重激活）。
      final midHit = p.chain
          .take(p.chain.length - 1)
          .any((s) => s.targetIndex == diatonicIndex);
      if (p.targetIndex == diatonicIndex || midHit) result.add(it.id);
    }
    return result..sort();
  }

  @override
  void saveMastery(Mastery m) {
    _masteryByItem[m.itemId] = m;
    writes.enqueue(() => _masteries.upsert(m));
  }

  /// 会话装配中途新建的条目（答错变体，02 §5.4）登记进读缓存。
  void registerItem(Item item, Mastery mastery) {
    _items[item.id] = item;
    _masteryByItem[item.id] = mastery;
  }

  Future<void> flush() => writes.flush();

  static int _tsOf(Trial t) => t.answeredAt ?? t.presentedAt;

  static TrialResult _toResult(Trial t) => TrialResult(
        correct: t.correct,
        rtMs: t.rtMs ?? 0,
        hintLevel: t.hintLevelUsed,
        ts: _tsOf(t),
      );
}

/// build 产物：引擎 + 队列计划 + 会话 id（供主程 UI 接线）。
class SessionBundle {
  final SessionEngine engine;
  final QueuePlan plan;
  final int sessionId;

  /// 本次会话执行阶段（build 开始时读取的 course_stage）。
  final int stage;
  final Set<int> activeAnchors;
  final bool diagnosisDone;
  final DbSessionDataSource source;
  final DbTrialRecorder recorder;

  /// build 末尾的阶段推进判定（canAdvance 时 course_stage 已 +1，微课下次会话）。
  final AdvanceDecision advance;

  const SessionBundle({
    required this.engine,
    required this.plan,
    required this.sessionId,
    required this.stage,
    required this.activeAnchors,
    required this.diagnosisDone,
    required this.source,
    required this.recorder,
    required this.advance,
  });

  /// 首页文案："今天没有到期复习，学点新的"（02 §6.4）。
  bool get noDueReview => plan.noDueReview;

  /// 等待全部落库（会话结束/退后台时调用）。
  Future<void> flush() => recorder.flush();
}

/// 会话装配：条目保障 → 候选收集 → buildQueue → session 落库 → 阶段推进检查。
class SessionSetup {
  static Future<SessionBundle> build({
    required Database db,
    required Config config,
    required Clock clock,
    required Rng rng,
    int? dailyCount,
    bool extraPractice = false,
    /// 试玩模式：队列只出短句（跳过热身/微课/其它段），见交付报告偏差 #19。
    bool phrasesOnly = false,
  }) async {
    final appState = AppStateRepo(db);
    final itemRepo = ItemRepo(db);
    final masteryRepo = MasteryRepo(db);

    final stage = int.tryParse(await appState.get('course_stage') ?? '') ?? 0;
    final diagnosisDone = (await appState.get('diagnosis_done') ?? '0') == '1';
    final anchorsRaw = await appState.get('active_anchors');
    final parsedAnchors = <int>{
      for (final e in jsonDecode(anchorsRaw ?? '[]') as List) e as int,
    };
    // 裁决 4：无锚点 → 跳过诊断口径 [C4,G4]（05 §8）。
    final activeAnchors = parsedAnchors.isEmpty ? {0, 4} : parsedAnchors;

    // ---- 条目保障（05 §1）：占位 id=0 → insert 真实 id → 重建 Mastery 绑定。
    final existing = await itemRepo.all();
    final toCreate = <NewItem>[
      ...ensureAnchorItems(activeAnchors, existing, clock, config: config),
      ...ensureDirectItems(existing, activeAnchors, clock, config: config),
      ...relationItemsForStage(stage, activeAnchors, existing, clock,
          config: config),
    ];
    for (final (item, m) in toCreate) {
      final id = await itemRepo.insert(item);
      await masteryRepo.upsert(Mastery(
        itemId: id,
        state: m.state,
        ease: m.ease,
        dueAt: m.dueAt,
        hintLevel: m.hintLevel,
      ));
    }

    // 自愈：早期版本把阶段 0 邻近音的初始提示级误设成微课满级（5），
    // 而级 5 按规格"记为提示完成、不计正确"——会出现答对也判错。
    // 阶段 0 的关系条目只可能是这批邻近音穿插题，高于 3 的一律压回初始级。
    if (stage == 0) {
      for (final it in existing) {
        if (it.type != ItemType.relation) continue;
        final m = await masteryRepo.byItemId(it.id);
        if (m != null && m.hintLevel > config.hintInitialLevel) {
          await masteryRepo
              .upsert(m.copyWith(hintLevel: config.hintInitialLevel));
        }
      }
    }

    // ---- 阶段>=4：生成 1 条新 PHRASE 落库（裁决 5）。
    if (stage >= 4) {
      final items = await itemRepo.all();
      final masteries = {
        for (final m in await masteryRepo.all()) m.itemId: m,
      };
      final recent = [
        for (final it in items)
          if (it.type == ItemType.phrase)
            (it.payload as PhrasePayload).noteSequence,
      ];
      final automated = <int>{
        for (final it in items)
          if ((it.type == ItemType.anchor || it.type == ItemType.direct) &&
              masteries[it.id]?.state == ItemState.automated)
            it.payload.targetIndices.first,
      };
      final gen = generatePhrase(
        stage: stage,
        rng: rng,
        recentSequences: recent,
        automatedIndices: automated,
        anchorIndices: activeAnchors,
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
    }

    // ---- 快照缓存（同步接口读口径）。
    final source = await DbSessionDataSource.load(db);
    final items = source.items;

    // ---- 候选收集（裁决 2：分桶互斥）。
    bool activeState(Mastery m) =>
        m.state == ItemState.learning ||
        m.state == ItemState.reviewing ||
        m.state == ItemState.automated;

    final newLearn = <Candidate>[];
    final direct = <Candidate>[];
    final phrase = <Candidate>[];
    final warmup = <Candidate>[];
    final excluded = <int>{};
    for (final it in items) {
      final m = source.masteryOf(it.id);
      switch (it.type) {
        case ItemType.relation:
          if (m.state == ItemState.learning && m.reps == 0) {
            newLearn.add((it, m));
            excluded.add(it.id);
          }
        case ItemType.direct:
          // 阶段 0 只做锚点建立：DIRECT 与同音位 ANCHOR 视觉完全相同（都是单音+限时），
          // 且未自动化前出 DIRECT 没有"关系推导→直认迁移"的意义（02 §4.1 的 DIRECT
          // 是迁移后的验证）。阶段 0 只出 ANCHOR + 邻近音穿插，避免同音位重复题。
          if (stage >= 1 && activeState(m)) {
            direct.add((it, m));
            excluded.add(it.id);
          }
          if (m.state == ItemState.automated) warmup.add((it, m));
        case ItemType.phrase:
          // inactive = 答错变体备胎（02 §5.4），只在预约复现时呈现，不进常规短句桶。
          if (m.state != ItemState.inactive) {
            phrase.add((it, m));
            excluded.add(it.id);
          }
        case ItemType.anchor:
          // 锚点在自动化之前都要每天出现（F1 锚点训练），
          // 包含已进入间隔复习的 reviewing —— 否则阶段 0 会出现"今天没题"。
          if (m.state == ItemState.learning ||
              m.state == ItemState.reviewing ||
              m.state == ItemState.automated) {
            warmup.add((it, m));
          }
      }
    }

    final endOfDay = clock.localEndOfDayUtcMs(clock.localDate());
    final due = <Candidate>[];
    final seenDue = <int>{};
    for (final m in await masteryRepo.dueBefore(endOfDay)) {
      if (excluded.contains(m.itemId) || !activeState(m)) continue;
      final it = source.itemById(m.itemId);
      if (it != null) {
        due.add((it, m));
        seenDue.add(it.id);
      }
    }
    // 加练模式（首页「再练一组」）：把已学过但**今天未到期**的条目也纳入复习桶。
    // 依据 02 §6.4「练得太勤时队列由新学/直认等填充」——不改变间隔阶梯与掌握判定，
    // 只是允许用户主动多练；未到期条目 overdue=0，排序自然排在到期条目之后。
    if (extraPractice) {
      for (final it in items) {
        if (excluded.contains(it.id) || seenDue.contains(it.id)) continue;
        // 阶段 0 不出 DIRECT（与同音位 ANCHOR 视觉重复），加练同样排除。
        if (stage == 0 && it.type == ItemType.direct) continue;
        final m = source.masteryOf(it.id);
        if (!activeState(m)) continue;
        due.add((it, m));
      }
    }

    // ---- 微课标记消费（上次 build 推进时置位，本次会话头部插入）。
    final microFlag =
        (await appState.get('micro_lesson_next_session') ?? '0') == '1';
    final microItems = microFlag
        ? [
            for (final it in coreItemsOf(stage, items, activeAnchors))
              (it, source.masteryOf(it.id)),
          ]
        : <Candidate>[];
    if (microFlag) await appState.set('micro_lesson_next_session', '0');

    // ---- carryover：上次被截断者本次 +1000 优先（05 §3，裁决 7）。
    final carryRaw = await appState.get('queue_carryover_ids');
    final carryover = <int>{
      for (final e in jsonDecode(carryRaw ?? '[]') as List) e as int,
    };

    if (phrasesOnly) {
      newLearn.clear();
      direct.clear();
      warmup.clear();
      due.clear();
    }

    final plan = buildQueue(
      stage: stage,
      dueItems: due,
      newItems: newLearn,
      directItems: direct,
      phraseItems: phrase,
      warmupPool: warmup,
      microLessonItems: phrasesOnly ? const [] : microItems,
      activeAnchors: activeAnchors,
      carryoverIds: carryover,
      stageAdvanced: microFlag,
      config: config,
      clock: clock,
      rng: rng,
      count: dailyCount,
      phrasesOnly: phrasesOnly,
    );
    await appState.set(
        'queue_carryover_ids', jsonEncode(plan.carryoverIds.toList()..sort()));

    // ---- session 行（02 §7 / 04 session 表）。
    final d = clock.localDate();
    final dateStr = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sessionId = await SessionRepo(db).insert(Session(
      date: dateStr,
      startedAt: clock.nowUtcMs(),
      plannedCount: plan.entries.length,
    ));

    // ---- 阶段推进检查（裁决 3：本次会话仍按 stage 执行，微课下次会话）。
    final decision = evaluateAdvance(
      stage: stage,
      items: items,
      masteries: {for (final it in items) it.id: source.masteryOf(it.id)},
      activeAnchors: activeAnchors,
      config: config,
    );
    if (decision.canAdvance) {
      await appState.set('course_stage', '${decision.nextStage}');
      await appState.set('micro_lesson_next_session', '1');
    }

    // ---- 答错变体备胎（02 §5.4）：为本次队列中的 PHRASE 条目各备 1 条变体。
    // 变体保持音程型、整体移调/镜像换音区（phrase_generator.wrongPhraseVariant），
    // 落 item 表且 mastery=inactive —— 只由 ReexposureScheduler 在整句错误率
    // > wrongPhraseThreshold 时取用（2–4 题后复现，不原题重做）。
    // 必须有真实 item id：否则 trial_log/mastery 会写入 itemId=0（数据错配）。
    final variantByOriginal = <int, (Item, Mastery)>{};
    if (stage >= 4) {
      final originals = <Item>[];
      final seen = <int>{};
      for (final e in plan.entries) {
        if (e.item.type == ItemType.phrase &&
            e.mastery.state != ItemState.inactive &&
            seen.add(e.item.id)) {
          originals.add(e.item);
        }
      }
      if (originals.isNotEmpty) {
        final allItems = await itemRepo.all();
        final masteryById = {
          for (final m in await masteryRepo.all()) m.itemId: m,
        };
        final spare = [
          for (final it in allItems)
            if (it.type == ItemType.phrase &&
                masteryById[it.id]?.state == ItemState.inactive)
              it,
        ];
        final recent = [
          for (final it in allItems)
            if (it.type == ItemType.phrase)
              (it.payload as PhrasePayload).noteSequence,
        ];
        var spareUsed = 0;
        for (final orig in originals) {
          final PhraseGenResult gen;
          try {
            gen = wrongPhraseVariant(
              orig.payload as PhrasePayload,
              rng,
              recentSequences: recent,
              config: config,
            );
          } on StateError {
            continue; // 变体生成不可行：该句退化为不预约变体（原有降级）。
          }
          final now = clock.nowUtcMs();
          Item variant;
          if (spareUsed < spare.length) {
            // 复用上次遗留的未使用备胎，避免 item 表无界增长。
            final s = spare[spareUsed++];
            await itemRepo.updatePayload(s.id, gen.payload);
            variant = Item(
              id: s.id,
              type: ItemType.phrase,
              payload: gen.payload,
              createdAt: s.createdAt,
            );
          } else {
            final id = await itemRepo.insert(Item(
              id: 0,
              type: ItemType.phrase,
              payload: gen.payload,
              createdAt: now,
            ));
            variant = Item(
              id: id,
              type: ItemType.phrase,
              payload: gen.payload,
              createdAt: now,
            );
          }
          // 落库态保持 inactive（不进常规短句桶）；呈现时按 learning 起算。
          await masteryRepo.upsert(Mastery(
            itemId: variant.id,
            state: ItemState.inactive,
            ease: config.easeInit,
            dueAt: now,
            hintLevel: 0,
          ));
          final vm = Mastery(
            itemId: variant.id,
            state: ItemState.learning,
            ease: config.easeInit,
            dueAt: now,
            hintLevel: 0,
          );
          source.registerItem(variant, vm);
          variantByOriginal[orig.id] = (variant, vm);
          recent.add(gen.payload.noteSequence);
        }
      }
    }

    final recorder = DbTrialRecorder(
      trialRepo: TrialRepo(db),
      phraseRepo: PhraseRepo(db),
      source: source,
    );
    final engine = SessionEngine(
      config: config,
      clock: clock,
      rng: rng,
      recorder: recorder,
      source: source,
      sessionId: sessionId,
      stage: stage,
      mode: config.inputMode,
      queue: plan.entries,
      reexposure: ReexposureScheduler(
        config: config,
        rng: rng,
        phraseVariantBuilder: (orig) => variantByOriginal[orig.id],
      ),
    );

    return SessionBundle(
      engine: engine,
      plan: plan,
      sessionId: sessionId,
      stage: stage,
      activeAnchors: activeAnchors,
      diagnosisDone: diagnosisDone,
      source: source,
      recorder: recorder,
      advance: decision,
    );
  }
}