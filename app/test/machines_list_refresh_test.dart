import 'dart:async';

import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/services/live_machine_scope.dart';
import 'package:dsh_remote_app/services/reminder_router.dart';
import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

/// design §5 多机器并发策略 on the list page: a 60 s low-frequency status sweep
/// for the machines the console is **not** driving, plus a manual pull. The dot
/// on a card reads that real tunnel state, so "机器离线（隧道断）时屏 A 仍显示
/// 绿灯" cannot happen again.
void main() {
  RemoteSessionSnapshot snapshot(TunnelState state,
          [EngineHealth engine = EngineHealth.unknown]) =>
      RemoteSessionSnapshot(
        tunnel: TunnelConnectionState(
            state: state, relayUrl: '', manualOff: false, engine: engine),
        active: null,
        sessions: const [],
        devices: const [],
      );

  Widget host(MachinesPage page) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: ScaffoldMessenger(child: page),
      );

  testWidgets('a pull refreshes once, by hand, and the puller waits for it',
      (tester) async {
    var asked = 0;
    final gate = Completer<RemoteSessionSnapshot?>();
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'mac-mini'))],
    );
    await tester.pumpWidget(host(MachinesPage(
      store: store,
      pollInterval: Duration.zero, // no background sweep in a widget test
      snapshotFetch: (_) {
        asked++;
        return gate.future;
      },
    )));
    await tester.pump();
    expect(asked, 0, reason: 'no tick, no data spent');

    await _pull(tester, settle: false);
    expect(asked, 1, reason: 'the puller triggered exactly one pass');
    expect(find.byType(RefreshProgressIndicator), findsOneWidget,
        reason: 'and it waits for the pass to finish');

    gate.complete(snapshot(TunnelState.connected));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('the card dot reads the polled tunnel state, not the clock',
      (tester) async {
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'mac-mini'))],
    );
    TunnelState served = TunnelState.connected;
    await tester.pumpWidget(host(MachinesPage(
      store: store,
      pollInterval: Duration.zero,
      snapshotFetch: (_) async => snapshot(served),
    )));
    await tester.pump();

    // The credential clock says "healthy" (fresh 24h window) — the dot must
    // still follow the tunnel.
    expect(_dotStage(tester, 'mac-mini'), ChipStage.neutral);

    served = TunnelState.reconnecting;
    await _pull(tester);
    expect(_dotStage(tester, 'mac-mini'), ChipStage.warn,
        reason: '隧道断开 must stop reading as a green light');

    served = TunnelState.manualOff;
    await _pull(tester);
    expect(_dotStage(tester, 'mac-mini'), ChipStage.danger);
  });

  testWidgets('with no snapshot the dot falls back to the credential clock',
      (tester) async {
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'mac-mini'))],
    );
    await tester.pumpWidget(host(MachinesPage(
      store: store,
      pollInterval: Duration.zero,
      snapshotFetch: (_) async => throw StateError('relay down'),
    )));
    await tester.pump();
    await _pull(tester);
    expect(_dotStage(tester, 'mac-mini'), ChipStage.neutral,
        reason: 'unknown is not a fault: the clock keeps its say');
  });

  testWidgets('a polled tunnel drop prompts once, and not with the switch off',
      (tester) async {
    final reminders = ReminderRouter();
    addTearDown(reminders.dispose);
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'mac-mini'))],
    );
    TunnelState served = TunnelState.reconnecting;
    Widget page(ReminderRouter router) => host(MachinesPage(
          store: store,
          reminders: router,
          pollInterval: Duration.zero,
          snapshotFetch: (_) async => snapshot(served),
        ));

    await tester.pumpWidget(page(reminders));
    await tester.pump();
    await _pull(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('mac-mini'), findsWidgets);
    await _snackGone(tester);

    // Same cause, second pass: no second prompt.
    await _pull(tester);
    expect(find.byType(SnackBar), findsNothing, reason: 'one cause, one prompt');
    await _snackGone(tester);

    // The tunnel is back, then down again → a new cause, a new prompt.
    served = TunnelState.connected;
    await _pull(tester);
    expect(find.byType(SnackBar), findsNothing, reason: 'the restore is not a prompt');
    await _snackGone(tester);

    served = TunnelState.reconnecting;
    await _pull(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    await _snackGone(tester);

    // And with 屏 G 提醒 off, the same outage is silent.
    reminders.enabled = false;
    served = TunnelState.connected;
    await _pull(tester);
    await _snackGone(tester);
    served = TunnelState.reconnecting;
    await _pull(tester);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the machine the console is driving is not polled', (tester) async {
    final live = LiveMachineScope()..claim('sess_s1');
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'live-one')),
        machineFrom(mintTestUrl(sessionId: 'sess_s2', name: 'idle-one')),
      ],
    );
    final asked = <String>[];
    await tester.pumpWidget(host(MachinesPage(
      store: store,
      live: live,
      pollInterval: Duration.zero,
      snapshotFetch: (entry) async {
        asked.add(entry.id);
        return snapshot(TunnelState.connected);
      },
    )));
    await tester.pump();

    await _pull(tester);
    expect(asked, ['sess_s2']);

    live.claim('sess_s2');
    await _pull(tester);
    expect(asked, ['sess_s2'], reason: 'the newly-claimed machine stops costing data');
  });

  test('the dot mapping is a pure function of the tunnel state', () {
    expect(
      MachineCard.dotStageOf(tunnel: TunnelState.connected, clock: ChipStage.warn),
      ChipStage.neutral,
      reason: 'a live tunnel outranks a stale credential warning',
    );
    expect(
      MachineCard.dotStageOf(tunnel: TunnelState.reconnecting, clock: ChipStage.neutral),
      ChipStage.warn,
    );
    expect(
      MachineCard.dotStageOf(tunnel: TunnelState.manualOff, clock: ChipStage.neutral),
      ChipStage.danger,
    );
    expect(
      MachineCard.dotStageOf(tunnel: null, clock: ChipStage.danger),
      ChipStage.danger,
      reason: 'no snapshot yet → the clock still says something',
    );
  });

  test('v3.177: a connected tunnel with an unreachable engine warns', () {
    expect(
      MachineCard.dotStageOf(
          tunnel: TunnelState.connected,
          engine: EngineHealth.unreachable,
          clock: ChipStage.warn),
      ChipStage.warn,
      reason: '2026-10-10：引擎重启轮换 token 后隧道照常绿灯、/api 全线 401'
          '——绿灯必须让位给实测的引擎不可达',
    );
    expect(
      MachineCard.dotStageOf(
          tunnel: TunnelState.connected, engine: EngineHealth.ok, clock: ChipStage.warn),
      ChipStage.neutral,
    );
    // 没有证据（unknown / 旧客户端快照缺字段）不构成故障，保持绿灯。
    expect(
      MachineCard.dotStageOf(
          tunnel: TunnelState.connected, engine: EngineHealth.unknown, clock: ChipStage.warn),
      ChipStage.neutral,
    );
    expect(
      MachineCard.dotStageOf(tunnel: TunnelState.connected, engine: null, clock: ChipStage.warn),
      ChipStage.neutral,
    );
  });

  testWidgets('the engine-unreachable hint renders only with evidence',
      (tester) async {
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [machineFrom(mintTestUrl(sessionId: 'sess_s1', name: 'mac-mini'))],
    );
    var served = snapshot(TunnelState.connected, EngineHealth.unknown);
    await tester.pumpWidget(host(MachinesPage(
      store: store,
      pollInterval: Duration.zero,
      snapshotFetch: (_) async => served,
    )));
    await _pull(tester);
    expect(find.textContaining('引擎没有应答'), findsNothing,
        reason: 'unknown 不是故障，健康态卡片布局必须逐像素不变');

    served = snapshot(TunnelState.connected, EngineHealth.unreachable);
    await _pull(tester);
    expect(find.textContaining('引擎没有应答'), findsOneWidget,
        reason: '黄态出现时必须告诉用户该检查什么（而不是引导重配对）');

    served = snapshot(TunnelState.reconnecting, EngineHealth.unreachable);
    await _pull(tester);
    await tester.pump();
    expect(find.textContaining('引擎没有应答'), findsNothing,
        reason: '隧道都断了，这句引擎提示没有意义——红态有自己的文案');
  });
}

/// Let the current SnackBar time out and animate away, so the next assertion
/// is about the *next* prompt rather than the one still on screen.
Future<void> _snackGone(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5)); // past the 4s display
  await tester.pump(const Duration(seconds: 1)); // the exit animation
}

/// One pull-to-refresh, driven the way a finger does it: a drag far enough
/// past the top edge to arm the indicator.
///
/// [settle] waits for the indicator to fold away again, so the next pull starts
/// from a clean edge. The pending-refresh case must not settle — the spinner
/// never stops, so `pumpAndSettle` would spin forever.
Future<void> _pull(WidgetTester tester, {bool settle = true}) async {
  await tester.drag(find.byType(ListView), const Offset(0, 300),
      warnIfMissed: false);
  await tester.pump(); // the drag is processed and the indicator arms
  if (settle) {
    // Two pumps, not one: the pass runs in a microtask, so the indicator only
    // starts folding away *after* the first pump, and a pull issued while it is
    // still folding never arms (the next pull would silently do nothing).
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The [ChipStage] the rendered dot for [name] is painting.
ChipStage _dotStage(WidgetTester tester, String name) => tester
    .widget<MachineCard>(find.ancestor(
      of: find.text(name),
      matching: find.byType(MachineCard),
    ))
    .dotStage;
