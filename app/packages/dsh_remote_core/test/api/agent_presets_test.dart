import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:test/test.dart';

/// D-073: `agentPresets/list` —— agent 预设目录的端点与解析。
///
/// 实测（2026-10-06 对真机引擎）：端点名 `agentPresets/list`，`args` 为
/// **空对象**即可——多传 `_request` 信封会被 `gateway/arguments-invalid`
/// 拒掉（unexpected "_request"）。返回 `{presets: [...]}`，行含
/// id/name?/description?/order/isDefault/broken?。
void main() {
  test('端点名与引擎 @Remote 一致', () {
    expect(AgentPresetsEndpoints.list, 'agentPresets/list');
  });

  test('listAgentPresets 发空 args 并解析出预设摘要', () async {
    final rpc = _RecordingRpc(value: {
      'presets': [
        {
          'id': 'standard',
          'order': 1,
          'isDefault': true,
        },
        {
          'id': 'news-radar',
          'name': '换仓雷达判读官',
          'description': '新闻判读 Agent',
          'order': 100,
        },
        {
          'id': 'image-creator',
          'name': '图片创作官',
          'order': 100,
          'broken': 'invalid config',
        },
      ],
    });
    final client = EngineClient(rpc: _StubRpc(rpc), mux: _UnusedMux());

    final result = await client.listAgentPresets();

    expect(result.isOk, isTrue);
    expect(rpc.calls.single.endpoint, 'agentPresets/list');
    expect(rpc.calls.single.args, isEmpty, reason: '实测空对象即可，别自作聪明包信封');

    final presets = ((result.value! as Map<String, dynamic>)['presets']
            as List<Object?>)
        .map(asObject)
        .whereType<Map<String, dynamic>>()
        .map(AgentPresetSummary.fromJson)
        .toList();
    expect(presets, hasLength(3));
    expect(presets[0].displayName, 'standard', reason: '无 name 回落 id');
    expect(presets[0].isDefault, isTrue);
    expect(presets[1].displayName, '换仓雷达判读官');
    expect(presets[2].broken, isNotNull, reason: '坏预设要带着坏因可见');
  });
}

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

class _RecordingRpc {
  _RecordingRpc({this.value});

  final Object? value;
  final List<_Call> calls = [];

  Future<EngineRpcResult> call(String endpoint,
      {Map<String, dynamic>? args}) async {
    calls.add(_Call(endpoint, args ?? const <String, dynamic>{}));
    return EngineRpcResult.ok(value);
  }
}

class _Call {
  _Call(this.endpoint, this.args);
  final String endpoint;
  final Map<String, dynamic> args;
}
