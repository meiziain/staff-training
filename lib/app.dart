// 规格: 06 §1 导航 —— 首次启动 → S0 诊断引导；完成后 → S2 首页。
// 冷启动直达（无账号/广告）。M2 演示页保留为调试入口（长按标题进入）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/providers.dart';
import 'data/repositories/app_state_repo.dart';
import 'features/diagnosis/diagnosis_controller.dart';
import 'features/diagnosis/diagnosis_pages.dart';
import 'features/home/home_page.dart';

class SightReadingApp extends StatelessWidget {
  const SightReadingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '识谱训练',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.system,
      home: const _RootGate(),
    );
  }
}

class _RootGate extends ConsumerStatefulWidget {
  const _RootGate();

  @override
  ConsumerState<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<_RootGate> {
  int _gateEpoch = 0;

  @override
  void initState() {
    super.initState();
    // 启动即触发音频服务创建与 22 个采样预加载（02 §1.4），
    // 避免第一题作答时还没加载完；并按设置同步静音开关。
    ref.read(audioServiceProvider);
    unawaited(() async {
      try {
        final cfg = await ref.read(configProvider.future);
        ref.read(audioServiceProvider).muted = !cfg.audioEnabled;
      } catch (_) {
        // 配置加载失败时保持默认有声，不阻塞启动。
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    return dbAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('数据库打开失败：$e\n请从备份导入或重置（设置页后续接入）',
                textAlign: TextAlign.center),
          ),
        ),
      ),
      data: (db) => FutureBuilder<bool>(
        key: ValueKey(_gateEpoch),
        future: AppStateRepo(db)
            .get('diagnosis_done')
            .then((v) => v == '1'),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (snap.data!) return const HomePage();
          return DiagnosisFlow(
            sink: AppStateDiagnosisSink(db),
            onDone: (_) => setState(() => _gateEpoch++),
          );
        },
      ),
    );
  }
}