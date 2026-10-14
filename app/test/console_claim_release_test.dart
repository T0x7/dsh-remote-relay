import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/services/live_machine_scope.dart';
import 'package:dsh_remote_app/services/machines_session_poller.dart';
import 'package:dsh_remote_core/api/relay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';
import 'fakes/fake_engine_gateway.dart';

/// D-112 —— claim 与 release 必须严格成对。
///
/// `ConsolePage._bindMachine` 过去只调 `LiveMachineScope.instance.claim(entry.id)`，
/// `dispose()` 与「切到别的机器」都没有配对的 release（`main.dart` 的详情页一直
/// 是有 release 的，所以这不是设计，是漏写）。
///
/// 后果不是内存泄漏这么温和：`LiveMachineScope` 的 claim 是**计数**，只加不减，
/// 于是
///
/// - 切走的机器被 `MachinesSessionPoller.sweep()` **永久**跳过（`live.holds()`），
/// - 它的卡片停在上一次读到的「在线」态，再也不刷新；
/// - 每次进出控制台页计数再 +1，永远回不来。
///
/// 守门断言的是**轮询器真的能再看到旧机器**，而不只是某个布尔计数：claim 的意义
/// 就是让轮询器绕开它，绕开与否只能在轮询器身上看见。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// 控制台常驻定时器，`pumpAndSettle` 永远不回来（D-032）。
Future<void> settle(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

RemoteSessionSnapshot _snapshot() => RemoteSessionSnapshot(
      tunnel: TunnelConnectionState(
        state: TunnelState.connected,
        relayUrl: 'ws://relay',
        manualOff: false,
      ),
      active: null,
      sessions: const [],
      devices: const [],
    );

void main() {
  late LiveMachineScope scope;
  late FakeEngineGateway gateway;

  setUp(() {
    scope = LiveMachineScope();
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
  });

  /// 两台机器，id 是 `sess_a` / `sess_b`。
  MachinesStore twoMachines() => MachinesStore(
        repo: InMemoryMachinesRepository(),
        seed: [
          machineFrom(mintTestUrl(sessionId: 'sess_a', name: 'a')),
          machineFrom(mintTestUrl(sessionId: 'sess_b', name: 'b')),
        ],
      );

  Future<void> mount(WidgetTester tester, MachinesStore store) async {
    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
      liveScope: scope,
    )));
    await settle(tester);
  }

  testWidgets('挂载时认领自己驾驶的那台，另一台留给轮询器',
      (tester) async {
    await mount(tester, twoMachines());

    expect(scope.holds('sess_a'), isTrue,
        reason: '控制台驾驶的那台必须是 live，否则会对着中继重复问');
    expect(scope.holds('sess_b'), isFalse);
  });

  testWidgets('切到另一台后，旧机器重新能被轮询器看到', (tester) async {
    final store = twoMachines();
    final entryA = machineFrom(mintTestUrl(sessionId: 'sess_a', name: 'a'));
    await mount(tester, store);

    // 第一轮：只有没被认领的那台会被读到。
    var asked = <String>[];
    final poller = MachinesSessionPoller(
      store: store,
      live: scope,
      fetch: (entry) async {
        asked = [...asked, entry.id];
        return _snapshot();
      },
    );
    addTearDown(poller.dispose);
    await poller.sweep();
    expect(asked, ['sess_b'],
        reason: '前置：被认领的机器这一轮确实被绕开了');

    // 驱动的那台没了（用户删了它）→ 控制台改驾驶另一台。
    await store.remove('sess_a');
    await settle(tester);

    expect(scope.holds('sess_b'), isTrue);
    expect(scope.holds('sess_a'), isFalse,
        reason: '旧机器必须被 release：只 claim 不 release 会让它被轮询器永久跳过，'
            '卡片一直停在上一次读到的「在线」');

    // 它重新出现在列表里（重新配对回来）而此刻没人驾驶它 →
    // 这才是这条守门真正要证明的东西：轮询器又能读到它了。
    await store.add(entryA);
    await settle(tester);
    asked = [];
    await poller.sweep();
    expect(asked, ['sess_a'],
        reason: '没人驾驶的机器要回到 60s 低频刷新里，否则它的状态从此是死的');
  });

  testWidgets('页面卸载时放掉当前 claim', (tester) async {
    final store = twoMachines();
    await mount(tester, store);
    expect(scope.holds('sess_a'), isTrue);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await settle(tester);

    expect(scope.holds('sess_a'), isFalse,
        reason: '页面走了，它驾驶的机器就该回到轮询器的视野里');
    expect(scope.machineIds, isEmpty);
  });

  testWidgets('没有下一台可驾驶时也放掉 claim', (tester) async {
    final store = twoMachines();
    await mount(tester, store);
    expect(scope.holds('sess_a'), isTrue);

    await store.remove('sess_a');
    await store.remove('sess_b');
    await settle(tester);

    expect(scope.machineIds, isEmpty,
        reason: '一台机器都不剩 = 本页不再持有任何 claim');
  });

  testWidgets('反复进出同一台不会把计数堆上去', (tester) async {
    final store = twoMachines();

    for (var i = 0; i < 3; i++) {
      await mount(tester, store);
      expect(scope.holds('sess_a'), isTrue);
      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await settle(tester);
      expect(scope.holds('sess_a'), isFalse,
          reason: '第 ${i + 1} 次进出：claim 必须是配对的，不是单调增长的');
    }
  });
}