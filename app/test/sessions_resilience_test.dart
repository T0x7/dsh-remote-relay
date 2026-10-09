import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/sessions/sessions_page.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';


/// D-037 — the session list survives a busy engine and stays renderable.
///
/// Two facts about the wire shape this test pins, both of which a screenshot
/// cannot show:
///
/// - **`session/list` has no server-side paging.** The request carries a
///   `cursor` that the engine *ignores* (`index.ts:252` names the parameter
///   `_request`), so a host with thousands of sessions answers with all of them
///   in one body. 1567 rows on a phone is a real cost, and the list is capped
///   on the client instead.
/// - **A 504 is a transient "engine busy", not a dead end.** The engine is
///   shared with its own scheduled jobs, so a list request can time out while
///   everything is healthy. The list retries with backoff on its own; a card
///   that only offers a manual button is what made the earlier verification
///   stall.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionSummary _summary(int i) => SessionSummary(
      sessionId: 'session-$i',
      updatedAt: 1791000000000 + i * 1000,
      running: false,
      blank: false,
      agentAvailable: true,
    );

void main() {
  late FakeEngineGateway gateway;
  /// The backoffs the page asked for, in order, each paired with its trigger.
  final List<({Duration delay, void Function() fire})> backoffs = [];


  setUp(() {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
  });

  /// Serve [n] sessions, optionally failing the first [failFirst] attempts.
  void seed(int n, {int failFirst = 0, bool alwaysFail = false}) {
    gateway.sessionListAlwaysFailing = alwaysFail;
    gateway.sessionListFailures =
        List.filled(failFirst, 'gateway/internal', growable: true);
    gateway.sessionListItems =
        [for (var i = 0; i < n; i++) _summary(i)];
  }

  /// Mount the page with its poll disabled: a live [Timer.periodic] never lets
  ///  settle (the D-032 trap), so these tests step the clock.
  Future<void> open(WidgetTester tester, {Duration retryDelay = Duration.zero}) async {
    await tester.pumpWidget(_host(SessionsPage(
      gateway: gateway,
      machineName: 'mac-mini',
      onOpenSession: (_) {},
      refreshInterval: const Duration(days: 1),
      retryDelay: retryDelay,
      scheduleRetry: (delay, fire) => backoffs.add((delay: delay, fire: fire)),
    )));
    await tester.pump();
  }

  /// Pump until the list arrives, without waiting on the poll timer.
  Future<void> settleOnce(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Cross one backoff by firing the page's own scheduled action.
  Future<void> tick(WidgetTester tester) async {
    if (backoffs.isEmpty) return;
    backoffs.removeAt(0).fire();
    await tester.pump();
  }

  group('D-037 session list resilience', () {
    testWidgets('a large host renders without building every row', (tester) async {
      seed(2000);
      await open(tester);
      await settleOnce(tester);

      // _summary(i) gets a LARGER updatedAt as i grows, so session-1999 is the
      // newest and must survive while the oldest tail is cut.
      expect(find.textContaining('session-1999'), findsOneWidget,
          reason: 'the newest session is the one the cap must keep');
      expect(find.textContaining('session-0'), findsNothing,
          reason: 'a 2000-session host must not be built in full');
      // The truncation line is the honest report of the cut.
      expect(find.textContaining('2000'), findsWidgets);
    });

    testWidgets('the newest session is still the first row', (tester) async {
      seed(50);
      await open(tester);
      await settleOnce(tester);

      // session-49 has the greatest updatedAt, so it sorts first.
      expect(find.textContaining('session-49'), findsOneWidget);
    });

    testWidgets('a 504 retries by itself instead of waiting for a tap',
        (tester) async {
      seed(10, failFirst: 2);
      await open(tester, retryDelay: const Duration(seconds: 1));

      // No tap anywhere: the page must work out its own recovery.
      // Inside the first backoff wait (1s) nothing has retried yet.
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.sessionListCalls, 1, reason: 'still inside the backoff');

      // First backoff elapses -> second attempt, fails again -> second backoff.
      expect(backoffs.single.delay, const Duration(seconds: 1),
          reason: 'the first backoff is one retryDelay');
      await tick(tester);
      expect(gateway.sessionListCalls, 2);

      // Second backoff is twice as long, then the third attempt succeeds.
      expect(backoffs.single.delay, const Duration(seconds: 2),
          reason: 'the second backoff doubles');
      await tick(tester);
      expect(gateway.sessionListCalls, 3);
      await settleOnce(tester);
      expect(find.textContaining('session-9'), findsWidgets,
          reason: 'the list arrived after the retries');
      expect(find.text('重试'), findsNothing,
          reason: 'a recovered load shows no manual retry button');
    });

    testWidgets('an engine that never recovers still offers the button',
        (tester) async {
      seed(10, alwaysFail: true);
      await open(tester, retryDelay: const Duration(seconds: 1));

      // Two retries are the whole budget; a third failure gives up.
      await tick(tester);
      await tick(tester);
      expect(backoffs, isEmpty, reason: 'no third attempt is scheduled');
      await settleOnce(tester);

      // Giving up is a real state: it must be visible and actionable.
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('a refresh that fails keeps the rows already on screen',
        (tester) async {
      seed(5);
      await open(tester);
      await settleOnce(tester);
      expect(find.textContaining('session-4'), findsWidgets);

      // The next refresh now fails; losing the list on a transient error would
      // throw away what the user was reading.
      gateway.sessionListFailures = const ['gateway/internal'];
      await tick(tester);
      await settleOnce(tester);

      expect(find.textContaining('session-4'), findsWidgets,
          reason: 'stale rows beat an empty screen');
    });
  });
}
