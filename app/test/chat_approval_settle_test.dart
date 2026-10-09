import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-078：审批/提问应答的代际（clientId generation）纪律。
///
/// 引擎网关只接受「接过该 waterfall 投递的那一代 $events 连接」的结果
/// （api/gateway/src/index.ts:618-621 — `deliveries.has(client)` 不符即静默
/// 丢弃；clientId 查无此代则 rpcFailure）。App 的 $events 定期重开换代，
/// 旧实现全局缓存最新 clientId + 乐观删卡 + 无视返回值，导致：
/// 换代窗口里点「允许」→ 无声失败 → 卡片消失但 dsh web 上审批仍挂起。
void main() {
  Future<({FakeEngineGateway gateway, ChatController controller})>
      open({bool ready = true}) async {
    final gateway = FakeEngineGateway();
    // D-078 pins the generation gate, so the fake must NOT auto-serve ready —
    // otherwise the pre-ready window this file tests can never be observed.
    gateway.autoEventReady = false;
    final controller = ChatController(
      gateway: gateway,
      eventsRefreshInterval: Duration.zero,
      answerReadyTimeout: const Duration(milliseconds: 100),
    )..startEvents();
    if (ready) gateway.raiseReady();
    await pumpEventQueue();
    await controller.open('session-1');
    // D-079 made `open` re-subscribe `$events`; with autoEventReady off the
    // fresh generation is silent, so this file keeps serving ready by hand.
    if (ready) gateway.raiseReady();
    await pumpEventQueue();
    return (gateway: gateway, controller: controller);
  }

  Future<void> raiseApproval(({FakeEngineGateway gateway, ChatController controller}) h) async {
    h.gateway.raiseWaterfall('approval/request', {
      'title': 'run brew install',
      'command': 'brew install jq',
    });
    await pumpEventQueue();
  }

  test('应答失败：卡片保留，可再次应答（不再乐观删卡）', () async {
    final h = await open();
    await raiseApproval(h);
    // 两次都失败：首次 + 自动重试（重试前需新一代 ready 上线）。
    for (var i = 0; i < 2; i++) {
      h.gateway.answerScript.add(EngineRpcResult.err(EngineRemoteError(
        code: 'gateway/result-invalid',
        message: 'Remote event result identifies no active event stream',
        details: const <String, dynamic>{},
      )));
    }

    final f = h.controller.answerApproval(ApprovalOutcome.allowedOnce);
    await pumpEventQueue();
    h.gateway.raiseReady(clientId: 'client-gen-2');
    await f;

    expect(h.controller.pendingApproval, isNotNull,
        reason: '失败必须保留卡片——否则用户以为已同意而引擎仍挂起');
    expect(h.gateway.sentAnswers, ['allowed-once', 'allowed-once']);

    // 新一代 ready 后再点 → 成功删卡。
    h.gateway.raiseReady(clientId: 'client-gen-3');
    await pumpEventQueue();
    await h.controller.answerApproval(ApprovalOutcome.allowedOnce);
    expect(h.controller.pendingApproval, isNull);
    h.controller.dispose();
    await h.gateway.dispose();
  });

  test('换代竞态：首次失败后自动重订并等新一代 ready，重试恰好一次', () async {
    final h = await open();
    await raiseApproval(h);
    h.gateway.answerScript.add(EngineRpcResult.err(EngineRemoteError(
      code: 'gateway/result-invalid',
      message: 'no active stream',
      details: const <String, dynamic>{},
    )));

    final f = h.controller.answerApproval(ApprovalOutcome.allowedOnce);
    await pumpEventQueue();
    expect(h.gateway.sentAnswers.length, 1, reason: '第一次尝试已发出且失败');
    // 新一代上线（重订后的 ready），随后重试应当落地。
    h.gateway.raiseReady(clientId: 'client-gen-2');
    await f;

    expect(h.gateway.sentAnswers.length, 2, reason: '失败后恰好重试一次');
    expect(h.controller.pendingApproval, isNull);
    h.controller.dispose();
    await h.gateway.dispose();
  });

  test('clientId 未就绪：先等 ready 再应答，不盲发空代', () async {
    final h = await open(ready: false);
    await raiseApproval(h);

    final f = h.controller.answerApproval(ApprovalOutcome.allowedOnce);
    await pumpEventQueue();
    expect(h.gateway.sentAnswers, isEmpty, reason: 'ready 前不得盲发');
    h.gateway.raiseReady();
    await f;

    expect(h.gateway.sentAnswers, ['allowed-once']);
    expect(h.controller.pendingApproval, isNull);
    h.controller.dispose();
    await h.gateway.dispose();
  });
}
