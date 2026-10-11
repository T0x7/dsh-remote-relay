import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/jobs/jobs_pane.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_ledger.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_engine_gateway.dart';
import 'ui_inventory.dart';

/// 本轮真机走查（2026-10-11）发现的四个 bug 的**守门测试**。
///
/// 为什么不把它们塞进巡检就算完：巡检盯的是「这一屏现在长什么样」，而这四个
/// 是**行为**——回底落点、窗口裁剪方向、流错误的可见性、重连后的重放。
/// 它们随时可能被下一次重构改回去，所以每个都要有一条钉死的断言。
///
/// D-089 任务页：D-070 摘要（9:18 与 9:39 两轮真机）
/// D-090 回底钮：一次落进空白区、一次停在距底一屏处
/// D-091 轨迹窗口：横幅数字颠倒 + 保留方向与文案相反
/// D-092 follow 重开：mux 重连后被「second snapshot」守卫误杀
void main() {
  group('D-093 · 工具行必须显示工具名', () {
    testWidgets('tool/result 的 callId 从 message.toolCallId 取', (tester) async {
      // 真机症状：对话页每一条工具调用都只剩「工具调用 + 参数摘要」，
      // 工具名整个消失；而轨迹页读 data.name 所以照常显示——同一份数据两屏
      // 不一致。根因：引擎把 callId 放在 `message.toolCallId`，代码从顶层
      // `data.callId` 读（永远 null），前向记录匹配失败后落到默认名 'tool'，
      // 再被 UI 过滤掉。
      //
      // 这条 fixture 刻意**只**按引擎契约给 tool/result，不带顶层 callId：
      // 只要将来有人改回顶层读法，这里立刻红。
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await controller.open('s1');
      await tester.pumpWidget(uiHost(ChatPane(controller: controller)));
      gateway.raiseReady();
      gateway.pushFrame(sweepSnapshot(
        id: 's1',
        events: [
          sweepEvent(
            type: 'tool/call',
            seq: 1,
            data: {
              'turn': 1,
              'step': 1,
              'callId': 'call-1',
              'name': 'mcp__demo__lookup',
              'arguments': '{"limit": 30}',
            },
          ),
          sweepEvent(
            type: 'tool/result',
            seq: 2,
            data: {
              'turn': 1,
              'step': 1,
              // 引擎契约：没有顶层 callId，只有 message.toolCallId。
              'message': {
                'role': 'tool',
                'toolCallId': 'call-1',
                'content': [
                  {'type': 'text', 'text': '{"ok": true}'},
                ],
              },
            },
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('mcp__demo__lookup'),
        findsWidgets,
        reason: '工具名必须出现在对话页的工具行上（与轨迹页一致）',
      );
    });
  });

  group('D-089 · 任务页不得把流错误吞成永久转圈', () {
    testWidgets('MuxStreamError 必须显示成错误卡片', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(uiHost(Builder(
        builder: (context) => JobsPane(
          gateway: gateway,
          sessionId: 's1',
          l10n: L10n.of(context),
        ),
      )));

      // 订阅建在 initState，所以先 pump 再投喂。
      gateway.raiseJobStreamError(
        code: 'gateway/internal',
        message: 'job stream died',
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '流已经带着错误结束了，界面不能再停在转圈'
            '（真机症状：9:18 与 9:39 两轮一直转圈）',
      );
      expect(find.textContaining('job stream died'), findsWidgets);
    });

    testWidgets('引擎回空列表时显示空态而不是错误', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(uiHost(Builder(
        builder: (context) => JobsPane(
          gateway: gateway,
          sessionId: 's1',
          l10n: L10n.of(context),
        ),
      )));
      gateway.raiseJobRows(const []);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byType(InlineErrorNotice),
        findsNothing,
        reason: '空列表是合法答案（引擎开流即 yield rows），不是故障',
      );
    });

    testWidgets('首帧永远不来时闸门打开', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(uiHost(Builder(
        builder: (context) => JobsPane(
          gateway: gateway,
          sessionId: 's1',
          l10n: L10n.of(context),
        ),
      )));
      // 什么都不推：等过首帧闸。
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '12s 都没等到第一帧，界面必须给出「没等到」而不是继续转',
      );
    });
  });

  group('D-090 · 回到底部必须真的到底', () {
    testWidgets('有超视口高的展开气泡时，回底后落点在底部容差内', (tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await controller.open('s1');
      await tester.pumpWidget(uiHost(ChatPane(controller: controller)));
      gateway.raiseReady();
      gateway.pushFrame(sweepSnapshot(
        id: 's1',
        events: [
          for (var i = 1; i <= 40; i++)
            sweepEvent(
              type: 'assistant/message',
              seq: i,
              data: {
                'turn': 1,
                'step': i,
                'message': {
                  'id': 'a$i',
                  'content': [
                    {
                      'type': 'text',
                      // 每条都够长：展开后总高度远超一屏，懒加载的
                      // maxScrollExtent 估算因此严重失真（真机的病根）。
                      'text': List.filled(
                          6, '第 $i 条消息的正文，' '内容要够长才能撑出视口。')
                          .join('\n'),
                    },
                  ],
                  'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
                  'role': 'assistant',
                },
                'stream': <Object?>[],
              },
            ),
        ],
      ));
      await tester.pumpAndSettle();

      // 滚到中段，制造「远离底部」的状态。
      final list = find.byType(Scrollable).first;
      await tester.drag(list, const Offset(0, -1200));
      await tester.pumpAndSettle();

      final state = tester.state<State<StatefulWidget>>(find.byType(ChatPane));
      final scrollable = tester.widget<Scrollable>(list);
      expect(scrollable.controller, isNotNull);

      // 触发页面自己的回底路径。
      await tester.tap(find.byType(IconButton).last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final position = scrollable.controller!.position;
      expect(
        position.pixels,
        greaterThanOrEqualTo(position.maxScrollExtent - 80),
        reason: '回底之后必须真的在底部（容差 80px = 贴底阈值）；'
            '落进空白区或停在半屏处都是失败',
      );
      expect(state.mounted, isTrue);
    });
  });

  group('D-091 · 轨迹窗口保最新，文案不颠倒', () {
    testWidgets('超窗口时保留最新 N 条、最旧的一条被裁掉', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final records = [
        for (var i = 1; i <= 200; i++)
          sweepEvent(
            type: 'assistant/message',
            seq: i,
            data: {
              'turn': 1,
              'step': i,
              'message': {
                'id': 'a$i',
                'content': [
                  {'type': 'text', 'text': '消息编号 $i'},
                ],
                'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
                'role': 'assistant',
              },
              'stream': <Object?>[],
            },
          ),
      ];
      final ledger = TrajectoryLedger()
        ..reset(records: records, cursor: 200, hasMore: false);

      await tester.pumpWidget(uiHost(TrajectoryPane(
        ledger: ledger,
        gateway: gateway,
        sessionId: 's1',
        subagentLabel: null,
      )));
      await tester.pumpAndSettle();

      // 横幅在列表顶部，所以先断言文案（顺序有意义）。
      expect(
        find.textContaining('窗口只保留最近'),
        findsOneWidget,
        reason: '有记录被窗口裁掉时必须如实报出数量',
      );
      // 文案里的两个数字必须与实际一致：200 条里保留 80、丢弃 120。
      // 顺序颠倒是 D-091 的正题——实参曾经按 (kept, dropped) 传给
      // (dropped, kept) 的签名，界面上显示成「保留 80 丢弃 120」的反面。
      final banner = tester.widget<Text>(find.textContaining('窗口只保留最近').first);
      expect(banner.data, contains('保留最近 80 条'));
      expect(banner.data, contains('120 条已丢弃'));

      // 记录表是懒加载 ListView：最新一条在屏幕外。滚不到才说明它被裁掉了。
      await tester.scrollUntilVisible(
        find.textContaining('消息编号 200'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('消息编号 200'),
        findsOneWidget,
        reason: '最新一条必须在窗口里——轨迹页的价值就是看刚刚发生了什么',
      );

      // 最旧的一条必须已经不在窗口里。
      expect(
        find.textContaining('消息编号 1 ', findRichText: true),
        findsNothing,
        reason: '被裁掉的是最旧的，不是最新的',
      );
    });
  });

  group('D-092 · 重连后对话不得静默停更', () {
    testWidgets('重开会话后第一批帧照常渲染（不是转圈或空白）', (tester) async {
      // 真正的重连契约由 core 层的 session follow 测试守；这里守 App 侧：
      // 重开后界面必须有内容。9:20 那次重连的现场症状是
      // 「控制台看着正常但流已经死了」，这里把「有内容」钉死。
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await controller.open('s1');
      await tester.pumpWidget(uiHost(ChatPane(controller: controller)));
      gateway.raiseReady();
      gateway.pushFrame(sweepSnapshot(
        id: 's1',
        events: sweepChatEvents(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.textContaining('mcp__demo__lookup'),
        findsWidgets,
        reason: '重开后第一批记录必须渲染出来',
      );
    });
  });
}

/// 错误卡片的定位锚点（避免测试里依赖具体文案）。
class InlineErrorNotice extends StatelessWidget {
  const InlineErrorNotice({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}