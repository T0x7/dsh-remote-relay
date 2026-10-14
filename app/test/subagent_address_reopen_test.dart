import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-112 —— 子代理会话一旦超时，**重试与自动重开都不能把成对寻址丢掉**。
///
/// 真机症状：点进一个子代理（团队页），首帧 45 秒没来 → 自动重开 → 用户看到的
/// 仍然是一个永远转圈的子会话，而且手动「重试」也救不回来。根因在
/// `ChatController._reopenJournal`：它调 `_openJournal(sessionId, reason: …)` 时
/// **既没传 `subagentLabel` 也没传 `parentSessionId`**，而 `_openJournal` 又只按
/// `subagentLabel` 决定地址，于是子代理被降级成 `PlainSessionAddress(childId)`
/// ——引擎对普通地址根本不认识这个 child，表现就是「永远空白」。
///
/// 叠加第二刀更糟：`_openJournal` 里那句 `parentSessionId ?? sessionId` 会把 child
/// 填进父半边，那是一个引擎必定回 `subagent/unauthorized` 的地址。两条路合起来
/// 就是「自动重开预算重置 + 地址退化」= 每 48 秒重试一次、无穷无尽。
///
/// 守门靠两件事一起兜住：
/// - 地址只有 [addressForSession] 一个构造点，且它对凑不齐的父子配对返回 null；
/// - `FakeEngineGateway.follow` 按**生产语义**校验地址，非法地址直接打成
///   `subagent/unauthorized`（历史上替身只记不校验，这一族缺陷因此能全绿逃逸）。
void main() {
  group('D-112 · 子代理地址在重开路径上不许退化', () {
    testWidgets('首帧超时 → 自动重开，发出去的还是成对地址',
        (WidgetTester tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      // D-104：自动重开会装上新的首帧看门狗，controller 必须在测试体内 dispose，
      // 否则 pending timer 会打在 testWidgets 的定时器审计上。
      addTearDown(gateway.dispose);

      await controller.open(
        'child-uuid',
        parentSessionId: 'parent-job',
        subagentLabel: '基本面周线腿',
      );
      await tester.pump();

      // 45s 首帧看门狗 → 错误卡落地；再 3s 自动重开（D-104 的退避）。
      await tester.pump(const Duration(seconds: 46));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      final follows =
          gateway.calls.where((c) => c.call == 'follow').toList(growable: false);
      expect(follows.length, greaterThanOrEqualTo(2),
          reason: '前置：自动重开必须真的发生了，否则这条断言没有意义');
      final reopened = follows.last.args as SessionAddress;
      expect(reopened, isA<SubagentSessionAddress>(),
          reason: '自动重开退化成普通会话 = 子代理永久不可恢复（本次缺陷）');
      expect((reopened as SubagentSessionAddress).parentSessionId, 'parent-job');
      expect(reopened.childSessionId, 'child-uuid');
      expect(gateway.rejectedAddresses, isEmpty,
          reason: '引擎对 parent 缺失/parent==child 的地址一律回 unauthorized');
      controller.dispose();
    });

    testWidgets('再手动重试一次，地址仍然是成对的',
        (WidgetTester tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      await controller.open(
        'child-uuid',
        parentSessionId: 'parent-job',
        subagentLabel: '基本面周线腿',
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 46));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      final before = gateway.calls.where((c) => c.call == 'follow').length;
      controller.retry();
      await tester.pump();

      final follows =
          gateway.calls.where((c) => c.call == 'follow').toList(growable: false);
      expect(follows.length, before + 1, reason: '前置：手动重试要真的重开一次');
      final retried = follows.last.args as SessionAddress;
      expect(retried, isA<SubagentSessionAddress>(),
          reason: '手动「重试」与自动重开走同一条路，必须同样保住 parent');
      expect((retried as SubagentSessionAddress).parentSessionId, 'parent-job');
      expect(retried.childSessionId, 'child-uuid');
      expect(gateway.rejectedAddresses, isEmpty);
      controller.dispose();
    });
  });

  group('D-112 · 凑不齐的父子配对不发地址', () {
    testWidgets('缺 parent：明确失败，且一次地址都不发',
        (WidgetTester tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      await controller.open('child-uuid', subagentLabel: '基本面周线腿');
      await tester.pump();

      expect(gateway.calls.where((c) => c.call == 'follow'), isEmpty,
          reason: '没有 parent 的子代理地址引擎必定拒绝——宁可明确失败也不发');
      expect(controller.loading, isFalse,
          reason: '失败要说出来，不能停在转圈上');
      expect(controller.error, isNotNull);
      expect(controller.bubbles.whereType<ErrorNotice>(), isNotEmpty,
          reason: 'D-095/D-100：只有 ErrorNotice 气泡是真的会被渲染的那块面板');
      expect(controller.canRetry, isFalse,
          reason: '同一个缺口再点一次重试，构造出来的还是同一个地址');
      controller.dispose();
    });

    testWidgets('parent 就是 child 自己：同样不发',
        (WidgetTester tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      // 这一格正是旧的 `parentSessionId ?? sessionId` 兜底造出来的地址。
      await controller.open(
        'child-uuid',
        parentSessionId: 'child-uuid',
        subagentLabel: '基本面周线腿',
      );
      await tester.pump();

      expect(gateway.calls.where((c) => c.call == 'follow'), isEmpty,
          reason: 'parent == child 的地址就是那次兜底的原样，引擎回 unauthorized');
      expect(controller.error, isNotNull);
      controller.dispose();
    });

    testWidgets('普通会话照常走普通地址（别把规则改过头）',
        (WidgetTester tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      await controller.open('plain-session');
      await tester.pump();

      final follow = gateway.calls.where((c) => c.call == 'follow').single;
      expect(follow.args, isA<PlainSessionAddress>());
      expect((follow.args! as PlainSessionAddress).sessionId, 'plain-session');
      expect(gateway.rejectedAddresses, isEmpty);
      controller.dispose();
    });
  });

  group('D-112 · 规则只有一处（addressForSession）', () {
    test('普通会话 / 成对子代理 / 凑不齐的三种结果', () {
      expect(
        addressForSession(sessionId: 's', subagentLabel: null, parentSessionId: null),
        isA<PlainSessionAddress>(),
      );
      final paired = addressForSession(
        sessionId: 'child',
        subagentLabel: 'label',
        parentSessionId: 'parent',
      );
      expect(paired, isA<SubagentSessionAddress>());
      expect((paired! as SubagentSessionAddress).parentSessionId, 'parent');
      expect(addressForSession(
        sessionId: 'child',
        subagentLabel: 'label',
        parentSessionId: null,
      ), isNull);
      expect(addressForSession(
        sessionId: 'child',
        subagentLabel: 'label',
        parentSessionId: 'child',
      ), isNull);
      expect(addressForSession(
        sessionId: null,
        subagentLabel: 'label',
        parentSessionId: 'parent',
      ), isNull);
    });

    test('替身按生产语义校验地址（否则守门测试是假绿）', () {
      expect(FakeEngineGateway.addressViolation(PlainSessionAddress('s')), isNull);
      expect(FakeEngineGateway.addressViolation(PlainSessionAddress('')), isNotNull);
      expect(
        FakeEngineGateway.addressViolation(const SubagentSessionAddress(
          parentSessionId: 'p',
          childSessionId: 'c',
          mode: SubagentMode.continuable,
        )),
        isNull,
      );
      expect(
        FakeEngineGateway.addressViolation(const SubagentSessionAddress(
          parentSessionId: '',
          childSessionId: 'c',
          mode: SubagentMode.continuable,
        )),
        isNotNull,
      );
      expect(
        FakeEngineGateway.addressViolation(const SubagentSessionAddress(
          parentSessionId: 'c',
          childSessionId: 'c',
          mode: SubagentMode.continuable,
        )),
        isNotNull,
        reason: 'parent 填成 child 自己就是旧兜底造出来的那个地址',
      );
    });
  });

  group('D-112 · 失败时选用的错误码不许给重试留后门', () {
    test('engineUnknown 的 retry 是 none（自动重开因此不会武装）', () {
      // 这条不是装饰：`_failUnaddressable` 用 engineUnknown 是**因为**它的
      // RetryPolicy 是 none——给了重试按钮，用户就会点出一个同样构造不出来的
      // 地址，正是本次缺陷的形状。
      expect(
        const AppError(ErrorCode.engineUnknown).retry,
        RetryPolicy.none,
      );
    });
  });
}