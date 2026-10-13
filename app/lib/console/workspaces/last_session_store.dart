import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D-109：每台机器「上次看的会话」。
///
/// **为什么需要它。** 冷启动后控制台会自动打开会话（D-031：`_loadSessions` 取
/// 列表第一个，也就是**引擎侧最近更新的**那个）。同进程内前后台切换是认得上原来
/// 那个的——`_resumeFromBackground` 拿内存里的 `_sessionId` 重开 journal；但
/// 杀进程重开，这条通路整个消失，而**跨冷启动没有任何地方存过 sessionId**
/// （`grep lastSession` 在 lib/ 里零命中）。于是「我刚才在 A 会话里，重开后却在
/// B 里」——B 通常是电脑上另一个终端刚跑过的会话。
///
/// **按机器分开存**，不是为了省事：多机器场景下「上次看的」必须跟着机器走，
/// 否则切到没去过的机器会拿另一台的 id 去开。
///
/// 写入点是 [ChatController.open]——它是「用户此刻在看哪个会话」的**唯一漏斗**
/// （控制台自动打开、会话列表点选、新建会话、团队页点子代理都走它）。漏斗之外的
/// 地方补记忆，迟早会漏一处。
///
/// 读出后还要**验活**：[lastFor] 给出的 id 可能已经被引擎删了，调用方必须先确认
/// 它还在列表里，不在就回落。
///
/// 格式沿用 `SessionTitleCache` 的 `␟` 分隔法：`machineId␟sessionId` 存成
/// StringList。条目量级 = 机器数，个位数。
class LastSessionStore {
  LastSessionStore({SharedPreferencesAsync? storage})
      : _storage = storage ?? SharedPreferencesAsync();

  /// 内存态构造（测试用）：不落盘。widget 测试没有平台通道，
  /// `SharedPreferencesAsync` 在那里直接抛错。
  LastSessionStore.inMemory() : _storage = _NullStorage();

  static const _storageKey = 'dsh_remote.lastSession.v1';

  final SharedPreferencesAsync _storage;
  final Map<String, String> _last = {};

  Future<void>? _loading;

  /// 测试用：让第二个 store 指向同一份存储，模拟「重启后恢复」。
  @visibleForTesting
  SharedPreferencesAsync get storage => _storage;

  /// 冷启动的调用方**必须先 await 这个**再读，否则会读到空内存态并静默回落到
  /// latest——那正是这个特性要修的行为，而且不会报任何错。
  Future<void> get ready => _loading ?? Future<void>.value();

  /// 幂等。App 启动时调一次；失败时按空记忆继续（和 `hydrate` 家族同一纪律：
  /// 降级要有声，不能静默吞掉）。
  Future<void> load() {
    if (_loaded) return ready;
    final future = _doLoad();
    _loading = future;
    return future;
  }

  bool _loaded = false;

  Future<void> _doLoad() async {
    try {
      final raw = await _storage.getStringList(_storageKey) ?? const <String>[];
      for (final line in raw) {
        final i = line.indexOf('␟'); // ␟ unit separator，id 里不会有
        if (i <= 0 || i == line.length - 1) continue;
        _last[line.substring(0, i)] = line.substring(i + 1);
      }
    } on Object catch (e) {
      // 存量坏了 ≠ 没有记忆：从空开始。静默的 catch 正是 D-054 那次
      // 「偏好凭空消失」查不到根因的直接原因。
      AppLog.w('last-session', 'load failed: $e');
    } finally {
      _loaded = true;
    }
  }

  /// [machineId] 上次看的会话；没有或 [machineId] 为 null 时给 null。
  String? lastFor(String? machineId) =>
      machineId == null ? null : _last[machineId];

  /// 记下「这台机器现在看的是这个会话」。[sessionId] 为 null 等于**忘掉**
  /// （用户显式关掉了会话，下次冷启动不该又把它请回来）。
  Future<void> remember(String? machineId, String? sessionId) async {
    if (machineId == null) return;
    if (sessionId == null || sessionId.isEmpty) {
      if (_last.remove(machineId) != null) await _persist();
      return;
    }
    if (_last[machineId] == sessionId) return;
    _last[machineId] = sessionId;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _storage.setStringList(_storageKey, [
        for (final e in _last.entries) '${e.key}␟${e.value}',
      ]);
    } on Object catch (e) {
      AppLog.w('last-session', 'persist failed: $e');
    }
  }
}

/// 永远写不进去的假存储：`LastSessionStore.inMemory` 用。
class _NullStorage implements SharedPreferencesAsync {
  @override
  Future<List<String>?> getStringList(String key) async => null;

  @override
  Future<void> setStringList(String key, List<String> value) async {}

  @override
  noSuchMethod(Invocation invocation) async => null;
}
