// 规格: 06 §1 §2（S0/S1/S1R）§5 —— 诊断三屏 + 集成用 Flow 包装。
// 页面独立可测：WelcomePage/ReportPage 纯回调；DiagnosisPage 只依赖 controller。
// DiagnosisFlow 为 M3 主程集成入口（configProvider/clockProvider 装配 controller）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/rng.dart';
import '../../domain/diagnosis.dart';
import '../../domain/models/note_position.dart';
import '../../ui/name_buttons.dart';
import '../../ui/staff_view.dart';
import 'diagnosis_controller.dart';

/// S0 欢迎与诊断引导（06 §2）。
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onStart, required this.onSkip});

  final VoidCallback onStart;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '锚点关系读谱训练',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Text(
                '入门诊断 · 约 6 分钟',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                '测一测你的锚点再认速度、关系推导策略与易混音对，'
                '为你定制初始锚点集与起始阶段。诊断过程无对错反馈。',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              FilledButton(
                key: const ValueKey('start_diagnosis'),
                onPressed: onStart,
                child: const Text('开始诊断'),
              ),
              const SizedBox(height: 12),
              TextButton(
                key: const ValueKey('skip_diagnosis'),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('将从锚点建立开始，可随时在设置重置'),
                  ));
                  onSkip();
                },
                child: const Text('跳过'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// S1 诊断流程（块A→B→C 连续，06 §2）。
class DiagnosisPage extends StatefulWidget {
  const DiagnosisPage({
    super.key,
    required this.controller,
    this.onFinished,
    this.onAborted,
  });

  final DiagnosisController controller;
  final void Function(DiagnosisResult result)? onFinished;
  final VoidCallback? onAborted;

  @override
  State<DiagnosisPage> createState() => _DiagnosisPageState();
}

class _DiagnosisPageState extends State<DiagnosisPage> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (c.needsOnset) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) c.markOnset();
          });
        }
        if (c.phase == DiagPhase.done && c.result != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onFinished?.call(c.result!);
          });
        }
        if (c.phase == DiagPhase.aborted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onAborted?.call();
          });
        }
        return Scaffold(
          appBar: AppBar(
            title: Text('${c.blockLabel}  ${c.displayIndex}/${c.blockTotal}'),
            leading: IconButton(
              key: const ValueKey('exit_diagnosis'),
              icon: const Icon(Icons.close),
              tooltip: '退出诊断',
              onPressed: c.abort,
            ),
          ),
          body: _body(c),
        );
      },
    );
  }

  Widget _body(DiagnosisController c) {
    switch (c.phase) {
      case DiagPhase.idle:
      case DiagPhase.done:
      case DiagPhase.aborted:
        return const SizedBox.shrink();
      case DiagPhase.blank:
        // 题间空屏：不提前显示下一题（06 §2 S1）。
        return const SizedBox.expand(key: ValueKey('diag_blank'));
      case DiagPhase.showing:
      case DiagPhase.presenting:
      case DiagPhase.awaitingAnswer:
        return Column(
          children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _staff(c),
              ),
            ),
            if (c.block == DiagBlock.strategy) _hintArea(c),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: c.block == DiagBlock.confusion
                  ? _sameDifferentButtons(c)
                  : NameButtons(
                      enabled: c.answerEnabled,
                      onAnswer: c.answerName,
                    ),
            ),
            const SizedBox(height: 16),
          ],
        );
    }
  }

  Widget _staff(DiagnosisController c) {
    if (c.block == DiagBlock.confusion) {
      final p = c.probe!;
      final (clef, positions) = switch (c.confusionStage) {
        ConfusionStage.first => (p.clefA, [p.indexA]),
        ConfusionStage.gap => (p.clefA, const <int>[]),
        ConfusionStage.second || ConfusionStage.answer => (
            p.clefB,
            [p.indexB]
          ),
      };
      return StaffView(
        clef: clef,
        positions: positions,
        jitterSeed: c.jitterSeed,
      );
    }
    return StaffView(
      clef: c.clef,
      positions: [c.currentNote!],
      jitterSeed: c.jitterSeed,
      anchorOverlay: c.block == DiagBlock.strategy
          ? StaffAnchorOverlay(
              index: c.anchorIndex!,
              label: NotePosition.of(c.anchorIndex!).displayName,
            )
          : null,
    );
  }

  Widget _hintArea(DiagnosisController c) {
    final t = c.strategyTrial;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          if (c.hintLevel >= 1 && t != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(t.upward ? Icons.arrow_upward : Icons.arrow_downward),
                const SizedBox(width: 4),
                Text(t.upward ? '目标在锚点上方' : '目标在锚点下方'),
              ],
            ),
          if (c.hintLevel >= 2 && t != null)
            Text('距离锚点 ${t.steps} 步（${t.steps == 1 ? "二度" : "三度"}）'),
          TextButton(
            key: const ValueKey('request_hint'),
            onPressed: c.answerEnabled && c.hintLevel < 2 ? c.requestHint : null,
            child: const Text('请求提示'),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _sameDifferentButtons(DiagnosisController c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        OutlinedButton(
          key: const ValueKey('same_button'),
          onPressed: c.answerEnabled ? () => c.answerSame(true) : null,
          child: const Text('相同'),
        ),
        const SizedBox(width: 16),
        OutlinedButton(
          key: const ValueKey('different_button'),
          onPressed: c.answerEnabled ? () => c.answerSame(false) : null,
          child: const Text('不同'),
        ),
      ],
    );
  }
}

/// S1R 诊断报告（06 §2）。
class DiagnosisReportPage extends StatelessWidget {
  const DiagnosisReportPage({
    super.key,
    required this.result,
    required this.onDone,
  });

  final DiagnosisResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = result.blockA.entries.toList();
    final maxRt = entries.fold<double>(
      1,
      (m, e) => e.value.rtMedian != null && e.value.rtMedian! > m
          ? e.value.rtMedian!
          : m,
    );
    final b = result.blockB;
    return Scaffold(
      appBar: AppBar(title: const Text('诊断报告')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('候选锚点表现',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final e in entries)
              _anchorRow(context, e.key, e.value, maxRt),
            const SizedBox(height: 16),
            Text('策略结论', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              b == null
                  ? '未进行策略探测。'
                  : result.startStage >= 2
                      ? '已能从锚点推导，建议直接从三度（阶段 2）开始。'
                      : '建议从二度推导（阶段 1）开始，逐步建立锚点关系。',
            ),
            if (b != null)
              Text(
                '策略题正确率 ${(b.acc * 100).round()}% · 请求提示 ${b.hintRequests} 次',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: 16),
            Text('易混对种子', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (result.seeds.isEmpty)
              const Text('未发现明显易混对。')
            else
              for (final s in result.seeds)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${NotePosition.of(s.pairA).displayName} ↔ '
                    '${NotePosition.of(s.pairB).displayName}',
                    key: ValueKey('seed_${s.pairA}_${s.pairB}'),
                  ),
                ),
            const SizedBox(height: 16),
            Text('起始阶段', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('起始阶段：阶段 ${result.startStage}'),
            Text(
              '锚点全部自动化前，实际训练将从锚点建立（阶段 0）开始。',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('start_training'),
              onPressed: onDone,
              child: const Text('开始训练'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _anchorRow(
      BuildContext context, int index, AnchorBlockScore score, double maxRt) {
    final scheme = Theme.of(context).colorScheme;
    final isAnchor = result.anchors.contains(index);
    final rt = score.rtMedian;
    return Container(
      key: ValueKey('report_anchor_$index'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: isAnchor ? scheme.primary : scheme.outlineVariant,
          width: isAnchor ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(NotePosition.of(index).displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (isAnchor)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  color: scheme.primary,
                  child: Text('初始锚点',
                      style: TextStyle(fontSize: 11, color: scheme.onPrimary)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _bar('正确率', score.acc, '${(score.acc * 100).round()}%', scheme),
          _bar(
            'RT',
            rt == null ? 0 : (rt / maxRt).clamp(0.0, 1.0),
            rt == null ? '—' : '${rt.round()}ms',
            scheme,
          ),
        ],
      ),
    );
  }

  Widget _bar(
      String label, double factor, String value, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 44, child: Text(label, style: const TextStyle(fontSize: 12))),
          SizedBox(
            width: 140,
            height: 8,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: factor.clamp(0.0, 1.0),
                child: Container(color: scheme.primary),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// M3 集成入口：S0 → S1 → S1R → onDone(result)。
/// config 来自 configProvider，时钟来自 clockProvider；
/// sink/delayer/seed 由调用方注入（测试传假实现）。
class DiagnosisFlow extends ConsumerStatefulWidget {
  const DiagnosisFlow({
    super.key,
    required this.sink,
    this.delayer,
    this.seed = 1,
    this.onDone,
    this.onAborted,
  });

  final DiagnosisSink sink;
  final Delayer? delayer;
  final int seed;
  final void Function(DiagnosisResult result)? onDone;
  final VoidCallback? onAborted;

  @override
  ConsumerState<DiagnosisFlow> createState() => DiagnosisFlowState();
}

enum _FlowScreen { welcome, running, report }

class DiagnosisFlowState extends ConsumerState<DiagnosisFlow> {
  DiagnosisController? controller;
  _FlowScreen _screen = _FlowScreen.welcome;

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configProvider);
    return configAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('配置加载失败：$e'))),
      data: (config) => _build(config),
    );
  }

  Widget _build(Config config) {
    final c = controller ??= DiagnosisController(
      config: config,
      clock: ref.read(clockProvider),
      delayer: widget.delayer ?? const RealDelayer(),
      sink: widget.sink,
      rng: rng(widget.seed),
    );
    return switch (_screen) {
      _FlowScreen.welcome => WelcomePage(
          onStart: () {
            setState(() => _screen = _FlowScreen.running);
            c.start();
          },
          onSkip: () async {
            await c.skip();
            if (mounted) widget.onDone?.call(c.result!);
          },
        ),
      _FlowScreen.running => DiagnosisPage(
          controller: c,
          onFinished: (_) {
            if (mounted) setState(() => _screen = _FlowScreen.report);
          },
          onAborted: () {
            if (mounted) widget.onAborted?.call();
          },
        ),
      _FlowScreen.report => DiagnosisReportPage(
          result: c.result!,
          onDone: () => widget.onDone?.call(c.result!),
        ),
    };
  }
}