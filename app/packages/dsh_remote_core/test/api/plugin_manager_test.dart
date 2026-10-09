import 'package:test/test.dart';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';

/// Records what the facade sent and replays a scripted response, so the tests
/// assert the *request* shape (which is where contract drift bites) without a
/// live engine.
class _FakeRelay implements RelayClient {
  _FakeRelay(this.value);

  final Object? value;
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<(int, dynamic)> postJson(String path, Object? payload) async {
    bodies.add(payload! as Map<String, dynamic>);
    final envelope = {
      'type': 'server-response',
      'rpcId': 'r',
      'result': {'ok': true, 'value': value},
    };
    return (200, envelope);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EngineClient _client(_FakeRelay relay) => EngineClient(
      rpc: EngineRpc(relay: relay),
      mux: EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
      ),
    );

/// D-081：pluginManager 三个路由的 wire 契约。信封全部由 2026-10-08 真引擎
/// 探针钉死（错误探针零副作用读 descriptor）：
/// - listPlugins：args 为空对象（无参数路由）
/// - setPluginEnabled：裸 `{id, enabled}`（descriptor: missing "id","enabled"）
/// - setBundleEnabled：裸 `{name, enabled}`（descriptor: missing "name","enabled"）
void main() {
  test('listPlugins takes no args and parses the real engine rows', () async {
    final relay = _FakeRelay([
      {
        'entryId': 'include',
        'moduleName': 'cordis:include',
        'enabled': true,
        'fiberPhase': 'active',
        'readOnlyReason': 'unaddressable',
      },
      {
        'entryId': 'include:tool-plugin-manager',
        'moduleName': '@deepseek-ai/dsh-plugin-manager/tools',
        'enabled': false,
        'fiberPhase': null,
        'patchId': 'tool-plugin-manager',
      },
      {
        'entryId': 'include:plugin-manager',
        'moduleName': '@deepseek-ai/dsh-plugin-manager',
        'enabled': true,
        'fiberPhase': 'active',
        'meta': {
          'title': '@deepseek-ai/dsh-plugin-manager',
          'description': 'Current-profile plugin and bundle management',
        },
      },
      {
        // D-081 真机实证：meta 是 locale map，不是字符串——4/193 行为此形态。
        'entryId': 'include:team',
        'moduleName': '@deepseek-ai/dsh-experimental-agent-team',
        'enabled': true,
        'fiberPhase': 'active',
        'patchId': 'team',
        'meta': {
          'title': {'en': 'Team Collaboration', 'zh': '团队协作'},
          'description': {'en': 'Manage team members.', 'zh': '管理团队成员。'},
        },
      },
    ]);
    final client = _client(relay);

    final result = await client.pluginManagerListPlugins();

    expect(result.isOk, isTrue);
    final body = relay.bodies.single;
    expect(body['method'], 'pluginManager/listPlugins');
    expect(body['payload']['args'], isEmpty,
        reason: 'listPlugins 是无参数路由（探针实证）');

    final rows = PluginManagerEntry.listFrom(result.value);
    expect(rows, hasLength(4));
    expect(rows[0].switchable, isFalse);
    expect(rows[0].readOnlyReason, 'unaddressable',
        reason: 'cordis:include 无唯一 loader entry，引擎拒绝寻址');
    expect(rows[1].switchable, isTrue);
    expect(rows[1].patchId, 'tool-plugin-manager');
    expect(rows[1].enabled, isFalse);
    expect(rows[3].displayName('zh'), '团队协作',
        reason: 'locale map：中文界面取 zh');
    expect(rows[3].displayName('en'), 'Team Collaboration');
    expect(rows[2].displayName('zh'), '@deepseek-ai/dsh-plugin-manager',
        reason: 'meta.title 存在时优先于 moduleName');
    expect(rows[0].displayName('zh'), 'cordis:include',
        reason: '无 meta 时回落 moduleName');
  });

  test('setPluginEnabled sends the bare {id, enabled}', () async {
    final relay = _FakeRelay({
      'changed': true,
      'application': 'applied',
      'stage': 'enable',
      'target': 'tool-plugin-manager',
      'enabled': true,
    });
    final client = _client(relay);

    await client.pluginManagerSetPluginEnabled(
      id: 'include:tool-plugin-manager',
      enabled: true,
    );

    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args, {
      'id': 'include:tool-plugin-manager',
      'enabled': true,
    }, reason: 'descriptor 探针：missing "id", "enabled" —— 裸键、无 request 包装');
  });

  test('setBundleEnabled sends the bare {name, enabled}', () async {
    final relay = _FakeRelay(null);
    final client = _client(relay);

    await client.pluginManagerSetBundleEnabled(name: 'dsh-bundle-x', enabled: false);

    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args, {'name': 'dsh-bundle-x', 'enabled': false});
  });
}