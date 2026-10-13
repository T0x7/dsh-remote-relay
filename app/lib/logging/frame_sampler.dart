import 'package:flutter/foundation.dart';

/// 帧级探针的聚合计数器（D-107）。
///
/// 之前 journal 对**每一帧**打一行 `[e2e] frame FollowAssistantStream`，
/// 而引擎流式输出时实测 130–250 帧/秒。那不是日志，是噪声源：512KB 的滚动
/// 缓冲（约 7800 行）会在**一次连续输出 30–60 秒内**被冲干净，真正要命的
/// `W/[chat] first-frame deadline hit` 反而被挤掉。
///
/// 换成「前 N 帧逐帧打 + 其后每窗口汇总一行」：
/// - [individual]（默认 3）帧仍然逐帧出现——「帧确实在来」这个证据不丢，
///   而 D-094~D-104 那一串排查靠的就是它；
/// - 之后按帧类型计数，每 [window] 汇总成一行
///   `journal frames 2.0s: FollowAssistantStream×214, FollowEvent×3`。
///
/// 30 秒满速流式输出从约 6000 行降到约 18 行，量级差三个数量级，而排障需要
/// 的信息一条不少。
///
/// **刻意不用 Timer 驱动窗口收尾**：定时器会在 widget 测试结束时留一个 pending
/// `Timer`（flutter_tools 报 "A Timer is still pending"）。窗口靠
/// [record] 里的时间比较推进，尾部残余由调用方在关流时显式 [flush]。
class FrameSampler {
  FrameSampler({
    required this.emit,
    this.window = const Duration(seconds: 2),
    this.individual = 3,
    this.maxKinds = 8,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _windowStart = _now();
  }

  /// 汇总行的去处（生产接 `AppLog.d('e2e', …)`，测试接收集器）。
  final void Function(String message) emit;

  /// 汇总窗口。窗口越长越省行，越短越接近实时。
  final Duration window;

  /// 每种帧类型前 N 帧逐帧打。
  final int individual;

  /// 帧类型种类上限；超出并进 `other`，防止异常实现刷出一屏类型名。
  final int maxKinds;

  final DateTime Function() _now;

  final Map<String, int> _counts = {};
  final Map<String, int> _individual = {};
  late DateTime _windowStart;

  /// 已缓冲但还没汇总的帧数（不含那 [individual] 帧）。守门用例的断言面。
  @visibleForTesting
  int get bufferedCount =>
      _counts.values.fold(0, (sum, value) => sum + value);

  /// 记录一帧。[kind] 通常是帧的 Dart 类型名。
  void record(String kind) {
    final seen = (_individual[kind] ?? 0) + 1;
    _individual[kind] = seen;
    if (seen <= individual) {
      emit('frame $kind');
    } else {
      final bucket = _counts.containsKey(kind) || _counts.length < maxKinds
          ? kind
          : 'other';
      _counts[bucket] = (_counts[bucket] ?? 0) + 1;
    }
    if (_now().difference(_windowStart) >= window) {
      _emitSummary();
    }
  }

  /// 收尾汇总。关流/销毁时必须调一次，否则最后一个不满窗口的窗口永远不落盘
  /// ——流式输出中途停下的那一段恰恰是最可疑的。
  void flush({String reason = 'flush'}) => _emitSummary(reason: reason);

  void _emitSummary({String reason = 'window'}) {
    final elapsed = _now().difference(_windowStart);
    _windowStart = _now();
    if (_counts.isEmpty) return;
    // 按帧数降序：排障时最想知道的是「哪种帧在刷屏」。
    final entries = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final body =
        entries.map((e) => '${e.key}×${e.value}').join(', ');
    _counts.clear();
    emit('journal frames ${_seconds(elapsed)}s ($reason): $body');
  }

  String _seconds(Duration d) =>
      d.inMilliseconds % 1000 == 0
          ? (d.inMilliseconds ~/ 1000).toString()
          : (d.inMilliseconds / 1000).toStringAsFixed(1);
}