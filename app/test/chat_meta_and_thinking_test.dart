import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-069：系统注入与思考内容的展示，学习成熟对话 App 的两个模式：
///
/// 1. **系统注入 = 摘要条**（ChatGPT/Cline 模式）：`<system-reminder>`、
///    运行时上下文快照这类宿主/引擎注入的样板，**无论长短**默认收成一行
///    「标签 · 字数」，点开才见全文——它们不是对话内容，18 行折叠都嫌占屏。
/// 2. **思考内容 = 思考块**（Claude/Cherry Studio 模式）：流式 reasoning
///    先于答案实时显示，**回答正文一到自动收起**成「已思考 · N 字」，点开
///    可回看；引擎不持久化 reasoning（journal 全是纯 text 块，实测 40 份），
///    所以 durable 气泡不再带思考——这是平台事实，如实呈现。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent _developerMessage(int seq, String text) => SessionWireEvent(
      type: 'developer/message',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'turn': 1,
        'step': 1,
        'message': [
          {'type': 'text', 'text': text},
        ],
      },
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

Future<({FakeEngineGateway gateway, ChatController controller})> _openConsole(
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
  await tester.pump(const Duration(milliseconds: 300));
  return (gateway: gateway, controller: controller);
}

void main() {
  testWidgets('系统注入默认折叠成摘要条：全文不渲染、无展开全文按钮', (tester) async {
    final injected = '<system-reminder>\n${'注入内容' * 1000}'; // 4018 字
    await _openConsole(
        tester, records: [FollowEvent(_developerMessage(1, injected))]);

    expect(find.textContaining('系统提醒'), findsOneWidget,
        reason: '摘要条带标签与字数');
    expect(find.textContaining('4018'), findsOneWidget);
    expect(find.textContaining('展开全文'), findsNothing,
        reason: '注入内容不走 18 行折叠——收就是收成一行');
    expect(find.text(injected), findsNothing,
        reason: '收起时正文不建 widget，一万字的样板不该进元素树');
  });

  testWidgets('点摘要条展开全文，再点收回', (tester) async {
    final injected = '<system-reminder>\n${'注入内容' * 1000}';
    await _openConsole(
        tester, records: [FollowEvent(_developerMessage(1, injected))]);

    await tester.tap(find.textContaining('系统提醒'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(injected), findsOneWidget, reason: '用户点了就看全文');

    await tester.tap(find.textContaining('系统提醒'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(injected), findsNothing);
  });

  testWidgets('短注入也收摘要条：样板再短也不是对话', (tester) async {
    await _openConsole(tester,
        records: [FollowEvent(_developerMessage(1, '<system-reminder>\n短提醒'))]);

    expect(find.textContaining('系统提醒'), findsOneWidget);
    expect(find.text('<system-reminder>\n短提醒'), findsNothing);
  });

  testWidgets('运行时上下文快照同样识别为注入', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_developerMessage(
              1, 'Current runtime context. This snapshot supersedes earlier ones. ${'细' * 800}')),
        ]);

    expect(find.textContaining('运行时上下文'), findsOneWidget);
  });

  testWidgets('普通用户长消息仍是 18 行折叠，不误伤成摘要条', (tester) async {
    await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '用户' * 400))]);

    expect(find.textContaining('展开全文'), findsOneWidget);
    expect(find.textContaining('系统提醒'), findsNothing);
  });

  testWidgets('user 通道注入的运行时上下文同样收摘要条（实测引擎走 user 角色）', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_userMessage(
              1, 'Current runtime context. This snapshot supersedes. ${'细' * 900}')),
        ]);

    expect(find.textContaining('运行时上下文'), findsOneWidget);
    expect(find.textContaining('展开全文'), findsNothing,
        reason: '注入不走长度折叠——收就收成一行');
  });

  testWidgets('流式思考：先实时可见，回答一到自动收起', (tester) async {
    final (:gateway, :controller) = await _openConsole(tester);

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
      'chunk': {'type': 'reasoning-delta', 'text': '推演之中' * 30},
    }));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('思考'), findsOneWidget,
        reason: '思考先于答案实时可见');
    expect(find.textContaining('推演之中'), findsOneWidget);

    controller.applyFrame(_frame({
      'type': 'chunk',
      'attemptId': 'att-1',
      'revision': 3,
      'index': 2,
      'turn': 1,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': '回答正文开始了'},
    }));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('已思考'), findsOneWidget,
        reason: '正文一到，思考自动收成一行');
    expect(find.textContaining('推演之中'), findsNothing,
        reason: '收起后正文不渲染');
    expect(find.textContaining('回答正文'), findsOneWidget);
  });
}
