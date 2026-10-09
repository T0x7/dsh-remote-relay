import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-076：会话页显示当前会话所属的 agent 预设。
///
/// 数据一直在手上：journal 首帧 header 就带 `agentPreset`（contract §1.7，
/// 引擎实测连默认会话都写 `"agentPreset":"standard"`），此前 controller 只取
/// 了 title 把它扔了。展示位置：ContextBar（会话级状态条）最左侧一颗
/// 非交互小 Chip——它是「这个会话由哪种 agent 处理」的常驻答案。
///
/// 两条边界：
/// - header 没带 agentPreset（理论上不会，但契约是可空的）→ 不显示，
///   不编造「standard」；
/// - 换会话时必须重置——上一个会话的 preset 不能泄漏到下一个会话。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

FollowSnapshot _snapshot({
  String id = 'session-1',
  String? agentPreset,
  List<FollowEvent> records = const [],
}) =>
    FollowSnapshot(
      header: SessionHeader(
          version: 4, id: id, createdAt: 0, isSeeded: false,
          agentPreset: agentPreset),
      cursor: 0,
      records: records,
      hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

Future<ChatController> _openConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
  String? agentPreset,
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
  gateway.pushFrame(_snapshot(id: sessionId, agentPreset: agentPreset, records: records));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return controller;
}

void main() {
  testWidgets('header 带 agentPreset：ContextBar 显示 preset id', (tester) async {
    await _openConsole(tester,
        records: [FollowEvent(SessionWireEvent(
          type: 'assistant/message',
          seq: 1,
          time: DateTime.now().millisecondsSinceEpoch,
          data: {
            'turn': 1,
            'step': 1,
            'message': {
              'id': 'a1',
              'content': [
                {'type': 'text', 'text': '结论'},
              ],
              'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
              'role': 'assistant',
            },
            'stream': <Object?>[],
          },
        ))],
        agentPreset: 'stock-researcher');

    expect(find.textContaining('stock-researcher'), findsOneWidget,
        reason: '「这个会话由哪个 agent 处理」要有常驻答案');
  });

  testWidgets('header 无 agentPreset：不显示，不编造 standard', (tester) async {
    await _openConsole(tester,
        records: [FollowEvent(SessionWireEvent(
          type: 'assistant/message',
          seq: 1,
          time: DateTime.now().millisecondsSinceEpoch,
          data: {
            'turn': 1,
            'step': 1,
            'message': {
              'id': 'a1',
              'content': [
                {'type': 'text', 'text': '结论'},
              ],
              'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
              'role': 'assistant',
            },
            'stream': <Object?>[],
          },
        ))]);

    expect(find.textContaining('stock-researcher'), findsNothing);
    expect(find.text('standard'), findsNothing, reason: '没数据就不显示');
  });

  test('换会话重置：上一个会话的 preset 不泄漏', () async {
    final gateway = FakeEngineGateway();
    final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
      ..startEvents();
    addTearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });
    gateway.raiseReady();
    await controller.open('session-a');
    controller.applyFrame(FollowSnapshot(
      header: SessionHeader(
          version: 4, id: 'session-a', createdAt: 0, isSeeded: false,
          agentPreset: 'stock-researcher'),
      cursor: 0, records: const [], hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    ));
    expect(controller.sessionPreset, 'stock-researcher');

    await controller.open('session-b');
    expect(controller.sessionPreset, isNull,
        reason: '还没收到新会话首帧，旧的必须先清掉');
  });
}
