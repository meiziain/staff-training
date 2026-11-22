// 规格: 08 P1 短句生成器性质测试（固定种子各跑 1000 次）/ 05 §6 / 02 §5.1 §5.3。
import 'package:test/test.dart';
import 'package:sight_reading/core/config.dart';
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/enums.dart';
import 'package:sight_reading/domain/models/item.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/phrase_generator.dart';

const config = Config.defaults;

List<int> intervals(List<int> seq) =>
    [for (var i = 1; i < seq.length; i++) seq[i] - seq[i - 1]];

bool seqEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void checkHard(PhrasePayload p) {
  final seq = p.noteSequence;
  expect(seq.length, p.clefSequence.length);
  var steps = 0;
  var switches = 0;
  for (var i = 0; i < seq.length; i++) {
    expect(inPool(seq[i]), true, reason: '音位越界: $seq');
    expect(canClef(seq[i], p.clefSequence[i]), true,
        reason: '音位与谱表不符: $seq / ${p.clefSequence}');
  }
  for (var i = 1; i < seq.length; i++) {
    final d = (seq[i] - seq[i - 1]).abs();
    expect(d >= 1 && d <= 2, true, reason: '出现 >三度跳进或停滞: $seq');
    if (d == 1) steps++;
    if (p.clefSequence[i] != p.clefSequence[i - 1]) {
      switches++;
      expect(seq[i], 0, reason: '谱表切换点必为 C4: $seq');
    }
  }
  expect(switches <= 1, true, reason: '全句最多一次谱表切换: $seq');
  expect(steps / (seq.length - 1) >= config.phraseStepMinRatio, true,
      reason: '级进比例不足: $seq');
}

void main() {
  group('P1 generatePhrase 性质（固定种子 1000 次）', () {
    test('阶段4：长度3、全高音谱表、硬约束、去重（放宽有标记）', () {
      final r = rng(2026);
      const automated = {0, 2, 4, 5, 7, 9, 11, 12};
      const anchors = {0, 4};
      final union = {...automated, ...anchors};
      final recent = <List<int>>[];
      for (var i = 0; i < 1000; i++) {
        final res = generatePhrase(
          stage: 4,
          rng: r,
          recentSequences: recent,
          automatedIndices: automated,
          anchorIndices: anchors,
        );
        final p = res.payload;
        expect(p.noteSequence.length, config.phraseLenStage4);
        expect(p.clefSequence.every((c) => c == Clef.treble), true);
        expect(union.contains(p.noteSequence.first), true,
            reason: '首音须来自已自动化∪锚点');
        checkHard(p);
        if (!res.dedupRelaxed) {
          expect(recent.any((s) => seqEq(s, p.noteSequence)), false,
              reason: '未放宽却与最近20条重复');
        }
        recent.add(p.noteSequence);
        if (recent.length > config.phraseDedupWindow) recent.removeAt(0);
      }
    });

    test('阶段5：长度4-5、跨谱表仅阶段5且支点C4、硬约束、去重', () {
      final r = rng(7);
      const automated = {0, 4, 7, -4, -7};
      const anchors = {0, 4, -4, -7};
      final union = {...automated, ...anchors};
      final recent = <List<int>>[];
      var crossCount = 0;
      for (var i = 0; i < 1000; i++) {
        final res = generatePhrase(
          stage: 5,
          rng: r,
          recentSequences: recent,
          automatedIndices: automated,
          anchorIndices: anchors,
        );
        final p = res.payload;
        expect(p.noteSequence.length,
            inInclusiveRange(config.phraseLenStage5Min, config.phraseLenStage5Max));
        expect(union.contains(p.noteSequence.first), true);
        checkHard(p);
        final hasTreble = p.clefSequence.contains(Clef.treble);
        final hasBass = p.clefSequence.contains(Clef.bass);
        if (hasTreble && hasBass) {
          crossCount++;
          final k = p.clefSequence
              .indexWhere((c) => c != p.clefSequence.first);
          expect(p.noteSequence[k], 0, reason: '跨谱表支点必为 C4');
        }
        if (!res.dedupRelaxed) {
          expect(recent.any((s) => seqEq(s, p.noteSequence)), false);
        }
        recent.add(p.noteSequence);
        if (recent.length > config.phraseDedupWindow) recent.removeAt(0);
      }
      expect(crossCount > 0, true, reason: '1000 次应出现跨谱表句');
    });

    test('去重放宽：候选空间被最近20条占满 → 放宽且标记，硬约束不放宽', () {
      // 阶段4、起点{0,4}、级进比例强制全级进时全部可能序列仅 6 条。
      final recent = <List<int>>[
        [0, 1, 0],
        [0, 1, 2],
        [4, 3, 2],
        [4, 3, 4],
        [4, 5, 4],
        [4, 5, 6],
      ];
      final res = generatePhrase(
        stage: 4,
        rng: rng(99),
        recentSequences: recent,
        automatedIndices: const {0, 4},
        anchorIndices: const {0, 4},
      );
      expect(res.dedupRelaxed, true);
      checkHard(res.payload);
      expect(recent.any((s) => seqEq(s, res.payload.noteSequence)), true);
    });

    test('无冲突时不放宽', () {
      final res = generatePhrase(
        stage: 4,
        rng: rng(1),
        automatedIndices: const {0, 4},
        anchorIndices: const {0, 4},
      );
      expect(res.dedupRelaxed, false);
    });
  });

  group('P1 wrongPhraseVariant（固定种子 1000 次）', () {
    void runVariant(PhrasePayload original, int seed) {
      final r = rng(seed);
      final origIv = intervals(original.noteSequence);
      for (var i = 0; i < 1000; i++) {
        final res = wrongPhraseVariant(original, r);
        final p = res.payload;
        expect(p.noteSequence.length, original.noteSequence.length);
        final iv = intervals(p.noteSequence);
        final transposed = seqEq(iv, origIv);
        final mirrored = seqEq(iv, origIv.map((e) => -e).toList());
        expect(transposed || mirrored, true,
            reason: '音程序列必须保持（移调同号/镜像反号）: '
                '${original.noteSequence} → ${p.noteSequence}');
        if (transposed) {
          final shift = (p.noteSequence.first - original.noteSequence.first).abs();
          expect(shift, inInclusiveRange(2, 4),
              reason: '移调幅度须为 ±2..4 自然音级');
        } else {
          expect(p.noteSequence.first, original.noteSequence.first,
              reason: '首音镜像保持首音');
        }
        expect(seqEq(p.noteSequence, original.noteSequence), false,
            reason: '变体不得与原句相同');
        checkHard(p);
      }
    }

    test('单谱表原句 [4,5,6]', () {
      runVariant(
        PhrasePayload(
          noteSequence: [4, 5, 6],
          clefSequence: [Clef.treble, Clef.treble, Clef.treble],
        ),
        11,
      );
    });

    test('跨谱表原句 [2,1,0,-1]', () {
      runVariant(
        PhrasePayload(
          noteSequence: [2, 1, 0, -1],
          clefSequence: [Clef.treble, Clef.treble, Clef.bass, Clef.bass],
        ),
        22,
      );
    });

    test('跨谱表原句 [3,2,1,0,-1]（含移调后仍跨谱表的支点拆分）', () {
      runVariant(
        PhrasePayload(
          noteSequence: [3, 2, 1, 0, -1],
          clefSequence: [
            Clef.treble,
            Clef.treble,
            Clef.treble,
            Clef.bass,
            Clef.bass
          ],
        ),
        33,
      );
    });

    test('越界换移调方向：原句贴近池上界', () {
      final res = wrongPhraseVariant(
        PhrasePayload(
          noteSequence: [12, 13, 14],
          clefSequence: [Clef.treble, Clef.treble, Clef.treble],
        ),
        rng(44),
      );
      checkHard(res.payload);
      expect(seqEq(intervals(res.payload.noteSequence), [1, 1]) ||
          seqEq(intervals(res.payload.noteSequence), [-1, -1]), true);
    });
  });

  group('短句稳定性辅助（02 §5.3）', () {
    test('复位依赖 >1 次/句不判稳定', () {
      expect(phraseResetAllowsStable(0), true);
      expect(phraseResetAllowsStable(1), true);
      expect(phraseResetAllowsStable(2), false);
      expect(phraseResetAllowsStable(5), false);
    });
  });
}