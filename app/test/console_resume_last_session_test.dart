import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/console/workspaces/last_session_store.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-109 —— 冷启动进控制台，恢复**自己上次看的那个**会话，而不是引擎侧最近更新的。
///
/// 真机症状：手机上聊着 A，电脑另一个终端跑了 B，杀进程重开 App 就落到了 B。
/// 同进程内前后台切换是认得的（`_resumeFromBackground` 拿内存里的 `_sessionId`
/// 重开），跨冷启动则没有——以前压根没有任何地方存过 sessionId。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

/// 显式给 `updatedAt`：列表顺序就是「按更新时间降序」，用 `DateTime.now()`
/// 造行等于把排序交给执行顺序，冷启动恢复的断言会飘。
SessionSummary _row(String id, int updatedAt) => SessionSummary(
      sessionId: id,
      updatedAt: updatedAt,
      running: false,
      blank: false,
      agentAvailable: true,
    );

/// The console keeps live timers (projection refresh, the sessions poll), so
/// `pumpAndSettle` never returns — the D-032 trap. Step a bounded window.
Future<void> settle(WidgetTester tester, {int steps = 14}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

const _machineId = 'relay-session';

MachinesStore _store() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return MachinesStore(
    repo: InMemoryMachinesRepository(),
    seed: [
      MachineEntry(
        id: _machineId,
        name: 'test-mini',
        firstPairedMs: now,
        params: SignedUrlParams(
          relayOrigin: Uri.parse('http://127.0.0.1:8080'),
          sessionId: _machineId,
          hash: 'h',
          mid: 'm',
          tMs: now,
          expMs: now + 3600 * 1000,
        ),
      ),
    ],
  );
}

/// 实际被 `session/follow` 的地址——这才是「App 此刻在看哪个会话」的事实。
String? followedSession(FakeEngineGateway gateway) {
  for (final c in gateway.calls.reversed) {
    if (c.call == 'follow') {
      final address = c.args! as SessionAddress;
      if (address is PlainSessionAddress) return address.sessionId;
      return (address as SubagentSessionAddress).childSessionId;
    }
  }
  return null;
}

void main() {
  testWidgets('冷启动恢复到「上次看的那个」，而不是最近更新的那个',
      (tester) async {
    // 列表按 updatedAt 降序：b 是引擎侧最近更新的，a 是用户上次看的。
    final gateway = FakeEngineGateway(sessions: [
      _row('session-b', 2000),
      _row('session-a', 1000),
    ]);
    addTearDown(gateway.dispose);

    final memory = LastSessionStore.inMemory()..load();
    await memory.remember(_machineId, 'session-a');

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(),
      gatewayFactory: (_) => gateway,
      lastSession: memory,
    )));
    await settle(tester);

    expect(followedSession(gateway), 'session-a',
        reason: '记忆优先于「最近更新」——后者只是没法识别时的兜底');
  });

  testWidgets('记忆里的会话已被引擎删掉 → 回落到最近更新的，绝不硬开',
      (tester) async {
    // 这是必须验活的理由：拿一个不存在的 id 去 session/follow，用户看到的是
    // 一个永远转圈的空白页（D-100 修过的那类症状），而且不会有任何报错。
    final gateway = FakeEngineGateway(sessions: [_row('session-b', 2000)]);
    addTearDown(gateway.dispose);

    final memory = LastSessionStore.inMemory()..load();
    await memory.remember(_machineId, 'session-deleted');

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(),
      gatewayFactory: (_) => gateway,
      lastSession: memory,
    )));
    await settle(tester);

    expect(followedSession(gateway), 'session-b');
  });

  testWidgets('没有记忆时行为不变：仍然自动打开最近更新的那个（D-031）',
      (tester) async {
    final gateway = FakeEngineGateway(sessions: [
      _row('session-b', 2000),
      _row('session-a', 1000),
    ]);
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(),
      gatewayFactory: (_) => gateway,
    )));
    await settle(tester);

    expect(followedSession(gateway), 'session-b',
        reason: 'D-031 不能被这个特性改掉');
  });

  testWidgets('切机器不串号：记忆按机器隔离', (tester) async {
    final gateway = FakeEngineGateway(sessions: [_row('session-a', 2000)]);
    addTearDown(gateway.dispose);

    final memory = LastSessionStore.inMemory()..load();
    await memory.remember('another-machine', 'session-elsewhere');

    await tester.pumpWidget(_host(ConsolePage(
      store: _store(),
      gatewayFactory: (_) => gateway,
      lastSession: memory,
    )));
    await settle(tester);

    expect(followedSession(gateway), 'session-a',
        reason: '别的机器的记忆不该把本机带到不存在的会话上');
  });

  testWidgets('打开会话会把「此刻在看哪个」写回记忆（D-109 的写侧）',
      (tester) async {
    final gateway = FakeEngineGateway(sessions: [_row('session-a', 2000)]);
    addTearDown(gateway.dispose);

    final memory = LastSessionStore.inMemory()..load();
    final store = _store();

    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
      lastSession: memory,
    )));
    await settle(tester);

    expect(memory.lastFor(_machineId), 'session-a',
        reason: '漏斗处记下，冷启动才有得读');
  });
}
