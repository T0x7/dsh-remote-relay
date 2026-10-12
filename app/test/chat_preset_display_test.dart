import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  Projections values = const Projections(),
}) =>
    FollowSnapshot(
      header: SessionHeader(
          version: 4, id: id, createdAt: 0, isSeeded: false,
          agentPreset: agentPreset),
      cursor: 0,
      records: records,
      hasMore: false,
      projections: SessionProjectionBaseline(asOfSeq: 0, values: values),
    );

/// D-105 用：一份「什么都报了」的状态条——上下文占用、tok/s、缓存、轮数
/// 全都有，正是真机上把这一栏挤爆的那种组合。
Projections _busyValues() => const Projections(
      tokenUsage: TokenUsageProjection(
          uncachedInputTokens: 1000,
          outputTokens: 500,
          cacheReadTokens: 9000,
          cacheWriteTokens: 0),
      contextPressure: ContextPressure(
          pressureTokens: 11000, projectedTokens: 12000, contextWindow: 100000),
      sessionStats: SessionStatsProjection(
          turns: 3,
          steps: 7,
          llmMs: 1000,
          toolMs: 500,
          ttftMs: 300,
          ttftSteps: 2,
          decodeMs: 2000,
          decodeTokens: 4000),
    );

Future<ChatController> _openConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
  String? agentPreset,
  List<FollowEvent> records = const [],
  Projections values = const Projections(),
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
      agentPreset: agentPreset,
      records: records,
      values: values));
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

  /// D-105：窄屏下 agent 名不得被截断——它回答的是「这段对话由哪种 agent
  /// 处理」，比 tok/s、缓存这些装饰性数字更该保住完整。
  ///
  /// 真机（小米 393dp）实测过单行布局：`上下文 11%🧊stock… 51.3 tok/s 缓存
  /// 88%`，截断的偏偏是 agent 名——因为整行里只有它套了 Flexible。改成上下
  /// 两行后它独占第一行。
  testWidgets('D-105 窄屏：agent 名完整显示，指标挪到第二行', (tester) async {
    // 393dp 就是小米的真实宽度（1080/440dpi*160）。
    await tester.binding.setSurfaceSize(const Size(393, 873));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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
        agentPreset: 'stock-researcher',
        values: _busyValues());

    final preset = find.text('stock-researcher');
    expect(preset, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: preset, matching: find.byType(RichText)));
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '393dp 上 agent 名必须完整显示，不能被截成 stock…');

    // 结构上确实是两行：第一行上下文占用 + agent，第二行指标 + 详情入口。
    expect(
      find.descendant(of: find.byType(ContextBar), matching: find.byType(Row)),
      findsNWidgets(2),
      reason: '状态条拆成上下两行（第一行上下文/agent，第二行速率/缓存/轮数）',
    );
    expect(find.textContaining('tok/s'), findsOneWidget);
    expect(find.textContaining('缓存'), findsOneWidget);
    expect(find.textContaining('轮'), findsOneWidget);
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
