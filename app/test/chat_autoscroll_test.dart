import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-072：流式输出时的滚动跟随。
///
/// 真机反馈：模型输出时新内容长在视口下面，列表不跟着走，得手动滑。
/// 规则对齐成熟聊天 App：
/// 1. **贴底即跟随**——用户在列表底部（±80px）时，内容增长自动钉住底部；
/// 2. **上滚不拽人**——用户往上翻历史时不自动拉回，右下角出现
///    「回到底部」悬浮钮，点它或手动滑回底部即恢复跟随。
///
/// 滚动位置经 ScrollableState 读取；动画/帧时序一律定长 pump。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
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
  await tester.pump(const Duration(milliseconds: 300));
  return controller;
}

ScrollPosition _listPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
          of: find.byType(ListView), matching: find.byType(Scrollable)),
    ).position;

void _delta(ChatController controller, int revision, String text) =>
    controller.applyFrame(_frame({
      'type': 'chunk',
      'attemptId': 'att-1',
      'revision': revision,
      'index': 1,
      'turn': 1,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': text},
    }));

void main() {
  testWidgets('流式输出增长时贴底跟随：视口始终钉在最新内容', (tester) async {
    final controller = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    controller.applyFrame(_frame({
      'type': 'start',
      'attemptId': 'att-1',
      'revision': 1,
      'index': 0,
      'turn': 1,
      'step': 1,
    }));
    // 第一段长文本：内容撑爆视口。
    _delta(controller, 2, '输出' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final p1 = _listPosition(tester);
    expect(p1.pixels, greaterThan(p1.maxScrollExtent - 4),
        reason: '贴底状态下内容增长应自动钉在底部');

    // 第二段：继续增长，依旧跟随。
    _delta(controller, 3, '继续' * 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final p2 = _listPosition(tester);
    expect(p2.pixels, greaterThan(p2.maxScrollExtent - 4));
  });

  testWidgets('用户上滚看历史：不被拽回，悬浮钮出现，点它回底', (tester) async {
    final controller = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    controller.applyFrame(_frame({
      'type': 'start',
      'attemptId': 'att-1',
      'revision': 1,
      'index': 0,
      'turn': 1,
      'step': 1,
    }));
    // 第一段：内容远超视口（~5000 字），让 600px 的 drag 滚不到头。
    _delta(controller, 2, '输出' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 用户上滚 600px 阅读历史。
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final before = _listPosition(tester);
    expect(before.pixels, lessThan(before.maxScrollExtent - 80),
        reason: 'drag 应该真的把列表滚离底部');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget,
        reason: '离底了就该给一颗回底按钮');

    // 内容继续增长：不拽人。
    _delta(controller, 3, '新增' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final after = _listPosition(tester);
    expect(after.pixels, lessThan(after.maxScrollExtent - 100),
        reason: '用户在看历史，自动跟随必须闭嘴');

    // 点悬浮钮回底，恢复跟随。
    await tester.tap(find.byKey(const ValueKey('scroll-to-bottom')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final back = _listPosition(tester);
    expect(back.pixels, greaterThan(back.maxScrollExtent - 4));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing);
  });
}
