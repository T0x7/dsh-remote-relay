import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-070：回答气泡的 Markdown 渲染 + tool 行的调用详情。
///
/// 两个真机痛点：
/// 1. 模型输出是 markdown（`#`/`**`/代码块），现在按纯文本直出，满屏裸符号。
///    修法：正文用 gpt_markdown 渲染；**折叠预览保持纯文本**（18 行裁剪 +
///    maxLines 需要纯 Text，预览态看到原始符号也是可接受的「这是原文」信号），
///    展开后才是富文本。
/// 2. tool 行只显示工具名，参数和结果在事件里但被丢了。修法：tool/call 的
///    arguments（JSON 字符串）与 tool/result 的 text 块随行保存，点行展开
///    详情，再点收起。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
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

SessionWireEvent _toolCall(int seq, String callId, String name, String args) =>
    SessionWireEvent(
      type: 'tool/call',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'turn': 1,
        'step': 1,
        'callId': callId,
        'name': name,
        'arguments': args,
      },
    );

SessionWireEvent _toolResult(int seq, String callId, String name, String text) =>
    SessionWireEvent(
      type: 'tool/result',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'turn': 1,
        'step': 1,
        'callId': callId,
        'message': {
          'role': 'tool',
          'toolCallId': callId,
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
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
  await tester.pump(const Duration(milliseconds: 300));
  return controller;
}

void main() {
  testWidgets('markdown 正文按富文本渲染，裸符号不出现', (tester) async {
    await _openConsole(tester,
        records: [FollowEvent(_assistantMessage(1, '# 标题\n\n**加粗**正文与`代码`'))]);

    // 渲染后的富文本里有「加粗」「标题」，但 markdown 标记消失。
    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
    expect(find.textContaining('**'), findsNothing,
        reason: '加粗标记应该被渲染掉，不是原样输出');
    expect(find.textContaining('# 标题'), findsNothing,
        reason: '标题标记应该被渲染掉');
  });

  testWidgets('长 markdown 折叠预览去符号，展开后才变富文本', (tester) async {
    final md = '## 结论\n\n**要点**：先想后查。\n\n${'细节' * 500}';
    await _openConsole(tester, records: [FollowEvent(_assistantMessage(1, md))]);

    // 折叠态：18 行去符号预览（标题散列、加粗星号、反引号都不见了）。
    expect(find.textContaining('展开全文'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing,
        reason: '预览是给人读的摘要，markdown 符号是噪音（D-070.1）');
    expect(find.textContaining('要点：先想后查'), findsOneWidget,
        reason: '文字内容保留，只去符号');

    await tester.tap(find.textContaining('展开全文'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('要点', findRichText: true), findsOneWidget);
  });

  /// D-106：折叠预览里的 markdown 表格不该把语法符号露出来。
  ///
  /// 真机（vivo）实拍：长回答里的表格在折叠态原样显示成
  /// `| 位置 | 含义 |` / `|----|----|` / `| 20.00 | 9 月中下旬…` 一片竖线。
  /// 根因在 [_previewOf]：D-070.1 那套净化只认 `#`/`**`/反引号/列表符号，
  /// **完全没处理表格**——而折叠态走的正是它（富文本只在展开后才有）。
  testWidgets('D-106 折叠预览里的表格：竖线与分隔行不外露', (tester) async {
    final table = '| 位置 | 含义 |\n|----|----|\n| 20.00 | 整数关口 |\n| 21.00 | 前高 |';
    // 撑过 600 字折叠阈值，让这段真的走折叠预览路径。
    final filler = '补充说明行。' * 120; // 840 字 > _foldChars(600)
    await _openConsole(tester,
        records: [FollowEvent(_assistantMessage(1, '结论\n\n$table\n\n$filler'))]);

    expect(find.textContaining('展开全文'), findsOneWidget,
        reason: '前置条件：这段必须是折叠态，否则测的是富文本路径');

    expect(find.textContaining('|----'), findsNothing,
        reason: '表格分隔行是语法噪音，预览里不该出现（D-070.1 的同一条标准）');
    expect(find.textContaining('| 位置 |'), findsNothing,
        reason: '表头不该带着竖线原样出现');
    expect(find.textContaining('| 20.00'), findsNothing,
        reason: '数据行也不该带着竖线');

    expect(find.textContaining('整数关口'), findsOneWidget,
        reason: '去掉符号不等于去掉内容——表格里的字还得在');
    expect(find.textContaining('前高'), findsOneWidget);
  });

  testWidgets('tool 行点开看参数与结果，再点收起', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_toolCall(1, 'c1', 'mcp_dsh__feed_dive_next',
              '{"limit": 30, "q": "华为"}')),
          FollowEvent(_toolResult(
              2, 'c1', 'mcp_dsh__feed_dive_next', '{"ok": true}')),
        ]);

    // 收起态：dsh web 样式两行——「工具调用」标签 + 全名·参数摘要。
    expect(find.textContaining('mcp_dsh__feed_dive_next'), findsOneWidget);
    expect(find.textContaining('华为'), findsOneWidget,
        reason: '参数摘要在收起态就可见（对齐 dsh web 的 06067.HK 样式）');

    await tester.tap(find.textContaining('mcp_dsh__feed_dive_next'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('调用参数'), findsOneWidget);
    expect(find.textContaining('运行结果'), findsOneWidget);
    expect(find.textContaining('"ok": true'), findsOneWidget,
        reason: '展开后结果文本可见');

    await tester.tap(find.textContaining('mcp_dsh__feed_dive_next'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('调用参数'), findsNothing, reason: '再点工具行收起');
  });

  testWidgets('dsh web 样式：工具调用标签 + 参数摘要取关键值', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_toolCall(
              1, 'c1', 'mcp__eastchoice__choice_f10_basic_info',
              '{"symbol":"06067.HK","kline":30}')),
          FollowEvent(_toolResult(
              2, 'c1', 'mcp__eastchoice__choice_f10_basic_info', 'ok')),
        ]);

    expect(find.text('工具调用'), findsOneWidget, reason: 'dsh web 同款标签');
    expect(find.textContaining('06067.HK'), findsOneWidget,
        reason: '关键参数值上摘要行');
  });

  testWidgets('file_path 参数摘要取 basename，不露出全路径', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_toolCall(1, 'c1', 'read',
              '{"file_path":"/home/someone/.dsh-host/watchlist.toml"}')),
          FollowEvent(_toolResult(2, 'c1', 'read', 'read ok')),
        ]);

    expect(find.textContaining('watchlist.toml'), findsOneWidget);
    expect(find.textContaining('/home/someone'), findsNothing,
        reason: '摘要是给人扫一眼的，全路径进详情面板');
  });

  testWidgets('被前缀折叠裁掉名字的行：标签 + 结果首行摘要', (tester) async {
    await _openConsole(
        tester,
        records: [
          FollowEvent(_toolResult(
              2, 'c1', 'tool',
              '{"ok": true, "count": 30, "rows": [{"id": "202609163876019966"}]}')),
        ]);

    expect(find.text('工具调用'), findsOneWidget);
    expect(find.textContaining('"count": 30'), findsOneWidget,
        reason: '没有名字时用结果首行摘要，不再是干巴巴的 tool');
  });

  testWidgets('失败的工具行保留失败标记与错误名', (tester) async {
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
    gateway.pushFrame(_snapshot(records: [
      FollowEvent(_toolCall(1, 'c1', 'mcp_break', '{}')),
      FollowEvent(SessionWireEvent(
        type: 'tool/result',
        seq: 2,
        time: DateTime.now().millisecondsSinceEpoch,
        data: {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'error': {'name': 'TimeoutError'},
          'message': {
            'role': 'tool',
            'toolCallId': 'c1',
            'content': [
              {'type': 'text', 'text': 'timed out'},
            ],
          },
        },
      )),
    ]));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('TimeoutError'), findsOneWidget);
    expect(find.textContaining('工具调用 · TimeoutError'), findsOneWidget,
        reason: '失败在标签行就地标红，不需要多余图标');
  });
}
