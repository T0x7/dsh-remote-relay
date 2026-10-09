import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-068：会话页长文案折叠。
///
/// 动机（真机反馈）：模拟盘交易 Agent 的「宪法红线」提示词一屏多全是它，
/// 把对话流挤成一条竖线。修法是每条消息超过阈值默认折叠到 18 行 + 渐隐，
/// 尾部给「展开全文（N 字）/ 收起」。三条边界：
///
/// 1. **流式中的消息不折叠**——它挂在列表底部自动滚动区，用户正看着它长，
///    折叠等于把正在打的字藏起来；收进 durable 气泡后才允许折叠。
/// 2. **展开状态按事件 seq 记在页面 State**——ListView 重建会把局部
///    StatefulWidget 的状态冲掉，用户展开过的消息必须活过每一次 notify。
/// 3. 短消息一个按钮都不多给。
///
/// 剪裁本身用 `maxLines + TextOverflow.fade`：Text 的 data 始终是全文，
/// 断言可折叠与否看 `maxLines` 与按钮，不造第二份截断文本。
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

FollowAssistantStream _start({
  String attemptId = 'att-1',
  int revision = 1,
}) =>
    FollowAssistantStream({
      'type': 'start',
      'attemptId': attemptId,
      'revision': revision,
      'index': 0,
      'turn': 1,
      'step': 1,
    });

FollowAssistantStream _textDelta(int revision, String text,
        {String attemptId = 'att-1'}) =>
    FollowAssistantStream({
      'type': 'chunk',
      'attemptId': attemptId,
      'revision': revision,
      'index': 1,
      'turn': 1,
      'step': 1,
      'chunk': {'type': 'text-delta', 'index': 0, 'text': text},
    });

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

/// 找到渲染 [text] 的那个 Text widget（气泡里全文始终是同一个 data）。
Text _bubbleText(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text));

void main() {
  testWidgets('超长文案默认折叠：18 行裁剪 + 展开按钮，无收起', (tester) async {
    final long = '宪' * 800; // > 600 字阈值
    await _openConsole(tester, records: [FollowEvent(_userMessage(1, long))]);

    final body = _bubbleText(tester, long);
    expect(body.maxLines, 18, reason: '默认只给 18 行，别让一条提示词占满一屏');
    expect(body.overflow, TextOverflow.fade);
    expect(find.textContaining('展开全文'), findsOneWidget);
    expect(find.text('收起'), findsNothing);
  });

  testWidgets('展开看全文、收起折回，状态活过列表重建', (tester) async {
    final long = '宪' * 800;
    final (:gateway, :controller) = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, long))]);

    await tester.tap(find.textContaining('展开全文'));
    await tester.pump(const Duration(milliseconds: 300));
    // D-070 起展开态是 markdown 富文本（无整块纯 Text），用按钮态判定。
    expect(find.textContaining('展开全文'), findsNothing,
        reason: '展开后全文可见');
    expect(find.text('收起'), findsOneWidget);

    // 列表因新消息重建，展开状态不能丢——状态记在页面 State（按 seq），
    // 不在会随重建丢状态的局部 widget 里。
    controller.applyFrame(FollowEvent(_userMessage(2, '下一条短消息')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('收起'), findsOneWidget,
        reason: '新消息触发的重建不该把用户展开过的消息折回去');
    expect(find.textContaining('展开全文'), findsNothing);

    await tester.tap(find.text('收起'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_bubbleText(tester, long).maxLines, 18);
    expect(find.textContaining('展开全文'), findsOneWidget);
  });

  testWidgets('短文案不折叠：全文直出，无按钮', (tester) async {
    await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '短消息，一两行就完了'))]);

    expect(find.textContaining('展开全文'), findsNothing);
    expect(find.textContaining('收起'), findsNothing);
  });

  testWidgets('流式中的长消息不折叠：正在打出的字不藏', (tester) async {
    final (:gateway, :controller) = await _openConsole(tester);

    controller.applyFrame(_start());
    controller.applyFrame(_textDelta(2, '流' * 800));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('展开全文'), findsNothing,
        reason: '流式气泡挂在底部自动滚动区，折叠等于把正在生成的回答藏起来');
    gateway.pushFrame(_snapshot()); // 触发一次重建，流式判定要稳定
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('展开全文'), findsNothing);
  });
}
