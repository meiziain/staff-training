// 规格: 03 §2 时间约定 / 05 §0 —— 时钟一律注入，禁止裸调用 DateTime.now()。
// 内部一律 UTC 毫秒时间戳；"天"的边界按设备本地时区计算；RT 计时用单调时钟。
library;

/// 时钟接口：墙钟（UTC ms）+ 单调钟（RT 计时）+ 本地日期工具。
abstract interface class Clock {
  /// 墙钟 UTC 毫秒时间戳（dueAt、trial 时间戳等持久化时间）。
  int nowUtcMs();

  /// 单调毫秒（Stopwatch 口径），仅用于 RT / 限时计时，不可持久化比较。
  int monotonicMs();

  /// 设备本地时区的当前日期（年月日）。
  DateTime localDate();

  /// 本地日期 date 的 00:00 对应的 UTC 毫秒时间戳。
  int localMidnightUtcMs(DateTime date);

  /// 本地日期 date 的 23:59:59.999 对应的 UTC 毫秒时间戳。
  int localEndOfDayUtcMs(DateTime date);
}

/// 生产实现。
class SystemClock implements Clock {
  final Stopwatch _sw = Stopwatch()..start();

  @override
  int nowUtcMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  @override
  int monotonicMs() => _sw.elapsedMilliseconds;

  @override
  DateTime localDate() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  int localMidnightUtcMs(DateTime date) =>
      DateTime(date.year, date.month, date.day).toUtc().millisecondsSinceEpoch;

  @override
  int localEndOfDayUtcMs(DateTime date) =>
      DateTime(date.year, date.month, date.day, 23, 59, 59, 999)
          .toUtc()
          .millisecondsSinceEpoch;
}

/// 测试用假时钟：所有分量可显式设置与推进。
class FakeClock implements Clock {
  int utcMs;
  int monoMs;
  DateTime _localDate;
  final int _tzOffsetMs;

  FakeClock({
    this.utcMs = 0,
    this.monoMs = 0,
    DateTime? localDate,
    Duration tzOffset = Duration.zero,
  })  : _localDate = localDate ?? DateTime(2026, 1, 1),
        _tzOffsetMs = tzOffset.inMilliseconds;

  /// 设置本地日期（测试用）。
  void setDate(DateTime d) => _localDate = DateTime(d.year, d.month, d.day);

  @override
  int nowUtcMs() => utcMs;

  @override
  int monotonicMs() => monoMs;

  @override
  DateTime localDate() => _localDate;

  @override
  int localMidnightUtcMs(DateTime date) =>
      DateTime(date.year, date.month, date.day)
          .toUtc()
          .millisecondsSinceEpoch -
      _tzOffsetMs;

  @override
  int localEndOfDayUtcMs(DateTime date) =>
      localMidnightUtcMs(date) +
      const Duration(hours: 23, minutes: 59, seconds: 59, milliseconds: 999)
          .inMilliseconds;

  /// 同时推进墙钟与单调钟，并按需推进本地日期。
  void advance(Duration d) {
    utcMs += d.inMilliseconds;
    monoMs += d.inMilliseconds;
  }
}