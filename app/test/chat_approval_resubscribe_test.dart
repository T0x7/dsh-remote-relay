import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-079：进入会话时必须立刻拿到「在别的界面就已挂起」的审批。
///
/// 引擎只在**新订阅**时把仍挂起的 waterfall 重放给客户端；App 的
/// `open()` 会清空 `_bubbles` 重开 journal，却从不重订 `$events`——于是
/// 早已抵达的审批被一并清掉且不会重放，卡片要等下一次 60s 定时重订才
/// 回来。真机 2026-10-07 09:2x 实测：日志里每 60s 一个 ready 后紧跟一个
/// waterfall，正是那笔挂起审批的定时回放。
void main() {
  test('进入会话即刻重放挂起的审批，不等 60s 定时重订', () async {
    final gateway = FakeEngineGateway();
    final controller = ChatController(
      gateway: gateway,
      eventsRefreshInterval: Duration.zero,
      answerReadyTimeout: const Duration(milliseconds: 100),
    )..startEvents();
    gateway.raiseReady();
    await pumpEventQueue();

    // 会话 A：先打开过，卡片在屏。
    await controller.open('session-A');
    gateway.raiseWaterfall('approval/request', {'title': 'stuck on A'});
    await pumpEventQueue();
    expect(controller.pendingApproval, isNotNull);

    // 会话 B：切走再切回。挂起的审批必须立刻回到屏幕上。
    await controller.open('session-B');
    expect(controller.pendingApproval, isNull, reason: 'B 会话不该有 A 的卡');
    await controller.open('session-A');
    // 宿主对新鲜订阅的重放是异步抵达的（与真实网关同构）。
    await pumpEventQueue();

    expect(controller.pendingApproval, isNotNull,
        reason: '回到 A 必须立刻重放仍在挂起的审批，不能等 60s 定时器');

    controller.dispose();
    await gateway.dispose();
  });
}