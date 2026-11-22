// 规格: 05 §0 —— 随机源一律注入 Rng(seed)，禁止裸调用 Random()。
library;

import 'dart:math';

/// 随机源接口（可注入固定种子复现）。
abstract interface class Rng {
  /// [0, max) 均匀整数。
  int nextInt(int max);

  /// [0, 1) 均匀浮点。
  double nextDouble();

  /// [min, max] 闭区间均匀整数（05 §3 randInt(2,4) 口径）。
  int randInt(int min, int max);

  /// 以概率 p 返回 true。
  bool chance(double p);

  /// 从非空列表均匀取一个。
  T pick<T>(List<T> items);
}

/// 确定性种子实现（dart:math Random(seed)）。
class SeededRng implements Rng {
  final Random _r;
  SeededRng(int seed) : _r = Random(seed);

  @override
  int nextInt(int max) => _r.nextInt(max);

  @override
  double nextDouble() => _r.nextDouble();

  @override
  int randInt(int min, int max) => min + _r.nextInt(max - min + 1);

  @override
  bool chance(double p) => _r.nextDouble() < p;

  @override
  T pick<T>(List<T> items) => items[_r.nextInt(items.length)];
}

/// 规格: 05 §0 —— Rng(seed) 工厂写法。
Rng rng(int seed) => SeededRng(seed);