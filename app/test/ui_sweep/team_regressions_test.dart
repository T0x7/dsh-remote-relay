import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/console/inline_error_card.dart';
import 'package:dsh_remote_app/console/team/team_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/services/app_lifecycle_gate.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_engine_gateway.dart';
import 'ui_inventory.dart';

/// D-094…D-098 —— 「智能体团队」这条路径的真机走查守门（2026-10-11 小米）。
///
/// 真机现场：父会话 `job-weekly-20261011-030055` 有 4 个子代理，team 页
/// 展示全对（标签完整换行、绿点、可继续对话），但**点进去是空白**，而且
/// 顶栏徽标不亮。这四条分别钉住那条链路上的四个断点：
///
/// D-094 子代理会话地址：`(parent, child)` 成对，parent 丢了引擎直接回
///       `subagent/unauthorized`，team 页的唯一动作因此完全不可用。
/// D-095 journal 错误可见性：`MuxStreamError` 过去被 `if (e is
///       EngineRemoteError)` 丢弃，于是 unauthorized 只进日志、界面全白
///       （D-089 在 jobs_pane 上修过一次，这里是同一个洞的另一半）。
/// D-096 徽标计数：AppBar 不听 ChatController，目录随 follow 快照晚到，
///       count 永远停在快照前的 0 ——「这个会话有子代理」的唯一提示不亮。
/// D-097 页脚文案：说「只读输出」，而 continuable 子代理实际给输入框。
/// D-098 工作区失败屏：没有 Scaffold ⇒ 没有 AppBar、没有返回、没有重试。
Widget _host(Widget child, [Locale locale = const Locale('zh')]) => MaterialApp(
      locale: locale,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// The console keeps live timers, so `pumpAndSettle` never returns (D-032).
Future<void> settle(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

MachinesStore _seededStore() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return MachinesStore(
    repo: InMemoryMachinesRepository(),
    seed: [
      MachineEntry(
        id: 'relay-session',
        name: 'test-mini',
        firstPairedMs: now,
        params: SignedUrlParams(
          relayOrigin: Uri.parse('http://127.0.0.1:8080'),
          sessionId: 'relay-session',
          hash: 'h',
          mid: 'm',
          tMs: now,
          expMs: now + 3600 * 1000,
        ),
      ),
    ],
  );
}

void main() {
  group('D-094 · 子代理会话必须带父会话 id', () {
    test('open(子 id, parentSessionId: 父 id) 发出去的地址两半都对', () async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });

      await controller.open(
        'child-uuid',
        parentSessionId: 'parent-job',
        subagentLabel: '基本面周线腿',
        mode: SubagentMode.continuable,
      );

      final follow =
          gateway.calls.where((c) => c.call == 'follow').toList(growable: false);
      expect(follow, hasLength(1));
      final address = follow.single.args as SubagentSessionAddress;
      expect(address.parentSessionId, 'parent-job',
          reason: 'parent 填成 child 自己的 id 时，引擎回 '
              'subagent/unauthorized（真机实测）');
      expect(address.childSessionId, 'child-uuid');
      expect(address.mode, SubagentMode.continuable);
    });

    test('D-099: 后台→前台恢复后重开的 journal 仍带父会话 id', () async {
      final gateway = FakeEngineGateway();
      final gate = AppLifecycleGate();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
        lifecycle: gate,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });

      await controller.open(
        'child-uuid',
        parentSessionId: 'parent-job',
        subagentLabel: '基本面周线腿',
        mode: SubagentMode.continuable,
      );

      // 真机 15:01 现场：App 带着子会话进后台，回前台时 resume 重开 journal
      // ——parent 不在恢复参数里就会被兜底成 child 自己。
      gate.enterBackground();
      await pumpEventQueue();
      expect(controller.suspended, isTrue);

      gate.enterForeground();
      await pumpEventQueue();

      final follows =
          gateway.calls.where((c) => c.call == 'follow').toList(growable: false);
      expect(follows.length, greaterThanOrEqualTo(2), reason: 'resume 重开了 journal');
      final resumed = follows.last.args as SubagentSessionAddress;
      expect(resumed.parentSessionId, 'parent-job',
          reason: '恢复路径丢 parent 时，引擎回 unauthorized，'
              '子会话在回前台后变成打不开的空白页');
      expect(resumed.childSessionId, 'child-uuid');
    });

    test('普通会话仍然走 PlainSessionAddress，不受 parent 参数影响', () async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });

      await controller.open('plain-session', parentSessionId: 'ignored');

      final follow =
          gateway.calls.where((c) => c.call == 'follow').toList(growable: false);
      expect(follow.single.args, isA<PlainSessionAddress>());
    });
  });

  group('D-095 · 对话流错误必须上界面', () {
    testWidgets('MuxStreamError 显示成错误卡片而不是空白页', (tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });

      await controller.open('s-child');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      // 订阅建在 open 里，所以先 pump 再投喂。
      gateway.pushFrameError(const MuxStreamError(
        code: 'subagent/unauthorized',
        message: 'subagent does not belong to the supplied parent',
      ));
      await settle(tester);

      expect(controller.error, isNotNull,
          reason: 'unauthorized 过去只进日志，界面全白 —— 真机点子代理就是这个症状');
      // `subagent/unauthorized` 在错误码表里映射为 subagentReadOnly。
      expect(controller.error!.code, ErrorCode.subagentReadOnly);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '流已经带着错误结束了，不能还停在转圈',
      );
      expect(find.textContaining('subagent does not belong'), findsWidgets);
    });

    testWidgets('D-100: 首帧看门狗超时同样要出错误卡', (tester) async {
      // 真机 15:02 现场：后台恢复后 journal 45s 无首帧，logcat 打了
      // `first-frame deadline hit`，屏幕却一直空白——看门狗只赋了 `_error`，
      // 而 `_error` 没有任何 widget 读（与 D-095 前半同一个洞）。
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      // D-104: 自动重开会装上**新的**首帧看门狗，而 addTearDown 跑在
      // testWidgets 的 pending-timer 断言之后——所以 controller 必须在本
      // 测试体内显式 dispose，gateway 留给 tearDown。
      addTearDown(gateway.dispose);

      await controller.open('never-answers');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '前置：还没超时，页面在等首帧');

      // 推过 45s 闸（FakeAsync 下零成本），真实定时器自然触发——比
      // onFirstFrameDeadlinePassedForTest 更贴近真实，也不会留下孤儿 Timer
      // 触发 testWidgets 的 pending-timer 断言。
      //
      // D-104：超时后有 3s 退避的自动重开，所以停在 46s 这个窗口里断言——
      // 此刻错误卡刚落地，自动重开还没发生。
      await tester.pump(const Duration(seconds: 46));
      await settle(tester);

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '超时后不能再转圈',
      );
      expect(controller.error!.code, ErrorCode.engineTimeout);
      expect(
        find.byType(InlineErrorCard),
        findsWidgets,
        reason: '看门狗超时必须落在气泡流里——否则用户看到的就是'
            '「空白 + 输入框」，没有任何地方解释发生了什么',
      );

      // D-104：那张卡带着「正在重试」的文案，就必须真的会重试一次。
      final followsBefore = gateway.calls
          .where((c) => c.call == 'follow')
          .length;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      final followsAfter = gateway.calls
          .where((c) => c.call == 'follow')
          .length;
      expect(
        followsAfter,
        greaterThan(followsBefore),
        reason: '文案写着「正在重试」就必须真重开一次 journal；'
            '真机（vivo）上网络恢复后这张卡永不消失，用户只能自己去会话'
            '列表重新进入（2026-10-12 实测）',
      );

      controller.dispose();
    });

    /// D-104：自动重开**只能发生一次**。
    ///
    /// 真机（小米 2026-10-12）当场抓到过这个 bug：日志里每 48 秒一次
    /// `first-frame deadline hit → auto-reopening → open journal`，无穷无尽，
    /// 用户永远只看到一个转圈。起因是自动重开也调了 `retry()`，而 `retry()`
    /// 为「用户主动点了就给一次自动兜底」重置了预算——于是每次都把预算花光
    /// 再重置。第一版守门只推进了 4 秒（只够验一次自动重开），所以没抓住。
    testWidgets('D-104: 第二次超时不得再自动重开（预算只花一次）', (tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      await controller.open('never-answers');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));

      // 第一轮：45s 超时 → 3s 退避 → 自动重开一次。
      await tester.pump(const Duration(seconds: 49));
      await settle(tester);
      final afterFirst =
          gateway.calls.where((c) => c.call == 'follow').length;
      expect(afterFirst, greaterThan(1),
          reason: '第一次超时后应自动重开一次');

      // 第二轮：又超时 45s。这一次**不允许**再自动重开——否则就是死循环。
      await tester.pump(const Duration(seconds: 49));
      await settle(tester);
      final afterSecond =
          gateway.calls.where((c) => c.call == 'follow').length;
      expect(
        afterSecond,
        afterFirst,
        reason: '自动重开的预算只花一次：第二次超时必须停下来等用户点重试，'
            '否则每 45s 无限重开，用户永远只看到转圈（小米真机 10:49 实锤）',
      );
      expect(find.byType(InlineErrorCard), findsWidgets,
          reason: '停下来的那一刻必须留一张可见的错误卡 + 重试按钮');

      controller.dispose();
    });

    /// D-104：错误卡必须**可点**。
    ///
    /// 修之前它只有文案：真机上点它毫无反应，而文案还写着「正在重试」——
    /// 一张会喊「正在重试」却不能点的卡片，比没有卡片更让人空等
    /// （vivo 2026-10-12 实测）。
    testWidgets('D-104: 错误卡带可点的重试，点它重开 journal', (tester) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
      )..startEvents();
      addTearDown(gateway.dispose);

      await controller.open('never-answers');
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      await tester.pump(const Duration(seconds: 46));
      await settle(tester);

      // 断言放在超时窗口内：此刻错误卡刚落地，自动重开还没触发。
      final retryButton = find.widgetWithText(TextButton, '重试');
      expect(controller.canRetry, isTrue,
          reason: 'engineTimeout 的 RetryPolicy 是 autoBackoff，值得给用户按钮');
      expect(retryButton, findsOneWidget,
          reason: '错误卡必须带可点的重试出口');

      final followsBefore =
          gateway.calls.where((c) => c.call == 'follow').length;
      await tester.tap(retryButton);
      await tester.pump();
      await settle(tester);
      expect(
        gateway.calls.where((c) => c.call == 'follow').length,
        greaterThan(followsBefore),
        reason: '点重试必须真的重开 journal',
      );

      controller.dispose();
    });
  });

  group('D-096 · 子代理徽标必须随目录亮起', () {
    testWidgets('快照里的 catalog 到达后徽标显示真实计数', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = FakeEngineGateway(sessions: [
        SessionSummary(
          sessionId: 'job-weekly-20261011-030055',
          updatedAt: 1,
          running: false,
          blank: false,
          agentAvailable: true,
        ),
      ]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        ConsolePage(store: _seededStore(), gatewayFactory: (_) => gateway),
      ));
      await settle(tester, steps: 20);

      // 首帧还没有投影：徽标在但没有数字。
      expect(find.byType(Badge), findsWidgets,
          reason: '徽标本身恒在（catalog 为 0 时只是不显示数字）');
      expect(find.text('0'), findsNothing,
          reason: 'count 为 0 时不应显示数字气泡');

      // 目录随 follow 快照晚到——这正是真机上徽标不亮的那一步。
      gateway.pushFrame(sweepSnapshot(
        id: 'job-weekly-20261011-030055',
        events: sweepChatEvents(),
        baseline: {
          'asOfSeq': 10,
          'values': {
            'subagentCatalog': [
              {'mode': 'continuable', 'label': '腿A', 'id': 'c1', 'createdAt': 1},
              {'mode': 'continuable', 'label': '腿B', 'id': 'c2', 'createdAt': 2},
            ],
          },
        },
      ));
      await settle(tester, steps: 20);

      expect(find.text('2'), findsWidgets,
          reason: 'AppBar 不听 ChatController 时 count 永远停在 0，'
              '「这个会话有子代理」的唯一提示就不会亮（真机：4 个子代理、徽标无数字）');
    });
  });

  group('D-097 · team 页脚不得承诺不存在的只读', () {
    testWidgets('页脚描述的是「打开会话」，不是「只读输出」', (tester) async {
      final l10n = await L10n.delegate.load(const Locale('zh'));
      // 真机形状：4 个 continuable 子代理（引擎 170 条 catalog 条目实测全是
      // continuable，没有一条 one-shot）。D-094 修好后点进去确实拿到输入框，
      // 所以页脚再说「只读输出」就是把可写说成只读。
      final baseline = SessionProjectionBaseline(
        asOfSeq: 1,
        values: Projections(
          subagentCatalog: [
            SubagentCatalogEntry(
              id: 'c1',
              createdAt: 1,
              mode: SubagentMode.continuable,
              label: '基本面周线腿：持仓与候选个股的周度价格/技术位/估值分位',
            ),
          ],
        ),
      );
      await tester.pumpWidget(_host(TeamPage(
        parentSessionId: 'job-weekly-20261011-030055',
        projections: baseline,
        l10n: l10n,
        onOpenChild: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('只读输出'), findsNothing);
      expect(find.text(l10n.teamFooter), findsOneWidget);
    });
  });

  group('D-098 · 工作区注册表失败屏不得是死胡同', () {
    testWidgets('失败时仍有 AppBar 标题、返回与重试', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      gateway.raiseWorkspaceError(const MuxStreamError(
        code: 'gateway/internal',
        message: 'workspace follow never answered',
      ));

      final registry = WorkspaceRegistryController(gateway);
      addTearDown(registry.dispose);
      final l10n = await L10n.delegate.load(const Locale('zh'));
      final sessions = ValueNotifier<List<SessionSummary>>(const []);
      addTearDown(sessions.dispose);

      // 真正上屏的形态是**被 push 出来的第二层路由**，所以返回键必须是
      // AppBar 自带的那个，而不是靠系统手势兜底。声明式双页：picker 压在
      // 一个占位页上面，`Navigator.canPop` 因此为 true——与真机的
      // `ConsolePage → push(picker)` 同构，又不依赖 push 的 Future。
      await tester.pumpWidget(_host(Navigator(
        pages: [
          const MaterialPage<void>(child: Scaffold(body: Center(child: Text('console')))),
          MaterialPage<void>(
            key: const ValueKey('picker'),
            child: WorkspacePickerPage(
              registry: registry,
              gateway: gateway,
              sessions: sessions,
              machineName: 'test-mini',
              onOpenSession: (_) {},
            ),
          ),
        ],
        onDidRemovePage: (page) => false,
      )));
      // 错误帧走 stream → errors → controller。**不能**用
      // `await Future.delayed(Duration.zero)` 等它：testWidgets 的 FakeAsync
      // 区里真实定时器永不触发，那一句会把整个测试吊死（实测 150s 超时）。
      // 有界 pump 会推进假时钟，恰好把零延时定时器和微任务一起冲走。
      await settle(tester, steps: 8);
      expect(registry.error, isNotNull);
      expect(find.byType(AppBar), findsOneWidget,
          reason: '没有 Scaffold 就没有 AppBar ⇒ 没有标题、没有返回键，'
              '用户被停在一整屏句子前面（真机截图）');
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget,
          reason: '流已经结束了，重进页面只会拿到同一个死掉的 controller，'
              '必须能从屏幕上重开');
      expect(find.text(l10n.workspacesUnavailable), findsOneWidget);
    });

    test('retry 重新开流并清掉错误', () async {
      final gateway = FakeEngineGateway();
      gateway.raiseWorkspaceError(const MuxStreamError(
        code: 'gateway/internal',
        message: 'boom',
      ));
      final registry = WorkspaceRegistryController(gateway);
      addTearDown(registry.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(registry.error, isNotNull);

      await registry.retry();
      expect(registry.error, isNull);
      expect(gateway.calls.where((c) => c.call == 'workspace/follow'),
          hasLength(2),
          reason: 'retry 必须真的重开订阅，而不是只把错误清掉');
    });
  });

  group('D-101 · 停留在轨迹页时账本重建必须立刻上屏', () {
    testWidgets('resume 重建 ledger 后，轨迹页不再需要切走再切回', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = FakeEngineGateway(sessions: [
        SessionSummary(
          sessionId: 'job-weekly',
          updatedAt: 1,
          running: false,
          blank: false,
          agentAvailable: true,
        ),
      ]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        ConsolePage(store: _seededStore(), gatewayFactory: (_) => gateway),
      ));
      await settle(tester, steps: 16);

      // 停在轨迹页：此刻没有任何帧，应是空态。
      await tester.tap(find.text('轨迹'));
      await settle(tester, steps: 8);
      expect(find.text('这个会话还没有轨迹记录'), findsOneWidget,
          reason: '前置：无记录时空态成立');

      // 快照到达（resume 场景里这就是重建后的账本）。controller 会
      // notifyListeners；轨迹页必须因此重建，而不是等用户切 tab。
      gateway.pushFrame(sweepSnapshot(
        id: 'job-weekly',
        events: sweepChatEvents(),
      ));
      await settle(tester, steps: 16);

      expect(find.text('这个会话还没有轨迹记录'), findsNothing,
          reason: '真机 15:20：快照到了轨迹页却停在空态，切走再切回才恢复');
      expect(find.textContaining('mcp__demo__lookup'), findsWidgets,
          reason: '快照里的工具调用必须直接出现在轨迹页上');
    });
  });

  group('工作区新建会话 · 端到端（combined 方案的接线）', () {
    testWidgets('ConsolePage 新会话：registry 快照进面板，choice 传给 createSession',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = FakeEngineGateway(sessions: [
        SessionSummary(
          sessionId: 'job-weekly',
          updatedAt: 1,
          running: false,
          blank: false,
          agentAvailable: true,
        ),
      ]);
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(
        ConsolePage(store: _seededStore(), gatewayFactory: (_) => gateway),
      ));
      await settle(tester, steps: 16);

      // 顶栏「新会话」→ 预设面板。registry 的默认基线带 w-jobs/w-workspace
      // 两个工作区，面板应显示工作区段。
      await tester.tap(find.byIcon(Icons.add_comment_outlined));
      await settle(tester, steps: 10);
      expect(find.text('在哪个工作区打开'), findsOneWidget,
          reason: 'ConsolePage 必须把 registry 快照交给面板——这是接线的关键一跳');

      // 选 w-jobs + Alpha Radar。
      await tester.tap(find.text('定时任务'));
      await settle(tester, steps: 4);
      await tester.tap(find.text('Alpha Radar'));
      await settle(tester, steps: 8);

      final creates = gateway.calls
          .where((c) => c.call == 'createSession')
          .toList(growable: false);
      expect(creates, hasLength(1));
      final args = creates.single.args as Map<String, dynamic>;
      expect(args['workspaceId'], 'w-jobs',
          reason: '面板选的工作区必须落到 session/create 的 wire 参数上');
      expect(args['agentPreset'], 'alpha-radar');
      expect(args['cwd'], isNull, reason: 'workspaceId 与 cwd 互斥（引擎契约）');
    });
  });
}
