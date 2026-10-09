import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';

import 'trajectory_model.dart';
import 'trajectory_projection.dart';

/// D-042 轨迹的事件账本。
///
/// **为什么单独一层**：对话页是「事件 → 气泡」的降维——`ChatEventReader`
/// 认不出的类型直接丢掉。轨迹要的是反过来的东西：原样、按 `seq` 排、带
/// 轮次与请求边界。所以账本存**原始事件**，投影按需算。
///
/// 投影结果按 (首 seq, 末 seq, 条数, 是否有更早历史) 记忆化：追加只改末
/// seq、补页只改首 seq，两个方向都不会让缓存全废——长会话里每秒可能有几十
/// 次追加，全量重算会把手机烧穿。
class TrajectoryLedger {
  final List<SessionWireEvent> _events = [];
  TrajectoryProjection? _cache;
  int? _cacheFirst;
  int? _cacheLast;
  int? _cacheCount;
  bool? _cacheHasEarlier;

  /// follow 首帧的 `cursor`，`session/page` 的 `throughSeq` 只能取它
  /// （超过当前游标引擎回 `gateway/bad-request`，契约 §3.5）。
  int _cursor = -1;

  bool _hasEarlierHistory = false;
  bool _loadingEarlier = false;
  AppLedgerError? _error;

  List<SessionWireEvent> get events => List.unmodifiable(_events);
  bool get hasEarlierHistory => _hasEarlierHistory;
  bool get loadingEarlier => _loadingEarlier;
  AppLedgerError? get error => _error;
  int get cursor => _cursor;

  /// 换会话：整本账清空。
  void clear() {
    _events.clear();
    _cache = null;
    _cursor = -1;
    _hasEarlierHistory = false;
    _loadingEarlier = false;
    _error = null;
  }

  /// follow 首帧落地。
  void reset({
    required List<SessionWireEvent> records,
    required int cursor,
    required bool hasMore,
  }) {
    _events
      ..clear()
      ..addAll(records);
    _cursor = cursor;
    _hasEarlierHistory = hasMore;
    _loadingEarlier = false;
    _error = null;
    _trim();
    _invalidate();
  }

  /// 一条实时事件。`seq` 不前进就丢掉——重连重放（D-032 的周期性
  /// `$events` 重开会回放 `assistant/attempt` 等）不该在轨迹里变成两行。
  void append(SessionWireEvent event) {
    if (_events.isNotEmpty && event.seq <= _events.last.seq) return;
    _events.add(event);
    if (event.seq > _cursor) _cursor = event.seq;
    _trim();
    _invalidate();
  }

  /// 一页更早的历史插到最前面。
  void prepend(List<SessionWireEvent> records) {
    if (records.isEmpty) return;
    _events.insertAll(0, records);
    _invalidate();
  }

  /// 投影，按需重算。
  TrajectoryProjection get projection {
    final first = _events.isEmpty ? null : _events.first.seq;
    final last = _events.isEmpty ? null : _events.last.seq;
    final count = _events.length;
    final cached = _cache;
    if (cached != null &&
        _cacheFirst == first &&
        _cacheLast == last &&
        _cacheCount == count &&
        _cacheHasEarlier == _hasEarlierHistory) {
      return cached;
    }
    final built = projectTrajectory(
      _events,
      hasEarlierHistory: _hasEarlierHistory,
    );
    _cache = built;
    _cacheFirst = first;
    _cacheLast = last;
    _cacheCount = count;
    _cacheHasEarlier = _hasEarlierHistory;
    return built;
  }

  /// 往前取一页历史。
  ///
  /// 引擎的 `session.page` 是唯一的分页入口，`beforeSeq` 取本窗最早的 seq。
  /// 返回值如实反映引擎的 `hasMore`，UI 据此决定「更早」那行还在不在。
  Future<void> loadEarlier(EngineGateway gateway, SessionAddress address) async {
    if (_loadingEarlier || !_hasEarlierHistory) return;
    final oldest = _events.isEmpty ? null : _events.first.seq;
    if (oldest == null) return;
    _loadingEarlier = true;
    _error = null;
    final result = await gateway.page(
      address: address,
      throughSeq: _cursor,
      beforeSeq: oldest,
    );
    _loadingEarlier = false;
    if (!result.isOk) {
      _error = AppLedgerError(result.error!.code);
      return;
    }
    final value = asObject(result.value) ?? const {};
    // `EngineClient.page` 已经把每条记录解码成 `FollowEvent` 了（见
    // `engine.dart:167-177`），这里直接取事件，不要再按 JSON map 解一遍
    // ——解第二遍会把真实响应和测试替身走出两条不同的路径。
    final events = <SessionWireEvent>[
      for (final entry in asList(value['records']) ?? const <Object?>[])
        if (entry is FollowEvent) entry.event,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    prepend(events);
    _hasEarlierHistory = value['hasMore'] == true;
    _invalidate();
  }

  /// 窗口上限。超了就丢最老的，**并且把「有更早历史」置真**——丢掉的部分
  /// 就是真存在的更早历史，标成 false 等于骗用户说没有。
  void _trim() {
    if (_events.length <= defaultLedgerWindow) return;
    _events.removeRange(0, _events.length - defaultLedgerWindow);
    _hasEarlierHistory = true;
  }

  void _invalidate() => _cache = null;
}

/// 补页失败。单独一个类型而不是复用 `AppError`：这一层不参与全局错误码
/// 登记表，它只是「这一行点不动了」。
class AppLedgerError {
  const AppLedgerError(this.message);
  final String message;
}
