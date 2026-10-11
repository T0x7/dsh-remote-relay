import 'dart:async';

import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:flutter/foundation.dart';

/// D-046: the machine's Workspace registry, as a live subscription.
///
/// **Machine-scoped, deliberately separate from [ChatController].** The
/// registry answers "which workspaces does this engine host"; the conversation
/// answers "what is happening in this one session". They have different
/// lifetimes — switching machines tears both down, but switching sessions must
/// not disturb the registry — and different reconnect algebra, so one stream
/// carrying both would force the slower one to gate the faster.
///
/// The subscription is opened on construction and torn down on [dispose]; the
/// console owns one per machine binding, exactly like the chat controller.
class WorkspaceRegistryController extends ChangeNotifier {
  WorkspaceRegistryController(this._gateway, {SessionTitleCache? titles})
      // 默认 inMemory（不落盘）：测试和不知道持久化的调用方拿到一个安全默认。
      // 真 App 在接线处显式传持久化版本（见 console_page.dart 的 D-062 注释）。
      : titles = titles ?? SessionTitleCache.inMemory() {
    // D-062: 标题缓存要先从磁盘恢复再开流——恢复完成时 notifyListeners 会让
    // 列表自动重绘成标题；顺序反了的话首帧先到、恢复后到，会出现一瞬间的
    // 「先显示 id 又闪成标题」。
    titles?.load();
    _open();
  }

  /// D-059: 打开过的会话的标题。共享实例，好让对话页记下的名字能回到列表上。
  final SessionTitleCache titles;

  final EngineGateway _gateway;
  final WorkspaceRegistryProjection _projection = WorkspaceRegistryProjection();

  WorkspaceFollowStream? _stream;
  StreamSubscription<WorkspaceFollowFrame>? _sub;
  StreamSubscription<Object>? _errorSub;
  bool _disposed = false;

  /// The engine's ordered workspaces. Empty until the baseline lands.
  List<WorkspaceView> get workspaces => _projection.items;

  List<String> get archivedSessionIds => _projection.archivedSessionIds;
  List<String> get pinnedSessionIds => _projection.pinnedSessionIds;

  /// True once the baseline has arrived. Distinguishes "the machine hosts no
  /// workspaces" from "we have not heard from the engine yet" — the first is a
  /// fact, the second is a wait, and the UI says different things for each.
  bool get loaded => _loaded;
  bool _loaded = false;

  Object? _error;
  Object? get error => _error;

  /// Sessions belonging to no workspace.
  ///
  /// dsh calls this `UNGROUPED_KEY` and renders it as a first-class group
  /// beside the registered ones (`ui-workspace/src/client/tree.ts:18`,
  /// `locales.ts:10` → `未分组`). The wire never sends that key, so it is
  /// computed as the complement: every session the list knows about, minus the
  /// ones a workspace claims, minus the archived.
  List<String> ungroupedSessionIds(Iterable<String> allSessionIds) {
    final claimed = _projection.claimedSessionIds;
    final archived = _projection.archivedSessionIds.toSet();
    return [
      for (final id in allSessionIds)
        if (!claimed.contains(id) && !archived.contains(id)) id,
    ];
  }

  // ------------------------------------------------- D-057: 稳定 vs 正在重算

  /// 多短时间内被改写就算「还在重算」。
  ///
  /// 实测引擎在 members 抖动期间每 4 秒重写一次 `jobs` 的 `updatedAt`；静止的
  /// 工作区则是几十分钟、几天。10 秒足够把两者分开，又不会把一次真实的成员
  /// 变更误判成抖动。
  static const _settleWindow = Duration(seconds: 10);

  /// 这台机器的成员资格是否还在被引擎重算。
  ///
  /// D-057：引擎在读取时才用懒索引过滤成员资格，索引未命中即丢弃，于是会话
  /// 随机消失（`docs/internal/engine-workspace-membership-flicker-report-20261005.md`）。
  /// 客户端改不了根因，但**可以不在引擎重算期间把一个抖动中的数字说成事实**。
  ///
  /// 只看工作区的 `updatedAt`：`archived` / `pinned` 帧在 wire 上只带 id、**没有
  /// 时间戳**（`api/workspace-controller/src/types.ts:165`），想用它们做新鲜度信号
  /// 就只能编一个假的出来。而实测里唯一每 4 秒变的就是 `updatedAt`，够用了。
  bool get isSettling {
    final stamps = [
      for (final w in _projection.items) DateTime.tryParse(w.updatedAt),
    ].whereType<DateTime>();
    if (stamps.isEmpty) return false;
    final newest = stamps.reduce((a, b) => a.isAfter(b) ? a : b);
    // 客户端时钟不可信时（用户刚改过系统时间）不因此宣布「正在同步」——
    // 一个负的差值只说明时钟问题，不说明引擎在忙。
    final age = _now().difference(newest);
    return !age.isNegative && age < _settleWindow;
  }

  final DateTime Function() _now = DateTime.now;

  /// 恢复刚推完一帧后的数据：投影层已经判过「无变化」则不通知，
  /// 免得引擎每次重写时间戳都把用户正在看的那一页重建一次。
  @visibleForTesting
  void applyFrameForTest(WorkspaceFollowFrame frame) {
    if (_projection.apply(frame)) notifyListeners();
  }

  void _open() {
    final stream = _gateway.followWorkspaces();
    _stream = stream;
    _sub = stream.frames.listen((frame) {
      if (_disposed) return;
      if (_projection.apply(frame)) {
        _loaded = true;
        _error = null;
        notifyListeners();
      } else if (frame is WorkspaceBaselineFrame) {
        _loaded = true;
        notifyListeners();
      }
    });
    _errorSub = stream.errors.listen((Object e) {
      if (_disposed) return;
      _error = e;
      notifyListeners();
    });
  }

  /// D-098: tear the subscription down and open it again.
  ///
  /// The failure screen used to be a dead end — no Scaffold, so no AppBar, no
  /// back button and no way to ask again, and the stream itself was already
  /// finished, so re-entering the page would have handed back the same dead
  /// controller. A retry has to re-**open**, not just re-read.
  Future<void> retry() async {
    if (_disposed) return;
    await _sub?.cancel();
    _sub = null;
    await _errorSub?.cancel();
    _errorSub = null;
    _stream?.dispose();
    _stream = null;
    _error = null;
    _loaded = false;
    notifyListeners();
    _open();
  }

  // ------------------------------------------------- D-055: the write side

  /// Which archived rows the page shows — the engine's own three-way choice
  /// (`ui-workspace/src/client/tree.ts:230`, `ArchivedFilter`).
  ///
  /// The names are the engine's, not ours: `default` hides archived rows,
  /// `show` mixes them back into their kept slots, `only` restricts the list
  /// **and the search** to archived rows. D-046 shipped the app with no filter
  /// at all, which pinned it permanently to `default` — and `default` alone is
  /// what made an archived session unrecoverable from the phone.
  ArchiveView get archiveView => _archiveView;
  ArchiveView _archiveView = ArchiveView.hide;

  set archiveView(ArchiveView value) {
    if (_archiveView == value) return;
    _archiveView = value;
    notifyListeners();
  }

  /// Whether a row should be drawn at all, given [archiveView].
  ///
  /// Kept beside the filter rather than in the widget so the preview rows, the
  /// drilled-in list, and the ungrouped row all ask the same question — three
  /// copies of this predicate is three places for the next filter to be missed.
  bool isVisible(String sessionId) {
    final archived = _projection.archivedSessionIds.contains(sessionId);
    return switch (_archiveView) {
      ArchiveView.hide => !archived,
      ArchiveView.show => true,
      ArchiveView.only => archived,
    };
  }

  bool isArchived(String sessionId) =>
      _projection.archivedSessionIds.contains(sessionId);

  bool isPinned(String sessionId) =>
      _projection.pinnedSessionIds.contains(sessionId);

  /// Hide a session from the grouping surfaces.
  ///
  /// [stopActivity] is the destructive one: it cancels a running desktop turn,
  /// its subagents, its background jobs and its schedules. It is never inferred
  /// — [archive] sends the plain form, and only [stopAndArchive] sends the
  /// other one, so "stop what my computer is doing" is always a separate,
  /// named tap.
  Future<EngineRpcResult> archive(String sessionId) async =>
      _write(() => _gateway.archiveSession(sessionId));

  /// The same, after stopping what the session is running.
  Future<EngineRpcResult> stopAndArchive(String sessionId) async =>
      _write(() => _gateway.archiveSession(sessionId, stopActivity: true));

  /// Bring an archived session back. Never refused for activity, and never
  /// restores a pin — the engine dropped it in the same write that archived the
  /// session, and unarchiving does not undo that.
  Future<EngineRpcResult> unarchive(String sessionId) async =>
      _write(() => _gateway.unarchiveSession(sessionId));

  Future<EngineRpcResult> pin(String sessionId) async =>
      _write(() => _gateway.pinSession(sessionId));

  Future<EngineRpcResult> unpin(String sessionId) async =>
      _write(() => _gateway.unpinSession(sessionId));

  /// Install the engine's answer, then let the list refresh.
  ///
  /// All four verbs answer with the **complete** resulting set rather than a
  /// delta, so the response is installed wholesale. Patching our own guess
  /// would be a second source of truth for a fact the engine already decided
  /// — and the `follow` stream will confirm it a moment later anyway.
  Future<EngineRpcResult> _write(
    Future<EngineRpcResult> Function() call,
  ) async {
    final result = await call();
    if (result.isOk) {
      final value = asObject(result.value);
      final archived = value?['archivedSessionIds'];
      final pinned = value?['pinnedSessionIds'];
      if (archived is List) _projection.setArchived(_ids(archived));
      if (pinned is List) _projection.setPinned(_ids(pinned));
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  static List<String> _ids(List<Object?> raw) => [
        for (final id in raw)
          if (id is String) id,
      ];

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _errorSub?.cancel();
    _stream?.dispose();
    super.dispose();
  }
}

/// How archived rows are shown. Mirrors the engine's `ArchivedFilter`.
enum ArchiveView {
  /// Archived rows are hidden. The engine's default, and D-046's only mode.
  hide,

  /// Archived rows are mixed back in, greyed, in their original slots.
  show,

  /// Only archived rows, and search is restricted to them too.
  only,
}
