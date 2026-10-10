import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-071：发送消息后、模型首个可上屏输出（正文/思考）到来前，会话里应该
/// 有一颗「正在思考」指示器，而不是一段死寂。三条边界：
///
/// 1. 最后一条是**刚发的**用户消息（无任何模型输出）→ 显示；
/// 2. 流式 reasoning/正文一旦到达 → 消失——思考块或流式文本本身就是反馈，
///    两份「思考中」叠在一起是噪音；
/// 3. 尾消息是超过 3 分钟的陈旧用户消息（回合已被引擎中断的死会话）→
///    不显示——对着一具尸体转圈比死寂更糟。
///
/// 指示器带无限重复动画，测试里禁用 pumpAndSettle（永不停止），用定长 pump。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent _userMessage(int seq, String text, {DateTime? time}) =>
    SessionWireEvent(
      type: 'user/message',
      seq: seq,
      time: (time ?? DateTime.now()).millisecondsSinceEpoch,
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
}) =>
    FollowSnapshot(
      header: SessionHeader(version: 4, id: id, createdAt: 0, isSeeded: false),
      cursor: 0,
      records: records,
      hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

FollowAssistantStream _frame(Map<String, Object?> json) =>
    FollowAssistantStream(json);

Future<ChatController> _openConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
  List<FollowEvent> records = const [],
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
  gateway.pushFrame(_snapshot(id: sessionId, records: records));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  return controller;
}

void main() {
  testWidgets('用户刚发言、模型还没输出：显示思考指示器', (tester) async {
    await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '帮我看看这只票'))]);

    expect(find.byKey(const ValueKey('thinking-indicator')), findsOneWidget);
  });

  testWidgets('流式 reasoning 到达：指示器让位给思考块', (tester) async {
    final controller = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '帮我看看这只票'))]);

    controller.applyFrame(_frame({
      'type': 'start',
      'attemptId': 'att-1',
      'revision': 1,
      'index': 0,
      'turn': 1,
      'step': 1,
    }));
    controller.applyFrame(_frame({
      'type': 'chunk',
      'attemptId': 'att-1',
      'revision': 2,
      'index': 1,
      'turn': 1,
      'step': 1,
      'chunk': {'type': 'reasoning-delta', 'text': '先查持仓再对照快讯'},
    }));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // D-087：思考块默认收成 pill（正文不上屏），但块本身就是反馈，指示器不叠加。
    expect(find.textContaining('思考中 · 9 字'), findsOneWidget,
        reason: 'pill 带实时字数，证明模型活着');
    expect(find.textContaining('先查持仓'), findsNothing,
        reason: '正文默认不上屏——点开 pill 才看实时流');
    expect(find.byKey(const ValueKey('thinking-indicator')), findsNothing,
        reason: '思考块本身就是反馈，指示器不叠加');
  });

  testWidgets('回合完成（最后是 assistant 消息）：无指示器', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_userMessage(1, '帮我看看这只票')),
          FollowEvent(_assistantMessage(2, '看完了，结论如下')),
        ]);

    expect(find.byKey(const ValueKey('thinking-indicator')), findsNothing);
  });

  testWidgets('陈旧的尾部用户消息（>3 分钟）：不显示，对死会话不转圈', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_userMessage(
              1, '这条消息发出去就没下文了', time: DateTime.now().subtract(const Duration(minutes: 10)))),
        ]);

    expect(find.byKey(const ValueKey('thinking-indicator')), findsNothing);
  });
}
