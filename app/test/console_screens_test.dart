import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/sessions/sessions_page.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// T2.2/T2.3 — the session list and conversation screens, driven by a fake
/// gateway (plan T2.3 DoD: approval / question callbacks round-trip through
/// the event stream).
///
/// Everything is created **inside** the `testWidgets` body. A controller built
/// in `setUp` lives in the real-async zone while the test body runs on the
/// fake clock, so stream callbacks land on a clock `pumpAndSettle` never
/// advances — the same trap as the M1 socket tests, and it shows up as a
/// silently empty screen rather than a failure.
Widget _host(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent _userMessage(int seq, String text) => SessionWireEvent(
      type: 'user/message',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'id': 'm$seq',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
        'role': 'user',
      },
    );

SessionWireEvent _assistantMessage(int seq, String text) => SessionWireEvent(
      type: 'assistant/message',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'a$seq',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
          'role': 'assistant',
        },
        'stream': <Object?>[],
      },
    );

FollowSnapshot _snapshot({
  String id = 'session-1',
  List<FollowEvent> records = const [],
  SessionProjectionBaseline? projections,
}) =>
    FollowSnapshot(
      header: SessionHeader(version: 4, id: id, createdAt: 0, isSeeded: false),
      cursor: 0,
      records: records,
      hasMore: false,
      projections: projections ??
          const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

/// Mount a console backed by a fake gateway, with the journal opened.
Future<({FakeEngineGateway gateway, ChatController controller})> _openConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
}) async {
  final gateway = FakeEngineGateway();
  // D-032: the periodic $events re-open timer would keep pumpAndSettle from
  // ever settling in a widget test — tests do not exercise the refresh.
  final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
    ..startEvents();
  gateway.raiseReady();
  await controller.open(sessionId);
  addTearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });
  await tester.pumpWidget(_host(ChatPane(controller: controller)));
  gateway.pushFrame(_snapshot(id: sessionId));
  await tester.pumpAndSettle();
  return (gateway: gateway, controller: controller);
}

/// Same, but the snapshot carries a live projection baseline.
Future<({FakeEngineGateway gateway, ChatController controller})> _openLiveConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
}) async {
  final gateway = FakeEngineGateway();
  final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
    ..startEvents();
  gateway.raiseReady();
  await controller.open(sessionId);
  addTearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });
  await tester.pumpWidget(_host(ChatPane(controller: controller)));
  gateway.pushFrame(_snapshot(
    id: sessionId,
    projections: FakeEngineGateway.liveProjections,
  ));
  await tester.pumpAndSettle();
  return (gateway: gateway, controller: controller);
}

void main() {
  group('ChatEventReader', () {
    test('user message text comes from the content blocks', () {
      final bubbles = ChatEventReader.bubblesOf(_userMessage(1, 'hello'));
      expect(bubbles, hasLength(1));
      final message = bubbles.single as ChatMessage;
      expect(message.fromUser, isTrue);
      expect(message.text, 'hello');
    });

    test('assistant message reads message.content, not the event root', () {
      final bubbles = ChatEventReader.bubblesOf(_assistantMessage(2, 'ack'));
      final message = bubbles.single as ChatMessage;
      expect(message.fromUser, isFalse);
      expect(message.text, 'ack');
    });

    test('non-text blocks contribute nothing to the plain-text bubble', () {
      final event = SessionWireEvent(
        type: 'user/message',
        seq: 3,
        time: 0,
        data: {
          'content': [
            {'type': 'image', 'attachment': {'attachmentId': 'a'}},
            {'type': 'text', 'text': 'see this'},
          ],
        },
      );
      expect((ChatEventReader.bubblesOf(event).single as ChatMessage).text, 'see this');
    });

    test('a tool result becomes a tool node, flagged on error', () {
      final ok = SessionWireEvent(
        type: 'tool/result',
        seq: 4,
        time: 0,
        data: {
          'message': {'name': 'shell'},
        },
      );
      final failed = SessionWireEvent(
        type: 'tool/result',
        seq: 5,
        time: 0,
        data: {
          'message': {'name': 'shell'},
          'error': {'name': 'SpawnError', 'code': 'ENOENT'},
        },
      );
      expect((ChatEventReader.bubblesOf(ok).single as ToolNode).failed, isFalse);
      final node = ChatEventReader.bubblesOf(failed).single as ToolNode;
      expect(node.failed, isTrue);
      expect(node.detail, 'SpawnError');
    });

    test('a tool result is labelled from its tool/call, not a bare fallback',
        () {
      // Real `tool/result` data is `{turn, step, message}` — there is no
      // `name` on it (measured against a live session). The name lives on the
      // preceding `tool/call`, so the two must be paired by callId.
      final names = <String, ToolCallInfo>{};
      ChatEventReader.bubblesOf(
        SessionWireEvent(
          type: 'tool/call',
          seq: 1,
          time: 0,
          data: {'callId': 'call-7', 'name': 'shell', 'arguments': '{}'},
        ),
        toolCalls: names,
      );
      final node = ChatEventReader.bubblesOf(
        SessionWireEvent(
          type: 'tool/result',
          seq: 2,
          time: 0,
          data: {
            'callId': 'call-7',
            'message': {
              'content': [
                {'type': 'text', 'text': 'done'},
              ],
            },
          },
        ),
        toolCalls: names,
      ).single as ToolNode;

      expect(node.name, 'shell');
    });

    test('a tool/call alone renders no bubble of its own', () {
      final bubbles = ChatEventReader.bubblesOf(
        SessionWireEvent(
          type: 'tool/call',
          seq: 1,
          time: 0,
          data: {'callId': 'c', 'name': 'shell'},
        ),
        toolCalls: {},
      );
      expect(bubbles, isEmpty, reason: 'a call and its result are one line');
    });

    test('an unpaired tool result degrades to a named fallback, not a crash',
        () {
      final node = ChatEventReader.bubblesOf(
        SessionWireEvent(
          type: 'tool/result',
          seq: 3,
          time: 0,
          data: {'message': const <String, dynamic>{}},
        ),
      ).single as ToolNode;
      expect(node.name, 'tool');
    });

    test('bookkeeping events render as nothing', () {
      for (final type in ['turn/start', 'step/end', 'llm/retry', 'todo/write']) {
        final event = SessionWireEvent(type: type, seq: 1, time: 0, data: const {});
        expect(ChatEventReader.bubblesOf(event), isEmpty, reason: type);
      }
    });

    test('a subagent label rides on the message for the lineage chip', () {
      final bubbles = ChatEventReader.bubblesOf(
        _assistantMessage(6, 'from the child'),
        subagentLabel: 'researcher',
      );
      expect((bubbles.single as ChatMessage).subagentLabel, 'researcher');
    });
  });

  group('chat pane renders the journal', () {
    testWidgets('shows the empty state until a session is opened',
        (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      expect(find.text('选一个会话开始'), findsOneWidget);
    });

    testWidgets('renders user and agent bubbles from follow frames',
        (tester) async {
      final env = await _openConsole(tester);

      env.gateway.pushEvent(_userMessage(1, '把回测窗口改成 90 天'));
      env.gateway.pushEvent(_assistantMessage(2, '已安排子代理'));
      await tester.pumpAndSettle();

      expect(find.text('把回测窗口改成 90 天'), findsOneWidget);
      expect(find.text('已安排子代理'), findsOneWidget);
    });

    testWidgets('restores the snapshot records on open', (tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero);
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await controller.open('session-1');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));

      gateway.pushFrame(_snapshot(records: [
        FollowEvent(_userMessage(1, 'restored')),
        FollowEvent(_assistantMessage(2, 'reply')),
      ]));      await tester.pumpAndSettle();

      expect(find.text('restored'), findsOneWidget);
      expect(find.text('reply'), findsOneWidget);
    });

    testWidgets('the context bar shows a ring only when the engine reported usage',
        (tester) async {
      // A snapshot WITHOUT a contextPressure projection must read as unknown,
      // never as 0% — absence is not zero.
      await _openConsole(tester);
      expect(find.text('上下文 未知'), findsOneWidget);
    });

    testWidgets('a live baseline renders the ratio and stat capsules',
        (tester) async {
      await _openLiveConsole(tester);
      expect(find.textContaining('上下文 38%'), findsOneWidget);
      expect(find.textContaining('tok/s'), findsOneWidget);
      expect(find.textContaining('缓存'), findsOneWidget);
      expect(find.text('4 轮'), findsOneWidget);
    });

    testWidgets('a tool result renders as a tool node', (tester) async {
      final env = await _openConsole(tester);
      // Real shape: the name lives on `tool/call`, and the result pairs with
      // it by callId (a live session's `tool/result` data is
      // `{turn, step, message}` with no name at all).
      env.gateway.pushEvent(SessionWireEvent(
        type: 'tool/call',
        seq: 8,
        time: 0,
        data: {'callId': 'call-1', 'name': 'shell', 'arguments': '{}'},
      ));
      env.gateway.pushEvent(SessionWireEvent(
        type: 'tool/result',
        seq: 9,
        time: 0,
        data: {
          'callId': 'call-1',
          'message': {
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          },
        },
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('shell'), findsOneWidget);
    });
  });

  group('composer', () {
    testWidgets('sending posts the text and clears the field', (tester) async {
      final env = await _openConsole(tester);

      await tester.enterText(find.byType(TextField), 'hello engine');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(env.gateway.sentPrompts.single.single.text, 'hello engine');
      expect(
        env.gateway.calls.lastWhere((c) => c.call == 'prompt').args,
        {'sessionId': 'session-1', 'mode': 'queue'},
      );
    });

    testWidgets('a read-only subagent gets no composer at all', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero);
      addTearDown(controller.dispose);
      await controller.open(
        'child-1',
        subagentLabel: 'researcher',
        mode: SubagentMode.oneShot,
      );
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      // The opening snapshot always arrives on the wire; without it the pane
      // stays on its loading spinner, which never settles.
      gateway.pushFrame(_snapshot(id: 'child-1'));
      await tester.pumpAndSettle();

      expect(find.text('该子代理只读，无法输入'), findsOneWidget);
      expect(find.byType(TextField), findsNothing,
          reason: 'a one-shot child is terminal — do not offer input at all');
    });

    testWidgets('an engine failure on send renders an inline card',
        (tester) async {
      final env = await _openConsole(tester);
      env.gateway.failPromptWith = 'session/writer-held';

      await tester.enterText(find.byType(TextField), 'conflicting edit');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('另一端正在编辑此会话，稍候再试'), findsOneWidget);
      expect(find.textContaining('session/writer-held'), findsOneWidget,
          reason: 'the raw engine code rides the mono line for bug reports');
    });
  });

  group('approval round trip (T2.3 DoD)', () {
    testWidgets('an approval waterfall renders an inline card', (tester) async {
      final env = await _openConsole(tester);
      env.gateway.raiseWaterfall('approval/request', {
        'toolName': 'write_file',
        'callId': 'call-1',
        'reason': 'python scripts/backtest.py --window 90d',
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('write_file'), findsOneWidget);
      expect(find.textContaining('backtest.py'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    });

    testWidgets('allow sends the BARE wire string, then the card clears',
        (tester) async {
      final env = await _openConsole(tester);
      env.gateway.raiseWaterfall('approval/request', {'toolName': 'write_file'});
      await tester.pumpAndSettle();

      await tester.tap(find.text('允许'));
      await tester.pumpAndSettle();

      expect(env.gateway.sentAnswers.single, isA<String>());
      expect(env.gateway.sentAnswers.single, 'allowed-once',
          reason: 'the wire value is the bare string, not an envelope');
      expect(find.text('允许'), findsNothing, reason: 'the card is settled');
    });

    testWidgets('reject sends the other bare string', (tester) async {
      final env = await _openConsole(tester);
      env.gateway.raiseWaterfall('approval/request', {'toolName': 'write_file'});
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();

      expect(env.gateway.sentAnswers.single, 'rejected');
    });

    testWidgets('the answer echoes the ready-frame clientId', (tester) async {
      final gateway = FakeEngineGateway();
      // D-079: `open` now re-subscribes `$events`, minting a new generation.
      // This test pins the *declared* clientId, so the fake stays manual.
      gateway.autoEventReady = false;
      final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      gateway.raiseReady(clientId: 'client-42');
      await controller.open('session-1');
      gateway.raiseReady(clientId: 'client-42');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      gateway.pushFrame(_snapshot());
      await tester.pumpAndSettle();

      gateway.raiseWaterfall('approval/request', {'toolName': 'shell'});
      await tester.pumpAndSettle();
      await controller.answerApproval(ApprovalOutcome.allowedOnce);
      await tester.pumpAndSettle();

      final call = gateway.calls.lastWhere((c) => c.call == 'answerEvent');
      expect((call.args! as Map<String, dynamic>)['clientId'], 'client-42');
    });
  });

  group('plan review round trip (屏 P groundwork)', () {
    void raisePlanReview(FakeEngineGateway gateway) =>
        gateway.raiseWaterfall('user-questions/request', {
          'questions': [
            {
              'id': 'plan-review',
              'question': 'Approve this plan and leave plan mode?',
              'detail': '# 计划\n\n1. 改窗口\n2. 重跑',
              'options': [
                {'label': 'Approve'},
                {'label': 'Keep planning'},
              ],
              'intent': {'kind': 'plan-review', 'approve': 'Approve', 'callId': 'call-9'},
            },
          ],
        });

    testWidgets('a plan review renders the plan body and both labels',
        (tester) async {
      final env = await _openConsole(tester);
      raisePlanReview(env.gateway);
      await tester.pumpAndSettle();

      expect(find.text('计划待批准'), findsOneWidget);
      expect(find.textContaining('改窗口'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Keep planning'), findsOneWidget);
    });

    testWidgets('approve sends {answers:[{id, selected:[label]}]} as a bare value',
        (tester) async {
      final env = await _openConsole(tester);
      raisePlanReview(env.gateway);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      expect(env.gateway.sentAnswers.single, {
        'answers': [
          {'id': 'plan-review', 'selected': ['Approve']},
        ],
      });
    });

    testWidgets('decline sends the other label — matched by name, not position',
        (tester) async {
      final env = await _openConsole(tester);
      raisePlanReview(env.gateway);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep planning'));
      await tester.pumpAndSettle();

      expect(
        (env.gateway.sentAnswers.single! as Map<String, dynamic>)['answers'],
        [
          {'id': 'plan-review', 'selected': ['Keep planning']},
        ],
      );
    });

    testWidgets('a question that is not a plan review shows the generic state',
        (tester) async {
      final env = await _openConsole(tester);
      env.gateway.raiseWaterfall('user-questions/request', {
        'questions': [
          {
            'id': 'q1',
            'question': 'Which environments?',
            'options': [
              {'label': 'staging'},
              {'label': 'prod'},
            ],
            'multiSelect': true,
          },
        ],
      });
      await tester.pumpAndSettle();

      expect(find.text('agent 正在等待你的回答'), findsOneWidget);
      expect(find.text('计划待批准'), findsNothing);
    });
  });

  group('sessions list (屏 M)', () {
    SessionSummary row(String id, {String? parent, bool running = false}) =>
        SessionSummary(
          sessionId: id,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          running: running,
          blank: false,
          agentAvailable: true,
          parentSessionId: parent,
        );

    testWidgets('renders parents with subagent children indented under them',
        (tester) async {
      final gateway = FakeEngineGateway(sessions: [
        row('parent-1'),
        row('child-1', parent: 'parent-1', running: true),
        row('parent-2'),
      ]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        SessionsPage(gateway: gateway, machineName: 'mac-mini', onOpenSession: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('parent-1'), findsOneWidget);
      expect(find.text('parent-2'), findsOneWidget);
      expect(find.text('child-1'), findsOneWidget);

      // The child is visually nested, not a sibling row.
      final parentBox = tester.getRect(find.text('parent-1'));
      final childBox = tester.getRect(find.text('child-1'));
      expect(childBox.left, greaterThan(parentBox.left),
          reason: 'a subagent child is indented under its parent');
    });

    testWidgets('a child whose parent is gone is promoted, not dropped',
        (tester) async {
      final gateway = FakeEngineGateway(sessions: [row('orphan', parent: 'vanished')]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        SessionsPage(gateway: gateway, machineName: 'm', onOpenSession: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('orphan'), findsOneWidget,
          reason: 'losing a live session from the list is worse than a flat row');
    });

    testWidgets('tapping a row restores that engine-side session',
        (tester) async {
      final gateway = FakeEngineGateway(sessions: [row('parent-1')]);
      addTearDown(gateway.dispose);
      SessionSummary? opened;

      await tester.pumpWidget(_host(
        SessionsPage(
          gateway: gateway,
          machineName: 'm',
          onOpenSession: (session) => opened = session,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('parent-1'));
      expect(opened?.sessionId, 'parent-1');
    });

    testWidgets('tapping a subagent child opens the child, not its parent',
        (tester) async {
      final gateway = FakeEngineGateway(sessions: [
        row('parent-1'),
        row('child-1', parent: 'parent-1'),
      ]);
      addTearDown(gateway.dispose);
      SessionSummary? opened;

      await tester.pumpWidget(_host(
        SessionsPage(
          gateway: gateway,
          machineName: 'm',
          onOpenSession: (session) => opened = session,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('child-1'));
      expect(opened?.sessionId, 'child-1',
          reason: 'the row renders the child, so tapping it must open the child');
    });

    testWidgets('a running session carries the running chip', (tester) async {
      final gateway = FakeEngineGateway(sessions: [row('s1', running: true)]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        SessionsPage(gateway: gateway, machineName: 'm', onOpenSession: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('运行中'), findsOneWidget);
    });

    testWidgets('an engine failure renders an inline card with a retry',
        (tester) async {
      final gateway = FakeEngineGateway()..failListSessions = 'gateway/internal';
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        SessionsPage(gateway: gateway, machineName: 'm', onOpenSession: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('引擎返回了未知错误'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('an empty list explains the two-ends story', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        SessionsPage(gateway: gateway, machineName: 'm', onOpenSession: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('还没有会话'), findsOneWidget);
      expect(find.textContaining('两端接力'), findsOneWidget);
    });
  });
}
