import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:test/test.dart';

/// The registry's **write** side (D-055).
///
/// D-046 gave us the read side — a `workspace/follow` subscription that already
/// carries `archivedSessionIds` and `pinnedSessionIds`. The App used them only
/// as subtraction: an archived session was dropped from the ungrouped row and
/// from every list, with no way to bring it back. That is a real asymmetry, not
/// a missing nicety — a session the user archived on the desktop became
/// invisible *and unrecoverable* on the phone, so it read as "the app lost it".
///
/// The engine exposes exactly four unary verbs for this
/// (`api/workspace-controller/src/index.ts:154-192`), and all four answer with
/// the complete resulting set rather than a delta — so the App can install the
/// response directly instead of guessing.
///
/// What this file deliberately does NOT cover: `archiveSessions(id)` (bulk
/// archive of a whole workspace) exists on the registry but is **not** a Remote
/// — it is a host-side API, not a wire endpoint, so there is nothing to call.
void main() {
  group('端点名', () {
    test('四个写端点与引擎的 @Remote 名一致', () {
      // Wire names are the contract. The engine's transport spec pins the exact
      // request object each verb must receive
      // (`api/workspace-controller/tests/transport.client.spec.ts:346-355`).
      expect(WorkspaceRegistryEndpoints.archive, 'workspace/archiveSession');
      expect(WorkspaceRegistryEndpoints.unarchive, 'workspace/unarchiveSession');
      expect(WorkspaceRegistryEndpoints.pin, 'workspace/pinSession');
      expect(WorkspaceRegistryEndpoints.unpin, 'workspace/unpinSession');
    });
  });

  group('archiveSession', () {
    test('默认不带 stopActivity —— 让引擎自己拒绝在跑的会话', () async {
      final rpc = _RecordingRpc();
      final client = _client(rpc);

      final result = await client.archiveSession('s-1');

      expect(result.isOk, isTrue);
      // 不传 stopActivity：引擎会走 workspace/session-activity waterfall，
      // 发现还有活就拒。App 不替用户决定「要不要强归档」。
      expect(rpc.calls.single.args, {
        'request': {'sessionId': 's-1'},
      });
    });

    test('stopActivity: true 会如实发出去（强归档 = 停掉在跑的活）', () async {
      final rpc = _RecordingRpc(
        value: {
          'archivedSessionIds': ['s-1'],
        },
      );
      final client = _client(rpc);

      final result = await client.archiveSession('s-1', stopActivity: true);

      expect(result.isOk, isTrue);
      expect(rpc.calls.single.endpoint, 'workspace/archiveSession');
      expect(rpc.calls.single.args, {
        'request': {'sessionId': 's-1', 'stopActivity': true},
      });
    });

    test('返回的是完整归档集合，可直接装进投影', () async {
      final rpc = _RecordingRpc(
        value: {
          'archivedSessionIds': ['s-1', 's-2'],
        },
      );
      final result = await _client(rpc).archiveSession('s-1');

      expect(result.isOk, isTrue);
      expect(result.value, {
        'archivedSessionIds': ['s-1', 's-2'],
      });
    });

    test('会话还在跑时，workspace/session-active 的 activity 明细要能读出来', () async {
      // 这是归档唯一需要「把话说明白」的错误：用户点了归档，必须告诉他
      // 会停掉什么，而不是只说「失败」。错误码带 activity 明细，App 要能
      // 逐族列出（turn / subagent / job / schedule）。
      final rpc = _RecordingRpc(
        error: EngineRemoteError(
          code: 'workspace/session-active',
          message: 'session is active',
          details: {
            'sessionId': 's-1',
            'activity': [
              {'kind': 'turn'},
              {
                'kind': 'job',
                'items': [
                  {'id': 'job-a', 'label': 'nightly-backtest'},
                ],
              },
              {
                'kind': 'schedule',
                'items': [
                  {'id': 'sch-1'},
                ],
              },
            ],
          },
        ),
      );

      final result = await _client(rpc).archiveSession('s-1');

      expect(result.isOk, isFalse);
      expect(result.error!.code, 'workspace/session-active');

      final activity = SessionActivityList.decode(result.error!.details);
      // `turn` 是唯一不带 per-item identity 的族：它出现本身就说明有东西在
      // 跑，所以断言的是「这个族在场」，不是「它有几个条目」——那会把它
      // 读成 0，然后让弹窗告诉用户「归档不会影响任何东西」。
      expect(activity.byKind, contains('turn'));
      expect(activity.byKind['turn'], isEmpty);
      expect(activity.byKind['job']!.single.label, 'nightly-backtest');
      // 没有 label 的族回落成 id —— 弹窗里也要有个能念出来的东西。
      expect(activity.byKind['schedule']!.single.label, null);
      expect(activity.byKind['schedule']!.single.display, 'sch-1');
      // 无 identity 的族在总计里算 1，不允许报成 0：
      // turn(1) + job(1) + schedule(1) = 3。
      expect(activity.totalItems, 3);
      expect(activity.isEmpty, isFalse);
      // 引擎编了 App 没编译过的族时不能炸也不能丢。
      expect(activity.unknownKinds, isEmpty);
    });

    test('引擎编了 App 没编译过的族：要留着并报成 unknown', () async {
      // 丢弃这一族等于少报「归档会停掉什么」，而那正是这个弹窗唯一要保证
      // 说清楚的事。dsh 自己的对话框也是回落到通用文案而不是隐藏
      // （`ArchiveSession.tsx` `activityLine` 的 `default:` 分支）。
      final rpc = _RecordingRpc(
        error: EngineRemoteError(
          code: 'workspace/session-active',
          message: 'session is active',
          details: {
            'sessionId': 's-1',
            'activity': [
              {
                'kind': 'some-future-plugin',
                'items': [
                  {'id': 'x-1'},
                ],
              },
            ],
          },
        ),
      );

      final activity =
          SessionActivityList.decode((await _client(rpc).archiveSession('s-1')).error!.details);

      expect(activity.unknownKinds, ['some-future-plugin']);
      expect(activity.byKind['some-future-plugin']!.single.id, 'x-1');
    });

    test('activity 缺失或畸形时是空列表而不是崩溃', () {
      expect(SessionActivityList.decode(null).isEmpty, isTrue);
      expect(SessionActivityList.decode(const {}).isEmpty, isTrue);
      expect(
        SessionActivityList.decode(const {'activity': 'nope'}).isEmpty,
        isTrue,
        reason: '拒绝时引擎仍要给用户一句「这个会话在忙」，只是没有明细列表',
      );
      expect(
        SessionActivityList.decode(const {'activity': 'nope'}).totalItems,
        0,
      );
    });
  });

  group('unarchiveSession', () {
    test('没有任何准入检查，直接恢复', () async {
      // 引擎侧 unarchive 不做存在性检查（移出一个 id 不会引入未知 id），
      // 所以这条路径永远不会撞上 session-active —— App 不需要为它准备
      // 「在跑怎么办」的分支。
      final rpc = _RecordingRpc(
        value: {
          'archivedSessionIds': <String>[],
        },
      );
      final result = await _client(rpc).unarchiveSession('arch-1');

      expect(result.isOk, isTrue);
      expect(rpc.calls.single.endpoint, 'workspace/unarchiveSession');
      expect(rpc.calls.single.args, {
        'request': {'sessionId': 'arch-1'},
      });
      expect(result.value, {
        'archivedSessionIds': <String>[],
      });
    });
  });

  group('pin / unpin', () {
    test('pinSession 返回完整置顶集合（最近置顶在前）', () async {
      final rpc = _RecordingRpc(
        value: {
          'pinnedSessionIds': ['s-9', 's-1'],
        },
      );
      final result = await _client(rpc).pinSession('s-9');

      expect(result.isOk, isTrue);
      expect(rpc.calls.single.endpoint, 'workspace/pinSession');
      expect(result.value, {
        'pinnedSessionIds': ['s-9', 's-1'],
      });
    });

    test('unpinSession 只带 sessionId', () async {
      final rpc = _RecordingRpc(
        value: {
          'pinnedSessionIds': ['s-1'],
        },
      );
      final result = await _client(rpc).unpinSession('s-9');

      expect(result.isOk, isTrue);
      expect(rpc.calls.single.args, {
        'request': {'sessionId': 's-9'},
      });
      expect(result.value, {
        'pinnedSessionIds': ['s-1'],
      });
    });
  });

  group('与投影的互斥关系', () {
    test('归档与置顶互斥：引擎在同一次写入里丢掉 pin，取消归档不还回来', () {
      // 这是必须写进测试的引擎语义，因为 UI 上它表现为「我刚置顶的会话，
      // 归档之后 pin 图标没了，恢复之后还是没了」——用户会觉得是 App 的 bug。
      // `docs/subsystems/workspace.zh.md:130`：
      //   归档在同一次持久化写入中移除该会话的置顶，取消归档不会恢复置顶。
      // 所以 App 不能靠「恢复归档 → pin 回来」来省事，必须如实照做。
      final projection = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame({
          'type': 'baseline',
          'value': {
            'items': <Map<String, dynamic>>[],
            'archivedSessionIds': <String>[],
            'pinnedSessionIds': ['s-1'],
          },
        }));
      expect(projection.pinnedSessionIds, ['s-1']);

      // 引擎归档后的 pinned 增量：置顶已经没了（同一次持久化写入）。
      projection.apply(decodeWorkspaceFrame({
        'type': 'pinned',
        'pinnedSessionIds': <String>[],
      }));
      projection.apply(decodeWorkspaceFrame({
        'type': 'archived',
        'archivedSessionIds': ['s-1'],
      }));
      expect(projection.archivedSessionIds, ['s-1']);
      expect(
        projection.pinnedSessionIds,
        isEmpty,
        reason: '归档的同一次写入已经丢掉了 pin，App 只是如实反映',
      );

      // 恢复归档不会把 pin 送回来，所以 App 侧不做任何「顺手恢复 pin」的事。
      projection.apply(decodeWorkspaceFrame({
        'type': 'archived',
        'archivedSessionIds': <String>[],
      }));
      expect(projection.archivedSessionIds, isEmpty);
      expect(
        projection.pinnedSessionIds,
        isEmpty,
        reason: '取消归档不恢复置顶——所以 unarchiveSession 里绝不能顺手 re-pin',
      );
    });
  });
}

// ---------------------------------------------------------------- test rig

EngineClient _client(_RecordingRpc rpc) => EngineClient(
      rpc: _StubRpc(rpc),
      mux: _UnusedMux(),
    );

class _StubRpc implements EngineRpc {
  _StubRpc(this.delegate);
  final _RecordingRpc delegate;

  @override
  Future<EngineRpcResult> call(String endpoint, {Map<String, dynamic>? args}) =>
      delegate.call(endpoint, args: args);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedMux implements EngineMux {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordedCall {
  _RecordedCall(this.endpoint, this.args);
  final String endpoint;
  final Map<String, dynamic> args;
}

class _RecordingRpc {
  _RecordingRpc({this.value, this.error});

  /// The complete resulting set the engine answers with.
  final Object? value;
  final EngineRemoteError? error;

  final List<_RecordedCall> calls = [];

  Future<EngineRpcResult> call(String endpoint, {Map<String, dynamic>? args}) async {
    calls.add(_RecordedCall(endpoint, args ?? const {}));
    final e = error;
    if (e != null) return EngineRpcResult.err(e);
    return EngineRpcResult.ok(value);
  }
}
