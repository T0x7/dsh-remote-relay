import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-110 —— 凭证终态失效时，控制台**不许**再说「正在重连」。
///
/// 三条一起钉：①文案不再是 `consoleReconnecting`；②给出唯一主行动；
/// ③凭证还活着时行为一点不变（不能为了修终态把正常态也改了）。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

MachinesStore _store({required bool expired}) {
  final now = DateTime.now();
  return MachinesStore(
    repo: InMemoryMachinesRepository(),
    seed: [
      MachineEntry(
        id: 'relay-session',
        name: 'test-mini',
        firstPairedMs: now.millisecondsSinceEpoch - 3600 * 1000,
        params: SignedUrlParams(
          relayOrigin: Uri.parse('http://127.0.0.1:8080'),
          sessionId: 'relay-session',
          hash: 'h',
          mid: 'm',
          tMs: now.millisecondsSinceEpoch - 3600 * 1000,
          // 过期 = expMs 落在过去；有效 = 落在 1 小时后。
          expMs: expired
              ? now.millisecondsSinceEpoch - 60 * 1000
              : now.millisecondsSinceEpoch + 3600 * 1000,
        ),
      ),
    ],
  );
}

Future<void> settle(WidgetTester tester, {int steps = 14}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('凭证终态失效：横幅不再谎称「正在重连」，并给出唯一主行动',
      (tester) async {
    final gateway = FakeEngineGateway(sessions: [
      SessionSummary(
        sessionId: 'session-a',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        running: false,
        blank: false,
        agentAvailable: true,
      ),
    ]);
    addTearDown(gateway.dispose);
    var jumpedToMachines = false;

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(expired: true),
      gatewayFactory: (_) => gateway,
      onShowMachines: () => jumpedToMachines = true,
    )));
    await settle(tester);

    // 核心断言：那句「正在重连」一个字都不许出现。
    expect(find.text('连接已断开，正在重连…'), findsNothing,
        reason: '终态下重连永远不会成功，这句话是谎（D-104 同族）');
    expect(find.text('凭证已失效，不会自动恢复'), findsOneWidget);
    // 唯一主行动在场，且点了真的跳。
    expect(find.text('去重新配对'), findsOneWidget);
    await tester.tap(find.text('去重新配对'));
    expect(jumpedToMachines, isTrue);
  });

  testWidgets('终态原因说人话，不是把 code 甩给用户', (tester) async {
    final gateway = FakeEngineGateway(sessions: const []);
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(expired: true),
      gatewayFactory: (_) => gateway,
    )));
    await settle(tester);

    expect(find.textContaining('会话已过期'), findsOneWidget,
        reason: 'design §7.2 文案三段式：用户视角一行，不裸抛 code');
  });

  testWidgets('凭证还活着时行为一点不变（不把正常态也改了）', (tester) async {
    final gateway = FakeEngineGateway(sessions: [
      SessionSummary(
        sessionId: 'session-a',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        running: false,
        blank: false,
        agentAvailable: true,
      ),
    ]);
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(expired: false),
      gatewayFactory: (_) => gateway,
      onShowMachines: () {},
    )));
    await settle(tester);

    expect(find.text('凭证已失效，不会自动恢复'), findsNothing);
    expect(find.text('去重新配对'), findsNothing);
  });

  testWidgets('30 天上限（max_age）与单纯过期要说不同的话', (tester) async {
    final gateway = FakeEngineGateway(sessions: const []);
    addTearDown(gateway.dispose);

    // 凭证早已过期，但 firstPairedMs 在 30 天内 ⇒ 判 expired 而不是 maxAge。
    final now = DateTime.now();
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        MachineEntry(
          id: 'relay-session',
          name: 'test-mini',
          firstPairedMs: now.millisecondsSinceEpoch - 3 * 24 * 3600 * 1000,
          params: SignedUrlParams(
            relayOrigin: Uri.parse('http://127.0.0.1:8080'),
            sessionId: 'relay-session',
            hash: 'h',
            mid: 'm',
            tMs: now.millisecondsSinceEpoch - 3 * 24 * 3600 * 1000,
            expMs: now.millisecondsSinceEpoch - 60 * 1000,
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
    )));
    await settle(tester);

    expect(find.textContaining('会话已过期'), findsOneWidget);
    expect(find.textContaining('超过 30 天'), findsNothing);
  });
}
