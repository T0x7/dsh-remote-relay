import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_ledger.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-042 轨迹页：记录表、检查器、向前分页、区间筛选。
///
/// 这几条锁的是**用户能看见的行为**，不是内部实现：
///
/// - 没有更早历史时不给出「加载更早」的死按钮；
/// - 有的话点一下真的调 `session/page` 并把记录插到最前面；
/// - 补页失败要说出失败，不能静默；
/// - 选中记录后检查器给出**原始载荷**，这是轨迹区别于对话的唯一理由；
/// - 区间筛选按闭区间相交判定，计时未知的记录被排除。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent ev(int seq, String type, Map<String, dynamic> data,
        {int? time}) =>
    SessionWireEvent(
      type: type,
      seq: seq,
      time: time ?? 1_700_000_000_000 + seq * 1000,
      data: data,
    );

/// 一段最小的可显示事件流：一个轮次 + 一条用户消息 + 一次工具调用。
List<SessionWireEvent> _session() => [
      ev(1, 'turn/start', {'turn': 1}),
      ev(2, 'user/message', {
        'turn': 1,
        'content': [
          {'type': 'text', 'text': '帮我看下这个仓库'}
        ],
      }),
      ev(3, 'tool/call', {
        'turn': 1,
        'callId': 'c1',
        'name': 'read_file',
        'arguments': {'path': 'README.md'},
      }),
      ev(4, 'tool/result', {
        'turn': 1,
        'callId': 'c1',
        'message': [
          {'type': 'text', 'text': '# dsh-remote-relay'}
        ],
      }),
    ];

Future<void> settle(WidgetTester tester, {int steps = 14}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  late FakeEngineGateway gateway;
  late TrajectoryLedger ledger;

  setUp(() {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    ledger = TrajectoryLedger();
  });

  /// 装一段会话并挂上轨迹页。
  Future<void> mount(
    WidgetTester tester, {
    List<SessionWireEvent>? events,
    bool hasMore = false,
    String? subagentLabel,
    String? parentSessionId,
  }) async {
    final window = events ?? _session();
    ledger.reset(
      records: window,
      cursor: window.last.seq,
      hasMore: hasMore,
    );
    await tester.pumpWidget(_host(TrajectoryPane(
      ledger: ledger,
      gateway: gateway,
      sessionId: 'session-x',
      subagentLabel: subagentLabel,
      parentSessionId: parentSessionId,
    )));
    await settle(tester);
  }

  group('记录表（P0）', () {
    testWidgets('轮次分组 + 类型/内容两列都画出来', (tester) async {
      await mount(tester);

      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('user/message'), findsOneWidget);
      expect(find.text('帮我看下这个仓库'), findsOneWidget);
      expect(find.text('tool/call'), findsOneWidget);
      expect(find.text('read_file'), findsOneWidget);
    });

    testWidgets('工具配对后显示耗时', (tester) async {
      await mount(tester);
      // call(seq3) → result(seq4) 相隔 1000ms
      expect(find.text('1.0s'), findsWidgets);
    });

    testWidgets('没打开会话时说清楚是缺会话，不是空轨迹', (tester) async {
      await tester.pumpWidget(_host(TrajectoryPane(
        ledger: ledger,
        gateway: gateway,
        sessionId: null,
        subagentLabel: null,
      )));
      await settle(tester);
      expect(find.textContaining('先打开一个会话'), findsOneWidget);
    });
  });

  group('检查器（P0）', () {
    testWidgets('点记录打开原始载荷，参数逐字可见', (tester) async {
      await mount(tester);

      await tester.tap(find.text('read_file'));
      await settle(tester);

      expect(find.text('载荷'), findsOneWidget);
      // 机器载荷是轨迹的核心价值：tool/call 的 arguments 必须原样可读。
      expect(find.textContaining('README.md'), findsWidgets);
      expect(find.textContaining('read_file'), findsWidgets);
    });

    testWidgets('检查器能退回记录表', (tester) async {
      await mount(tester);
      await tester.tap(find.text('read_file'));
      await settle(tester);

      await tester.tap(find.text('记录'));
      await settle(tester);
      expect(find.text('帮我看下这个仓库'), findsOneWidget,
          reason: '返回后记录表要还在');
    });
  });

  group('向前分页（P1）', () {
    testWidgets('引擎说没有更早历史时，不给死按钮', (tester) async {
      await mount(tester, hasMore: false);
      expect(find.text('加载更早的记录'), findsNothing);
    });

    testWidgets('有更早历史时点一下真的调 session/page 并插到最前', (tester) async {
      gateway.pageResults.add((
        records: [
          FollowEvent(ev(90, 'user/message', {
            'turn': 0,
            'content': [
              {'type': 'text', 'text': '很久以前说过的一句话'}
            ],
          })),
        ],
        hasMore: false,
      ));
      await mount(tester, hasMore: true);

      expect(find.text('加载更早的记录'), findsOneWidget);
      await tester.tap(find.text('加载更早的记录'));
      await settle(tester);

      expect(gateway.calls.where((c) => c.call == 'page'), hasLength(1));
      expect(find.text('很久以前说过的一句话'), findsOneWidget);
      expect(ledger.projection.records.first.seq, 90,
          reason: '补页必须插到最前面，顺序错了因果就错了');
      expect(find.text('加载更早的记录'), findsNothing,
          reason: '引擎说 hasMore=false 就该把按钮收掉');
    });

    testWidgets('补页失败要说出失败，不能静默', (tester) async {
      gateway.pageFailure = 'gateway/internal';
      await mount(tester, hasMore: true);

      await tester.tap(find.text('加载更早的记录'));
      await settle(tester);

      expect(find.textContaining('加载更早的记录失败'), findsOneWidget);
    });
  });

  // D-112：分页同样要在 wire 上寻址，而子代理是**成对**的。这一组钉的是 D-094
  // 那一族缺陷在轨迹侧的残留：过去这里把 sessionId 同时填进父子两半，而子代理
  // 会话里那个 sessionId 就是 child 自己的 id，于是引擎每次回
  // `subagent/unauthorized`——「更早」永远补不上，且界面一声不吭。
  group('D-112 · 补页地址与对话侧同一条规则', () {
    testWidgets('子代理补页走成对地址（父半边是父会话，不是 child）',
        (tester) async {
      gateway.pageResults.add((
        records: [
          FollowEvent(ev(90, 'user/message', {
            'turn': 0,
            'content': [
              {'type': 'text', 'text': '很久以前说过的一句话'}
            ],
          })),
        ],
        hasMore: false,
      ));
      await mount(
        tester,
        hasMore: true,
        subagentLabel: '基本面周线腿',
        parentSessionId: 'parent-job',
      );

      await tester.tap(find.text('加载更早的记录'));
      await settle(tester);

      expect(gateway.pagedAddresses, hasLength(1));
      final address = gateway.pagedAddresses.single;
      expect(address, isA<SubagentSessionAddress>(),
          reason: '子代理补页不能退化成普通地址');
      expect((address as SubagentSessionAddress).parentSessionId, 'parent-job');
      expect(address.childSessionId, 'session-x');
      expect(gateway.rejectedAddresses, isEmpty);
      expect(find.text('很久以前说过的一句话'), findsOneWidget);
    });

    testWidgets('普通会话补页仍是普通地址（别把规则改过头）', (tester) async {
      await mount(tester, hasMore: true);

      await tester.tap(find.text('加载更早的记录'));
      await settle(tester);

      expect(gateway.pagedAddresses, hasLength(1));
      expect(gateway.pagedAddresses.single, isA<PlainSessionAddress>());
      expect(
        (gateway.pagedAddresses.single as PlainSessionAddress).sessionId,
        'session-x',
      );
      expect(gateway.rejectedAddresses, isEmpty);
    });

    testWidgets('子代理缺父 id：不发补页请求，并说清楚为什么', (tester) async {
      // 这一格正是旧代码的产物：只有 subagentLabel，父子两半都拿 session-x 填。
      await mount(tester, hasMore: true, subagentLabel: '基本面周线腿');

      await tester.tap(find.text('加载更早的记录'));
      await settle(tester);

      expect(gateway.pagedAddresses, isEmpty,
          reason: 'parent 缺失时那个地址只会被引擎拒绝，不该发出去');
      expect(find.textContaining('subagent/parent-missing'), findsOneWidget,
          reason: '不发请求可以，但必须告诉用户为什么——否则又是一个死按钮');
    });
  });

  group('时间概览（P2）', () {
    testWidgets('一条都没有可画耗时时说明原因，而不是画一条空图', (tester) async {
      // 只有用户消息：它没有 startedAt，按 dsh 口径不投影。
      await mount(tester, events: [
        ev(1, 'turn/start', {'turn': 1}),
        ev(2, 'user/message', {
          'turn': 1,
          'content': [
            {'type': 'text', 'text': 'x'}
          ],
        }),
      ]);
      expect(find.textContaining('没有可画的耗时'), findsOneWidget);
    });

    testWidgets('有耗时时画出三条轨道图例', (tester) async {
      await mount(tester);
      expect(find.text('系统'), findsOneWidget);
      expect(find.text('消息'), findsOneWidget);
      expect(find.text('工具'), findsOneWidget);
    });
  });
}
