// 临时度量脚本（交付后删除）：轮廓分布 / 方向惯性 / 级进比例 / 耗时 / 去重放宽。
import 'package:sight_reading/core/rng.dart';
import 'package:sight_reading/domain/models/note_position.dart';
import 'package:sight_reading/domain/models/sight_score.dart';
import 'package:sight_reading/domain/sight_generator.dart';

void main() {
  final r = rng(20261121);
  final contourCount = <String, int>{};
  var same = 0;
  var dirSteps = 0;
  final ratioList = <double>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < 1000; i++) {
    final res =
        generateSightScore(mode: SightMode.trebleOnly, rng: r, columnCount: 12);
    final key = res.contour ?? '-';
    contourCount[key] = (contourCount[key] ?? 0) + 1;
    final seq = res.score.sequenceOf(SightVoice.upper).whereType<int>().toList();
    var steps = 0;
    for (var k = 1; k < seq.length; k++) {
      final d = seq[k] - seq[k - 1];
      if (d.abs() == 1) steps++;
      if (k >= 2 && d != 0) {
        final prev = seq[k - 1] - seq[k - 2];
        dirSteps++;
        if (prev != 0 && d.sign == prev.sign) same++;
      }
    }
    ratioList.add(steps / (seq.length - 1));
  }
  sw.stop();
  ratioList.sort();
  print('treble-12: 耗时 ${sw.elapsedMilliseconds}ms / 1000 条');
  print('轮廓分布: $contourCount');
  print('方向惯性: ${(same * 100 / dirSteps).toStringAsFixed(1)}% ($same/$dirSteps)');
  print('级进比例: min=${(ratioList.first * 100).toStringAsFixed(1)}% '
      'p50=${(ratioList[500] * 100).toStringAsFixed(1)}% '
      'max=${(ratioList.last * 100).toStringAsFixed(1)}%');

  // 双手：音域触达 + 耗时
  final rg = rng(4242);
  var uMax = -99;
  var lMin = 99;
  final swg = Stopwatch()..start();
  for (var i = 0; i < 1000; i++) {
    final s = generateSightScore(mode: SightMode.grand, rng: rg).score;
    for (final x in s.sequenceOf(SightVoice.upper).whereType<int>()) {
      if (x > uMax) uMax = x;
    }
    for (final x in s.sequenceOf(SightVoice.lower).whereType<int>()) {
      if (x < lMin) lMin = x;
    }
  }
  swg.stop();
  print('grand: 耗时 ${swg.elapsedMilliseconds}ms / 1000 条, uMax=$uMax lMin=$lMin');

  // 去重放宽次数
  final rd = rng(555);
  final recent = <String>[];
  var relaxed = 0;
  final swd = Stopwatch()..start();
  for (var i = 0; i < 600; i++) {
    final res = generateSightScore(
        mode: SightMode.trebleOnly, rng: rd, columnCount: 8,
        recentSignatures: recent);
    if (res.dedupRelaxed) relaxed++;
    recent.add(sightSignature(res.score));
  }
  swd.stop();
  print('去重: relaxed=$relaxed/600 耗时 ${swd.elapsedMilliseconds}ms');
  print('mod / pool: ${mod(-1, 7)} ${poolMin}');
}
