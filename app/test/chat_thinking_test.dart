import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-087：流式思考块默认收起（移动端惯例，对齐 Claude / ChatGPT App）。
///
/// 思考中只显示 pill「💭 思考中 · N 字」（字数实时增长证明活着），点开才看
/// 实时流、再点收起；回答正文到达照旧收成「已思考 · N 字」。钉住（用户点按）
/// 全权覆盖默认——思考中点开的状态在正文到达后保持展开。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionHeader _header(String id) =>
    SessionHeader(version: 4, id: id, createdAt: 0, isSeeded: false);

Future<ChatController> _openConsole(
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
  gateway.pushFrame(FollowSnapshot(
    header: _header(sessionId),
    cursor: 0,
    records: const [],
    hasMore: false,
    projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return controller;
}

Future<void> _pushChunk(
  WidgetTester tester,
  ChatController controller, {
  String attemptId = 'att-1',
  required Map<String, Object?> chunk,
}) async {
  controller.applyFrame(FollowAssistantStream({
    'type': 'chunk',
    'attemptId': attemptId,
    'revision': 1,
    'index': 1,
    'turn': 1,
    'step': 1,
    'chunk': chunk,
  }));
  // D-034：流式 token 的重绘按 48ms 窗口合并，pump 越过窗口才会落到屏幕。
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _startStream(
  WidgetTester tester,
  ChatController controller, {
  String attemptId = 'att-1',
}) async {
  controller.applyFrame(FollowAssistantStream({
    'type': 'start',
    'attemptId': attemptId,
    'revision': 1,
    'index': 0,
    'turn': 1,
    'step': 1,
  }));
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  const secret = '这是不该默认上屏的思考正文，只有点开才能看到。';

  testWidgets('思考中默认收起：只有 pill 与实时字数，正文不上屏', (tester) async {
    final controller = await _openConsole(tester);
    await _startStream(tester, controller);
    await _pushChunk(tester, controller,
        chunk: {'type': 'reasoning-delta', 'text': secret});

    expect(find.text('💭 思考中 · ${secret.length} 字'), findsOneWidget,
        reason: 'pill 必须带实时字数——字数增长证明模型活着');
    expect(find.textContaining('不该默认上屏'), findsNothing,
        reason: 'D-087：思考正文默认折叠，不点不上屏');
  });

  testWidgets('思考中点 pill 展开实时流，再点收起', (tester) async {
    final controller = await _openConsole(tester);
    await _startStream(tester, controller);
    await _pushChunk(tester, controller,
        chunk: {'type': 'reasoning-delta', 'text': secret});

    await tester.tap(find.text('💭 思考中 · ${secret.length} 字'));
    await tester.pump();
    expect(find.textContaining('不该默认上屏'), findsOneWidget,
        reason: '点开后实时流可见');
    expect(find.text('💭 思考中 · ${secret.length} 字（点按收起）'), findsOneWidget);

    await tester.tap(find.text('💭 思考中 · ${secret.length} 字（点按收起）'));
    await tester.pump();
    expect(find.textContaining('不该默认上屏'), findsNothing);
  });

  testWidgets('正文到达自动收成「已思考」；未钉住时不被思考流重新撑开', (tester) async {
    final controller = await _openConsole(tester);
    await _startStream(tester, controller);
    await _pushChunk(tester, controller,
        chunk: {'type': 'reasoning-delta', 'text': secret});
    // 正文 delta 到达 = answerStarted，active 随之关闭。
    await _pushChunk(tester, controller,
        chunk: {'type': 'text-delta', 'text': '这是回答正文。'});

    expect(find.text('💭 已思考 · ${secret.length} 字（点按展开）'), findsOneWidget,
        reason: '回答一到自动收起，时态从「思考中」切到「已思考」');
    expect(find.textContaining('不该默认上屏'), findsNothing);
    expect(find.textContaining('这是回答正文'), findsOneWidget,
        reason: '正文照常上屏');
  });

  testWidgets('思考中点开＝钉住：正文到达后保持展开', (tester) async {
    final controller = await _openConsole(tester);
    await _startStream(tester, controller);
    await _pushChunk(tester, controller,
        chunk: {'type': 'reasoning-delta', 'text': secret});
    await tester.tap(find.text('💭 思考中 · ${secret.length} 字'));
    await tester.pump();
    await _pushChunk(tester, controller,
        chunk: {'type': 'text-delta', 'text': '这是回答正文。'});

    expect(find.textContaining('不该默认上屏'), findsOneWidget,
        reason: '钉住的展开是用户显式意愿，不随正文到达被自动收起');
  });

  testWidgets('D-088：durable 气泡带 reasoning 块——历史会话的思考可回看', (tester) async {
    // 引擎 0.2.0-rc.2+ 把 reasoning 作为 assistant/message.content 的独立
    // 块落库（实测 347/1300 字等多份）。durable 路径必须把它带上。
    final gateway = FakeEngineGateway();
    final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
      ..startEvents();
    gateway.raiseReady();
    await controller.open('session-1');
    addTearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });
    await tester.pumpWidget(_host(ChatPane(controller: controller)));
    gateway.pushFrame(FollowSnapshot(
      header: SessionHeader(version: 4, id: 'session-1', createdAt: 0, isSeeded: false),
      cursor: 0,
      records: [
        FollowEvent(SessionWireEvent(
          type: 'assistant/message',
          seq: 25,
          time: DateTime.now().millisecondsSinceEpoch,
          data: {
            'turn': 2,
            'step': 1,
            'message': {
              'id': 'a25',
              'content': [
                {'type': 'reasoning', 'text': secret},
                {'type': 'text', 'text': 'Answer: 15.'},
              ],
              'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
              'role': 'assistant',
            },
            'stream': <Object?>[],
          },
        )),
      ],
      hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('💭 已思考 · ${secret.length} 字（点按展开）'), findsOneWidget,
        reason: 'durable 气泡的思考以折叠 chip 呈现');
    expect(find.textContaining('不该默认上屏'), findsNothing,
        reason: '默认收起——点开才看');

    await tester.tap(find.text('💭 已思考 · ${secret.length} 字（点按展开）'));
    await tester.pump();
    expect(find.textContaining('不该默认上屏'), findsOneWidget,
        reason: '展开可回看历史思考');
    expect(find.textContaining('Answer: 15'), findsOneWidget,
        reason: '回答正文照常上屏');
  });
}
