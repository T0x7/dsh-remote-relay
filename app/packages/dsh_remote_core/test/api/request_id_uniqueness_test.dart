import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:test/test.dart';

/// D-077：requestId 跨进程必须唯一——否则引擎的幂等去重会把新消息当成
/// 旧重试**静默吞掉**（实测 2026-10-06 23:24：ok=true 但全 journal 无记录；
/// 同 requestId curl 两连发确定性复现：第 1 条落库、第 2 条 accepted 但消失）。
///
/// 旧实现 `'app-req-${_requestSeq++}'` 的计数器随 App 进程从零开始——今天
/// App 重启了 8+ 次，每次都重放 app-req-1..N，与引擎全天积累的已处理 id
/// 撞车。修法：id 掺入微秒时间戳，跨进程天然不同；进程内仍单调递增。
void main() {
  test('模拟重启：两个全新 client 的同序号 requestId 必须不同', () {
    // 每个进程各自 new 一个 EngineClient——重启 = 新进程 = 新实例。
    final boot1 = EngineClient(
        rpc: _UnusedRpc(), mux: _UnusedMux());
    final boot2 = EngineClient(
        rpc: _UnusedRpc(), mux: _UnusedMux());

    final a = boot1.newRequestId();
    final b = boot2.newRequestId();

    expect(a, isNot(b), reason: '同序号撞车 = 引擎幂等去重吞消息');
    expect(a, startsWith('app-req-'));
  });

  test('进程内仍单调递增（重试语义不受影响）', () {
    final client = EngineClient(rpc: _UnusedRpc(), mux: _UnusedMux());
    final ids = [client.newRequestId(), client.newRequestId()];
    expect(ids.toSet().length, 2);
  });
}

class _UnusedRpc implements EngineRpc {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedMux implements EngineMux {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
