import 'package:dsh_remote_app/console/workspaces/last_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// D-109：跨冷启动的「上次看的会话」记忆。
///
/// 真机症状：冷启动进控制台落到了**引擎侧最近更新**的会话，而不是自己刚才在看
/// 那个——电脑上另一个终端跑过别的会话就会跳错。同进程内前后台切换是认得上的
/// （`_resumeFromBackground` 拿内存里的 `_sessionId` 重开），跨冷启动则一片空白。
///
/// 存储替身沿用 `workspace_titles_test.dart` 的做法：`InMemorySharedPreferencesAsync`
/// 平台实现，而不是手写 `implements SharedPreferencesAsync`（那样要么撞
/// `must_be_immutable`，要么得给可变字段开豁免）。
/// 失败注入用 [_ThrowingStorage] 转发——它的开关都是 final，lint 干净。

/// 全字段 final 的转发器：只在构造时决定「读炸 / 写炸」，不中途翻。
class _ThrowingStorage implements SharedPreferencesAsync {
  _ThrowingStorage(this._delegate, {this.failReads = false, this.failWrites = false});

  final SharedPreferencesAsync _delegate;
  final bool failReads;
  final bool failWrites;

  @override
  Future<List<String>?> getStringList(String key) async {
    if (failReads) throw StateError('storage exploded on read');
    return _delegate.getStringList(key);
  }

  @override
  Future<void> setStringList(String key, List<String> value) async {
    if (failWrites) throw StateError('disk full');
    await _delegate.setStringList(key, value);
  }

  @override
  noSuchMethod(Invocation invocation) => _delegate.noSuchMethod(invocation);
}

/// 一份「App 进程」用的存储。返回 store 本身，好让下一段进程接着用同一份。
SharedPreferencesAsync freshProcess() {
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  return SharedPreferencesAsync();
}

void main() {
  group('LastSessionStore', () {
    test('写入后换一个实例读盘，能拿回同一个会话', () async {
      final first = LastSessionStore(storage: freshProcess());
      await first.load();
      await first.remember('machine-a', 'sess_alpha');

      // 第二个实例 = 重启后的 App，指向同一份平台存储。
      final revived = LastSessionStore(storage: SharedPreferencesAsync());
      await revived.load();
      expect(revived.lastFor('machine-a'), 'sess_alpha');
    });

    test('按机器隔离：切到没去过的机器不串号', () async {
      final storage = freshProcess();
      final store = LastSessionStore(storage: storage);
      await store.load();
      await store.remember('machine-a', 'sess_alpha');
      await store.remember('machine-b', 'sess_beta');

      expect(store.lastFor('machine-a'), 'sess_alpha');
      expect(store.lastFor('machine-b'), 'sess_beta');
      expect(store.lastFor('machine-c'), isNull);
      expect(store.lastFor(null), isNull,
          reason: '没有机器就没有「上次」可言');
    });

    test('sessionId 为 null = 忘掉（用户显式关掉了会话）', () async {
      final storage = freshProcess();
      final store = LastSessionStore(storage: storage);
      await store.load();
      await store.remember('machine-a', 'sess_alpha');
      await store.remember('machine-a', null);

      final revived = LastSessionStore(storage: SharedPreferencesAsync());
      await revived.load();
      expect(revived.lastFor('machine-a'), isNull);
    });

    test('load 幂等：连调三次也只读一次盘，ready 可重复 await', () async {
      final store = LastSessionStore(storage: freshProcess());
      await store.load();
      await store.load();
      await store.load();
      await store.ready;
      await store.ready;
      expect(store.lastFor('m'), isNull);
    });

    test('读盘失败按空记忆继续（降级要有声，但不抛给调用方）', () async {
      final inner = freshProcess();
      final store = LastSessionStore(
          storage: _ThrowingStorage(inner, failReads: true));
      await store.load();
      expect(store.lastFor('machine-a'), isNull,
          reason: '存量坏了 ≠ 没有记忆：从空开始');
    });

    test('写盘失败不抛给调用方（日志绝不能打断调用链）', () async {
      final inner = freshProcess();
      final store = LastSessionStore(
          storage: _ThrowingStorage(inner, failWrites: true));
      await store.load();
      await expectLater(store.remember('m', 'sess_x'), completes);
      expect(store.lastFor('m'), 'sess_x', reason: '内存态仍然生效，只是没落盘');
    });

    test('畸形条目（没有分隔符 / 空 id）被跳过，不带崩整次加载', () async {
      final inner = freshProcess();
      await inner.setStringList('dsh_remote.lastSession.v1',
          ['machine-a␟sess_ok', 'garbage', '␟sess_no_machine', 'machine-b␟']);
      final store = LastSessionStore(storage: inner);
      await store.load();
      expect(store.lastFor('machine-a'), 'sess_ok');
      expect(store.lastFor('machine-b'), isNull);
    });
  });
}
