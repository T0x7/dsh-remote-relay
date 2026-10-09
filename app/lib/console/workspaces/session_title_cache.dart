import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D-059：会话 id → 标题。
///
/// **为什么只有打开过的会话才有标题。** 工作区注册表在 wire 上就不带标题：
/// `WorkspaceView.sessionIds` 是 `readonly SessionId[]`（引擎
/// `workspace/workspace/src/types.ts:56`），`SessionSummary` 里也没有 title
/// 字段。dsh web 之所以能显示标题，是因为它读另一个 namespace
/// ——`session-reference` 的 `@Remote('candidates')`（其
/// `SessionReferenceCandidate.label` 明确写着「Latest log-backed title」），
/// 那是 SPA 常驻连接才负担得起的查询。
///
/// 我们走的是「轮询式、按需打开」，付不起 1500 个会话的 title 查询。但
/// `session/follow` 的**首帧 header 里带 `title`**（`SessionHeader.title`），
/// 而用户为了看这个会话已经付过那笔请求了——顺手记下来是零成本。
///
/// **D-062：必须持久化。** 第一版是纯内存 Map，真机上立刻暴露：App 重启后
/// 之前打开过的会话全部退回显示 id——用户眼中的症状正是「为什么工作区里只有
/// session-xxxx 没有 title」。标题不是秘密（就是会话名），不值得放 secure
/// storage；`SharedPreferences` 零新依赖（引擎本身就是它）且随 App 存活。
class SessionTitleCache extends ChangeNotifier {
  SessionTitleCache({SharedPreferencesAsync? storage})
      : _storage = storage ?? SharedPreferencesAsync();

  /// 内存态构造（测试用）：不落盘，`remember` 只改内存。widget 测试没有
  /// 平台通道，`SharedPreferencesAsync` 在那里直接抛错。
  SessionTitleCache.inMemory() : _storage = _NullStorage();

  static const _storageKey = 'dsh_remote.sessionTitles.v1';

  final SharedPreferencesAsync _storage;

  /// 测试用：让第二个 cache 指向同一份存储，模拟「重启后恢复」。
  @visibleForTesting
  SharedPreferencesAsync get storage => _storage;
  final Map<String, String> _titles = {};

  /// 持久化是否已加载完成。构造函数不能 await，所以加载是异步的；列表在
  /// 加载完成前会先显示 id，加载完成后自动重绘（[notifyListeners]）。
  bool get loaded => _loaded;
  bool _loaded = false;

  /// Known titles, keyed by session id. Read-only: callers go through
  /// [remember] so the list still repaints.
  Map<String, String> get titles => Map.unmodifiable(_titles);

  int get length => _titles.length;

  /// 从磁盘恢复。App 启动时调一次；失败时按空缓存继续（和 `hydrate` 家族
  /// 同一纪律：降级要有声，不能静默吞掉）。
  Future<void> load() async {
    try {
      final raw =
          await _storage.getStringList(_storageKey) ?? const <String>[];
      for (final line in raw) {
        final i = line.indexOf('\u241F'); // ␟ unit separator，标题里不会有
        if (i <= 0) continue;
        _titles[line.substring(0, i)] = line.substring(i + 1);
      }
      _loaded = true;
      notifyListeners();
    } on Object catch (e) {
      // 存量坏了 ≠ 没有标题：从空开始重新攒，比让整个列表卡死强。
      _loaded = true;
      notifyListeners();
      // D-054 的教训：静默的 catch 是那次「偏好凭空消失」查不到根因的直接
      // 原因。这里哪怕只是 debugPrint，也比无声吞掉强。
      AppLog.w('title-cache', 'load failed: $e');
    }
  }

  /// Record a header title. Blank titles are ignored on purpose: a header with
  /// an empty `title` is a session that has not been named yet, and storing
  /// that would replace a perfectly readable `job-cnradar-2026…` id with
  /// nothing at all.
  Future<void> remember(String sessionId, String? title) async {
    final trimmed = title?.trim();
    if (sessionId.isEmpty || trimmed == null || trimmed.isEmpty) return;
    if (_titles[sessionId] == trimmed) return;
    _titles[sessionId] = trimmed;
    notifyListeners();
    await _persist();
  }

  /// What to render for [sessionId]: its title when one is known, else the id.
  String titleOf(String sessionId, {Map<String, String>? titles}) {
    final source = titles ?? _titles;
    final t = source[sessionId]?.trim();
    if (t == null || t.isEmpty) return sessionId;
    return t;
  }

  /// 落盘。存成 `id␟title` 的字符串列表：条目量级是「用户打开过的会话」，
  /// 几十到几百，远不到需要数据库的程度。
  Future<void> _persist() async {
    final raw = [
      for (final e in _titles.entries) '${e.key}\u241F${e.value}',
    ];
    try {
      await _storage.setStringList(_storageKey, raw);
    } on Object catch (e) {
      AppLog.w('title-cache', 'persist failed: $e');
    }
  }
}

/// 永远写不进去的假存储：`SessionTitleCache.inMemory` 用。
class _NullStorage implements SharedPreferencesAsync {
  @override
  Future<List<String>?> getStringList(String key) async => null;

  @override
  Future<void> setStringList(String key, List<String> value) async {}

  @override
  noSuchMethod(Invocation invocation) async => null;
}
