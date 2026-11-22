// 规格: 08 T11 诊断评分（6 行用例）/ 05 §8 / 02 §2.1。
import 'dart:convert';

import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/diagnosis.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/note_position.dart';

const config = Config.defaults;

List<DiagTrial> trials(int correctCount, int total, int rtMs) => [
      for (var i = 0; i < total; i++)
        DiagTrial(correct: i < correctCount, rtMs: rtMs),
    ];

Map<int, List<DiagTrial>> blockA({
  List<DiagTrial>? c4,
  List<DiagTrial>? g4,
  List<DiagTrial>? f3,
  List<DiagTrial>? c5,
  List<DiagTrial>? c3,
}) =>
    {
      0: c4 ?? trials(3, 6, 900),
      4: g4 ?? trials(3, 6, 900),
      -4: f3 ?? trials(3, 6, 900),
      7: c5 ?? trials(3, 6, 900),
      -7: c3 ?? trials(3, 6, 900),
    };

void main() {
  group('T11 诊断评分', () {
    test('行1: C4/G4/F3 达标且 RT 依次最快 → anchors=[0,4,-4]', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(
          c4: trials(6, 6, 600),
          g4: trials(5, 6, 800),
          f3: trials(5, 6, 1000),
          c5: trials(3, 6, 400),
          c3: trials(3, 6, 400),
        ),
        blockBTrials: trials(6, 6, 1500),
        hintRequests: 0,
      );
      expect(r.anchors, [0, 4, -4]);
      expect(r.blockA[0]!.pass, true);
      expect(r.blockA[7]!.pass, false);
      expect(r.blockA[7]!.acc, closeTo(0.5, 1e-9));
    });

    test('行2: 仅 C4 达标 → anchors 含 C4 且不重复（全取达标者+C4）', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(c4: trials(6, 6, 700)),
        blockBTrials: trials(3, 6, 2000),
        hintRequests: 3,
      );
      expect(r.anchors, [0]);
      expect(r.anchors.toSet().length, r.anchors.length);
    });

    test('行3a: 4 个达标（含 C4）→ 取 RT 最快 4 个，C4 必入', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(
          c4: trials(6, 6, 900),
          g4: trials(6, 6, 600),
          f3: trials(6, 6, 700),
          c5: trials(6, 6, 800),
        ),
        blockBTrials: trials(6, 6, 1500),
        hintRequests: 0,
      );
      expect(r.anchors, [4, -4, 7, 0]);
    });

    test('行3b: 5 个达标且 C4 最慢 → 前 4 挤掉最慢者补 C4', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(
          c4: trials(6, 6, 1200),
          g4: trials(6, 6, 500),
          f3: trials(6, 6, 600),
          c5: trials(6, 6, 700),
          c3: trials(6, 6, 800),
        ),
        blockBTrials: trials(6, 6, 1500),
        hintRequests: 0,
      );
      expect(r.anchors, [4, -4, 7, 0]);
    });

    test('行3c: 4 个达标但 C4 未达标 → C4 仍必入，挤掉最慢达标者', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(
          g4: trials(6, 6, 500),
          f3: trials(6, 6, 600),
          c5: trials(6, 6, 700),
          c3: trials(6, 6, 800),
        ),
        blockBTrials: trials(6, 6, 1500),
        hintRequests: 0,
      );
      expect(r.anchors, [4, -4, 7, 0]);
      expect(r.blockA[0]!.pass, false);
    });

    test('行4: 块B acc=0.83 提示 1 次 → startStage=2', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(c4: trials(6, 6, 700)),
        blockBTrials: trials(5, 6, 1800),
        hintRequests: 1,
      );
      expect(r.blockB!.acc, closeTo(5 / 6, 1e-9));
      expect(r.startStage, 2);
    });

    test('行5: 块B acc=0.83 提示 2 次 → startStage=1', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(c4: trials(6, 6, 700)),
        blockBTrials: trials(5, 6, 1800),
        hintRequests: 2,
      );
      expect(r.startStage, 1);
    });

    test('行6: 跳过诊断 → anchors=[0,4]，startStage=0', () {
      final r = DiagnosisResult.skipped();
      expect(r.anchors, [0, 4]);
      expect(r.startStage, 0);
      final j = jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;
      expect(j['anchors'], [0, 4]);
      expect(j['startStage'], 0);
    });
  });

  group('块A 评分口径', () {
    test('acc 与 rtMedian（偶数条取中间两值平均）', () {
      final ts = [
        for (var i = 0; i < 6; i++)
          DiagTrial(correct: i < 5, rtMs: 500 + i * 100),
      ];
      final s = scoreAnchor(ts, config);
      expect(s.acc, closeTo(5 / 6, 1e-9));
      expect(s.rtMedian, 750.0);
      expect(s.pass, true);
    });

    test('acc 恰好 0.8 达标（>= 边界）', () {
      final s = scoreAnchor(
        [
          for (var i = 0; i < 5; i++)
            DiagTrial(correct: i < 4, rtMs: 800),
        ],
        config,
      );
      expect(s.acc, 0.8);
      expect(s.pass, true);
    });
  });

  group('块C 结构先验选题', () {
    test('8 题覆盖三类先验，音位合法，C4 两种呈现为同、C4/C5 为异', () {
      final probes = buildConfusionProbes(config, rng(7));
      expect(probes.length, config.diagConfusionTrials);
      for (final p in probes) {
        expect(inPool(p.indexA), true);
        expect(inPool(p.indexB), true);
        expect(canClef(p.indexA, p.clefA), true);
        expect(canClef(p.indexB, p.clefB), true);
      }
      final c4Cross = probes.where((p) =>
          p.indexA == 0 && p.indexB == 0 && p.clefA != p.clefB);
      expect(c4Cross, isNotEmpty);
      expect(c4Cross.first.same, true);
      final c4Octave = probes.where((p) =>
          (p.indexA == 0 && p.indexB == 7) ||
          (p.indexA == 7 && p.indexB == 0));
      expect(c4Octave, isNotEmpty);
      expect(c4Octave.first.same, false);
      expect(probes.where((p) => (p.indexA - p.indexB).abs() == 1),
          isNotEmpty);
    });

    test('固定种子可复现', () {
      final a = buildConfusionProbes(config, rng(42));
      final b = buildConfusionProbes(config, rng(42));
      expect(jsonEncode(a.map((e) => e.toJson()).toList()),
          jsonEncode(b.map((e) => e.toJson()).toList()));
    });

    test('错误对 → seedPair（sort 后 pairA<=pairB，去重）', () {
      const probes = [
        ConfusionProbe(
            indexA: 7, clefA: Clef.treble, indexB: 0, clefB: Clef.treble),
        ConfusionProbe(
            indexA: 0, clefA: Clef.treble, indexB: 0, clefB: Clef.bass),
        ConfusionProbe(
            indexA: 4, clefA: Clef.treble, indexB: 5, clefB: Clef.treble),
      ];
      final seeds = seedsFromAnswers(probes, [false, false, true]);
      expect(seeds.length, 2);
      expect(seeds[0].pairA, 0);
      expect(seeds[0].pairB, 0);
      expect(seeds[1].pairA, 4);
      expect(seeds[1].pairB, 5);
    });
  });

  group('diagnosis_result JSON', () {
    test('序列化往返一致', () {
      final r = scoreDiagnosis(
        blockATrials: blockA(
          c4: trials(6, 6, 600),
          g4: trials(5, 6, 800),
          f3: trials(5, 6, 1000),
        ),
        blockBTrials: trials(5, 6, 1800),
        hintRequests: 1,
        seeds: [SeedPair.sorted(5, 4)],
      );
      final j = jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;
      expect(j['anchors'], [0, 4, -4]);
      expect(j['startStage'], 2);
      expect((j['blockA'] as Map)['0']['pass'], true);
      expect((j['blockB'] as Map)['hintRequests'], 1);
      expect((j['seeds'] as List).first, {'pairA': 4, 'pairB': 5});
      final back = DiagnosisResult.fromJson(j);
      expect(back.anchors, r.anchors);
      expect(back.startStage, r.startStage);
      expect(back.blockA[0]!.rtMedian, r.blockA[0]!.rtMedian);
      expect(back.blockB!.acc, r.blockB!.acc);
      expect(back.seeds, r.seeds);
    });
  });
}