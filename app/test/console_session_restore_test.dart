import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/console/sessions/sessions_page.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_pane.dart';
import 'package:dsh_remote_app/console/workspace/workspace_pane.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-041 — picking a session from the list lands on the **conversation**.
///
/// The console is one page with four segments (对话 / 任务 / 主机 / 工作区), and
/// the session list is pushed on top of it. Restoring a session pops that list,
/// but the segment selection is state that outlives the pop — so a user who was
/// reading the workspace got dropped straight back into the workspace, and the
/// tap looked like it had done nothing at all. "点进去没反应" is not a
/// discoverable bug; it is the visible half of a segment that never moved.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

SessionSummary _row(String id) => SessionSummary(
      sessionId: id,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      running: false,
      blank: false,
      agentAvailable: true,
    );

/// The console keeps live timers (projection refresh, the sessions poll), so
/// `pumpAndSettle` never returns — the D-032 trap. Step a bounded window
/// instead and let the fake clock carry the async work.
Future<void> settle(WidgetTester tester, {int steps = 14}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('restoring a session returns to the chat segment, not the one '
      'the user was reading', (tester) async {
    final gateway = FakeEngineGateway(sessions: [_row('session-abc')]);
    addTearDown(gateway.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        MachineEntry(
          id: 'relay-session',
          name: 'test-mini',
          firstPairedMs: now,
          params: SignedUrlParams(
            relayOrigin: Uri.parse('http://127.0.0.1:8080'),
            sessionId: 'relay-session',
            hash: 'h',
            mid: 'm',
            tMs: now,
            // Far enough out that `_defaultMachine` accepts it.
            expMs: now + 3600 * 1000,
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
    )));
    await settle(tester);

    // Read the workspace first — that is the segment a user is most likely to
    // be on when they decide to check a session.
    await tester.tap(find.text('工作区'));
    await settle(tester);
    expect(find.byType(WorkspacePane), findsOneWidget,
        reason: 'precondition: the workspace segment is showing');

    // Open the list and restore a session.
    await tester.tap(find.byIcon(Icons.list_alt));
    await settle(tester);
    expect(find.text('session-abc'), findsOneWidget);
    await tester.tap(find.text('session-abc'));
    await settle(tester);

    // The composer is the chat segment's own widget; the workspace pane is the
    // workspace segment's. Landing back on the workspace is the bug, and so is
    // staying on the list at all.
    expect(find.byType(SessionsPage), findsNothing,
        reason: 'the list must not stay on top of the conversation');
    expect(find.byType(WorkspacePane), findsNothing,
        reason: 'restoring a session must leave the workspace segment');
    expect(find.byType(ChatPane), findsOneWidget,
        reason: 'the conversation is where the user asked to land');

    // The restored session's own `follow` is deliberately NOT asserted here.
    // `ChatController.open` awaits `StreamSubscription.cancel()` on a broadcast
    // controller, and that future never completes under `pump()`'s fake clock
    // (it does under `tester.runAsync` and on a real event loop). Asserting it
    // would either hang the test or tempt someone to move the `open()` call
    // back in front of the pop — which is the bug this test exists to pin.
  });

  testWidgets('D-048: 新会话 is reachable even while a session is open — '
      'D-031 auto-open used to hide the button forever', (tester) async {
    final gateway = FakeEngineGateway(sessions: [_row('session-abc')]);
    addTearDown(gateway.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        MachineEntry(
          id: 'relay-session',
          name: 'test-mini',
          firstPairedMs: now,
          params: SignedUrlParams(
            relayOrigin: Uri.parse('http://127.0.0.1:8080'),
            sessionId: 'relay-session',
            hash: 'h',
            mid: 'm',
            tMs: now,
            expMs: now + 3600 * 1000,
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
    )));
    // Long enough for the auto-open (D-031) to have happened.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(find.byType(ChatPane), findsOneWidget);
    // D-060: 这个入口从右下角 FAB 挪到了顶栏——那里是「会话级操作」该在的
    // 位置，FAB 的落点与 composer 的发送按钮完全重合，把主操作盖死了。
    // D-048 的**意图**（入口不该消失）不变，所以这条断言也只跟着换定位方式。
    expect(
      find.byIcon(Icons.add_comment_outlined),
      findsOneWidget,
      reason: 'a session being open is the normal state, not a reason to '
          'remove the only way to start a new one',
    );
  });

  testWidgets('D-042: the console grows a fifth segment and it reaches the '
      'trajectory pane', (tester) async {
    final gateway = FakeEngineGateway(sessions: [_row('session-abc')]);
    addTearDown(gateway.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        MachineEntry(
          id: 'relay-session',
          name: 'test-mini',
          firstPairedMs: now,
          params: SignedUrlParams(
            relayOrigin: Uri.parse('http://127.0.0.1:8080'),
            sessionId: 'relay-session',
            hash: 'h',
            mid: 'm',
            tMs: now,
            expMs: now + 3600 * 1000,
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(ConsolePage(
      store: store,
      gatewayFactory: (_) => gateway,
    )));
    await settle(tester);

    expect(find.text('轨迹'), findsOneWidget,
        reason: '轨迹是第 5 个分段，和对话/任务/主机/工作区并列');
    await tester.tap(find.text('轨迹'));
    await settle(tester);
    expect(find.byType(TrajectoryPane), findsOneWidget);
    expect(find.byType(ChatPane), findsNothing);
  });
}
