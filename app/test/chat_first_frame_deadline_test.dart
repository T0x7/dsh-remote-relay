import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-058：点会话进去**一直转圈**。
///
/// 真机（小米 2109119BC）复现：`[e2e] open journal addr=…` 打出来了，说明流建立
/// 成功；但 `[e2e] frame …` 一条都没有，`context unknown`，转圈 40 秒不停。
///
/// 根因：[ChatController.open] 把 `_loading = true` 之后，**只在两个地方清除**——
/// 收到首帧（`applyFrame`）或流报错（`errors`）。而 mux 的 `_onFrame` 对
/// 「未注册 / 已取消」的流是**静默 `return`**（`engine_mux.dart:468`），连一条
/// error 都不发。
///
/// 于是「流活着但一帧不来」= 永远 loading，界面上没有任何提示。引擎对重会话的
/// 首帧可能要 20 秒以上（`session/projections` 实测 125s），**慢**和**死**在
/// 转圈这个画面上长得一模一样——把它分开是 App 的活，不是引擎的。
void main() {
  group('D-058 打开会话卡在 loading', () {
    test('流开了但迟迟没有首帧 → 超时后必须停下来并说明', () async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, machineId: 'm-1');
      addTearDown(controller.dispose);

      await controller.open('job-heavy-session');
      expect(controller.loading, isTrue);

      // 引擎还没给出首帧。App 必须自己承认「等太久了」，而不是无限转圈。
      controller.onFirstFrameDeadlinePassedForTest();
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.loading,
        isFalse,
        reason: '没有首帧的流不能让用户对着转圈等下去',
      );
      expect(
        controller.error,
        isNotNull,
        reason: '停下来必须带一句说明：为什么停了、能不能重试',
      );
    });

    test('首帧一到就恢复正常，不受超时影响', () async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, machineId: 'm-1');
      addTearDown(controller.dispose);

      await controller.open('job-fast');
      gateway.pushFrame(_snapshotFrame());
      await Future<void>.delayed(Duration.zero);
      expect(controller.loading, isFalse);

      // 超时回调这时不该再改写任何东西（否则会把一个已经好的会话说成失败）。
      final errorBefore = controller.error;
      controller.onFirstFrameDeadlinePassedForTest();
      await Future<void>.delayed(Duration.zero);
      expect(controller.loading, isFalse);
      expect(controller.error, same(errorBefore));
    });

    test('换一个会话时，上一个的定时器不能把新会话判成超时', () async {
      // 这是最容易写坏的一格：切会话很快时，旧会话的首帧定时器仍在飞，
      // 到点后会把**新**会话的 loading 错误地清掉并弹一个假错误。
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, machineId: 'm-1');
      addTearDown(controller.dispose);

      await controller.open('job-a'); // 故意不给首帧
      await controller.open('job-b'); // 切走了
      gateway.pushFrame(_snapshotFrame()); // b 的首帧到了
      await Future<void>.delayed(Duration.zero);
      expect(controller.loading, isFalse);

      // a 的定时器到点：什么都不该发生。
      controller.onFirstFrameDeadlinePassedForTest();
      await Future<void>.delayed(Duration.zero);
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
    });

    test('流报错时照旧清除 loading（这条本来就对，别被改坏）', () async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, machineId: 'm-1');
      addTearDown(controller.dispose);

      await controller.open('job-broken');
      gateway.pushFrameError(const EngineRemoteError(
        code: 'gateway/timeout',
        message: 'no frame',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(controller.loading, isFalse);
      expect(controller.error, isNotNull);
    });
  });
}

/// 走真实解码路径，顺便验证「引擎给的首帧能被解成 FollowSnapshot」。
SessionFollowFrame _snapshotFrame({String sessionId = 'job-fast'}) =>
    SessionFollowFrame.fromJson({
      'type': 'snapshot',
      'header': {'sessionId': sessionId, 'title': 'nightly-backtest'},
      'projections': const <String, Object?>{},
      'records': const <Object?>[],
      'cursor': 1,
      'hasMore': false,
    });
