import 'dart:async';

import 'package:dsh_remote_app/console/agent_preset_sheet.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/jobs/jobs_pane.dart';
import 'package:dsh_remote_app/console/team/team_page.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_ledger.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_pane.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/logging/diagnostics_page.dart';
import 'package:dsh_remote_app/settings/about_page.dart';
import 'package:dsh_remote_app/settings/language_page.dart';
import 'package:dsh_remote_app/settings/locale_store.dart';
import 'package:dsh_remote_app/settings/pins_page.dart';
import 'package:dsh_remote_app/settings/settings_page.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_engine_gateway.dart';

/// 一个界面状态。
///
/// 「界面」不是 Activity，也不是 tab —— 是**一屏上所有分叉的笛卡尔积**：
/// 空 / 有数据 / 错误 / 长文本，外加该屏上每个可展开的子表面（工具行、
/// 思考块、详情、筛选态…）。2026-10-11 那轮真机走查漏掉「任务页永久
/// 转圈」和「轨迹横幅数字颠倒」，正是因为它们不在任何既有断言里——
///
/// 没人把它们列进过清单。
enum UiState {
  /// 空态（列表无数据 / 无会话）。
  empty,

  /// 有数据的正常态。
  populated,

  /// 长文本态（触发展开 / 折叠 / 换行）。
  longText,
}

/// 一个可交互子表面的探针。
///
/// `act` 点它，`expectAfter` 断言内容真的出来了，`fold` 再收回去——缺了
/// `fold` 的探针只能证明「点得开」，证不了「关得掉」（2026-10-11 的思考
/// chip 就是这么双向验的，`_unfoldedSeqs` / `_thinkingPinned` 都是这一类
/// 「活过列表重建」的状态）。
class UiProbe {
  const UiProbe({
    required this.name,
    required this.act,
    this.foldAct,
    this.expectAfter = const [],
    this.fold,
  });

  final String name;
  final Future<void> Function(WidgetTester tester) act;

  /// 收回去时点的目标。
  ///
  /// 默认复用 [act]，适用于**对称**控件（工具行：展开前后按钮都是同一个）。
  /// 「展开全文 → 收起」这类**非对称**控件必须显式给：展开后按钮文案变成
  /// 「收起」，拿同一个 finder 再点一次只会撞上空 finder（Bad state: No element），
  /// 失败原因还长得像 App 有 bug——其实是探针自己写错了。
  final Future<void> Function(WidgetTester tester)? foldAct;

  /// 点开之后必须出现在树里的东西（至少一个命中）。
  final List<String> expectAfter;

  /// 点回去之后必须消失的东西；null 表示不测回收。
  final List<String>? fold;
}


/// 一次巡检用例内的可变槽位。
///
/// 用例之间**不能**靠文件级变量传状态：flutter_test 跑在同一个 isolate 里，
/// 上一条用例留下的 gateway 会让下一条的「空态」悄悄变成「有数据态」——
/// 而空态恰恰是巡检最该盯住、也最容易被污染的面。
class SweepKit {
  /// 巡检宿主里的 [BuildContext]。弹层类界面（agent 预设面板）需要在
  /// 首帧之后用它调 `showModalBottomSheet`，而那时已经没有 context 参数了。
  BuildContext? hostContext;
  FakeEngineGateway? gateway;
  FakeEngineGateway? chatGateway;
  ChatController? chat;
  TrajectoryLedger? ledger;
  List<SessionWireEvent> events = const [];
}

/// 一个界面 + 它的状态 + 子表面探针。
///
/// 三段式构造是**逼出来的**，不是设计洁癖：
/// - [prepare] 造引擎替身与 controller（必须在 testWidgets 体内，落在
///   真异步区的 controller 收不到 pumpAndSettle 推进的时钟）；
/// - [build] 只负责把 controller 接到界面上——它拿得到 `BuildContext`，
///   所以 `L10n.of` 这类「要先有一个宿主」的东西不用各界面自己绕；
/// - [afterFirstPump] 处理**订阅建立之后**才能发生的事（往 broadcast
///   StreamController 推帧、答 RPC）。少了这一段，界面永远停在空态——而
///   「空态」恰好是巡检最容易误判成「通过」的地方。
class UiSurface {
  const UiSurface({
    required this.id,
    required this.title,
    required this.group,
    required this.build,
    this.state = UiState.populated,
    this.prepare,
    this.afterFirstPump,
    this.openSheet,
    this.probes = const [],
    this.requiredCopy = const [],
  });

  final String id;
  final String title;

  /// 归属分组，只影响报告可读性：控制台 / 设置 / 宿主。
  final String group;
  final UiState state;

  final Future<void> Function(WidgetTester tester, SweepKit kit)? prepare;
  final Widget Function(BuildContext context, SweepKit kit) build;
  final Future<void> Function(WidgetTester tester, SweepKit kit)? afterFirstPump;

  /// 弹层类界面的打开动作，在首帧之后调用。
  ///
  /// `showModalBottomSheet` 这类界面没法靠 [build] 返回一个 widget 来「呈现」
  /// ——它需要宿主 context 并在路由里推一层。所以单列一个钩子，否则这类界面
  /// 会被清单静默漏掉（agent 预设面板就是这么漏的：它是 `+` 号背后的弹层，
  /// 不在任何 tab 的首屏上，走查时极易当成「不存在」）。
  final Future<void> Function(BuildContext context, SweepKit kit)? openSheet;

  final List<UiProbe> probes;

  /// 该状态必须显示的文案（漏一条 = 那一行被布局挤没了）。
  final List<String> requiredCopy;
}

/// 巡检宿主：把裸 widget 包进带本地化与主题的外壳。
///
/// 所有巡检面共用它——外壳不一致时，「界面渲染异常」和「宿主没配好」根本
/// 分不开（i18n 的 zh/en 摇摆就是这么飘出来的）。
Widget uiHost(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// 内存 secure storage：巡检不写盘，也不碰平台通道。
class SweepStorage extends FlutterSecureStorage {
  SweepStorage([Map<String?, String>? seed]) : map = seed ?? <String?, String>{};

  final Map<String?, String> map;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      map[key];

  @override
  Future<void> write({
    required String key,
    String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    map[key] = value ?? '';
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    map.remove(key);
  }
}

// ───────────────────────────── fixtures ─────────────────────────────

SessionWireEvent sweepEvent({
  required String type,
  required int seq,
  Map<String, dynamic>? data,
}) =>
    SessionWireEvent(
      type: type,
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: data ?? const {},
    );

/// 一段**结构真实**的会话：用户消息 → 助手消息（含 reasoning 块）→
/// 工具调用 → 工具结果。工具行、思考 chip、展开全文三种子表面都靠它。
List<SessionWireEvent> sweepChatEvents({bool longText = false}) {
  final filler = List.generate(
    longText ? 40 : 1,
    (i) => '第 $i 段：这是一份用于压测排版的分析正文。',
  ).join('\n\n');
  final reasoning =
      '先想后查：这条消息要回答的核心问题是什么？需要哪些证据？' *
          (longText ? 12 : 1);
  return [
    sweepEvent(
      type: 'user/message',
      seq: 1,
      data: {
        'id': 'm1',
        'content': [
          {
            'type': 'text',
            'text': longText ? '请给我一份足够详细的分析。' : '看一下进展。',
          },
        ],
        'source': {'kind': 'user'},
        'role': 'user',
      },
    ),
    sweepEvent(
      type: 'assistant/message',
      seq: 2,
      data: {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'a1',
          'content': [
            // 字段名是 `text`：引擎的 ReasoningBlock 就是
            // `{type:'reasoning', text}`（llm/lib/types/types.d.ts:51），
            // 不是 `{type:'reasoning', reasoning}`。写错字段名的话气泡照常
            // 渲染，只是「已思考」chip 永远不出现——一个假绿的 fixture。
            {'type': 'reasoning', 'text': reasoning},
            {'type': 'text', 'text': filler},
          ],
          'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
          'role': 'assistant',
        },
        'stream': <Object?>[],
      },
    ),
    sweepEvent(
      type: 'tool/call',
      seq: 3,
      data: {
        'turn': 1,
        'step': 2,
        'callId': 'call-1',
        'name': 'mcp__demo__lookup',
        'arguments': '{}',
      },
    ),
    sweepEvent(
      type: 'tool/result',
      seq: 4,
      data: {
        'turn': 1,
        'step': 2,
        'callId': 'call-1',
        // 结果走 `message` 信封（role/toolCallId/content），不是裸 result：
        // 展开后要显示的就是这段 text，写错键位的话工具行点开是空的。
        'message': {
          'role': 'tool',
          'toolCallId': 'call-1',
          'content': [
            {'type': 'text', 'text': '{"ok": true, "data": {"hit": 1}}'},
          ],
        },
      },
    ),
  ];
}

/// 一份 FollowSnapshot。
///
/// 注意类型：跟随时走的是 [FollowSnapshot]（不是裸 [SessionWireEvent]）——
/// snapshot 是 follow 契约的第一帧，类型不同就意味着重放/基线校验会走另一
/// 条路。这也是为什么「构造 fixture 时顺手复制一��事件形状」是个坑。
FollowSnapshot sweepSnapshot({
  required String id,
  Map<String, dynamic>? baseline,
  List<SessionWireEvent> events = const [],
}) =>
    FollowSnapshot(
      header: SessionHeader(
        version: 4,
        id: id,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isSeeded: false,
      ),
      cursor: events.isEmpty ? 0 : events.last.seq,
      records: events.map(FollowEvent.new).toList(growable: false),
      hasMore: false,
      projections: baseline == null
          ? const SessionProjectionBaseline(asOfSeq: 0, values: Projections())
          : SessionProjectionBaseline.fromJson(baseline),
    );

// ───────────────────────────── 界面清单 ─────────────────────────────

/// **新增界面必须登记在这里。**
///
/// 这是本套巡检唯一的覆盖面来源：没进清单的界面不会被检查，而「以为已经
/// 检查过」正是上一轮漏检的成因——真机走查覆盖的是我当天想到的面，不是
/// 仓库里存在的面。
List<UiSurface> buildUiInventory() => [
      // ───────── 控制台 · 对话 ─────────
      UiSurface(
        id: 'console.chat.empty',
        title: '对话 · 无会话',
        group: '控制台',
        state: UiState.empty,
        prepare: (tester, kit) async {
          final gateway = FakeEngineGateway();
          final controller = ChatController(
            gateway: gateway,
            eventsRefreshInterval: Duration.zero,
          );
          addTearDown(() async {
            controller.dispose();
            await gateway.dispose();
          });
          kit.chat = controller;
        },
        build: (ctx, kit) => ChatPane(controller: kit.chat!),
      ),
      UiSurface(
        id: 'console.chat.populated',
        title: '对话 · 有数据',
        group: '控制台',
        prepare: (tester, kit) => _prepareChat(tester, kit, events: sweepChatEvents()),
        build: (ctx, kit) => _chatPane(ctx, kit),
        afterFirstPump: (tester, kit) => _feedChat(tester, kit),
        probes: [
          UiProbe(
            name: '工具行展开 → 收起',
            act: (tester) => sweepTapText(tester, 'mcp__demo__lookup'),
            expectAfter: ['运行结果'],
            fold: const ['运行结果'],
          ),
          UiProbe(
            name: '思考块回看展开',
            act: (tester) => sweepTapText(tester, '已思考'),
          ),
        ],
      ),
      UiSurface(
        id: 'console.chat.longText',
        title: '对话 · 长文案',
        group: '控制台',
        state: UiState.longText,
        prepare: (tester, kit) => _prepareChat(tester, kit, events: sweepChatEvents(longText: true)),
        build: (ctx, kit) => _chatPane(ctx, kit),
        afterFirstPump: (tester, kit) => _feedChat(tester, kit),
        probes: [
          UiProbe(
            name: '展开全文 → 收起',
            act: (tester) => sweepTapText(tester, '展开全文'),
            foldAct: (tester) => sweepTapText(tester, '收起'),
            expectAfter: ['收起'],
            fold: const ['收起'],
          ),
        ],
      ),

      // ───────── 控制台 · 任务 ─────────
      UiSurface(
        id: 'console.jobs.empty',
        title: '任务 · 空态（引擎回空列表）',
        group: '控制台',
        state: UiState.empty,
        prepare: (tester, kit) async => kit.gateway = _newJobsGateway(tester),
        build: (ctx, kit) => _jobsPane(ctx, kit),
        afterFirstPump: (tester, kit) async {
          // 引擎实证：job/list 开流即回 rows（空数组也是合法答案）。
          kit.gateway!.raiseJobRows(const []);
          await tester.pumpAndSettle();
        },
      ),
      UiSurface(
        id: 'console.jobs.populated',
        title: '任务 · 四种卡片状态',
        group: '控制台',
        prepare: (tester, kit) async => kit.gateway = _newJobsGateway(tester),
        build: (ctx, kit) => _jobsPane(ctx, kit),
        afterFirstPump: (tester, kit) async {
          kit.gateway!.raiseFullJobRows();
          await tester.pumpAndSettle();
        },
        probes: const [
          UiProbe(
            name: '运行中任务显示进度且可结束',
            act: _idle,
            expectAfter: ['3/10 步'],
          ),
        ],
      ),
      UiSurface(
        id: 'console.jobs.failed',
        title: '任务 · 流失败必须有卡片（不许永久转圈）',
        group: '控制台',
        prepare: (tester, kit) async => kit.gateway = _newJobsGateway(tester),
        build: (ctx, kit) => _jobsPane(ctx, kit),
        afterFirstPump: (tester, kit) async {
          // 回归 D-089：这条通道曾经完全不可达，MuxStreamError 被静默吞掉，
          // 任何失败都长成同一个转圈（2026-10-11 真机 9:18/9:39 两轮实证）。
          kit.gateway!.raiseJobStreamError();
          await tester.pumpAndSettle();
        },
      ),

      // ───────── 控制台 · 轨迹 ─────────
      UiSurface(
        id: 'console.trajectory',
        title: '轨迹 · 记录表与详情',
        group: '控制台',
        prepare: (tester, kit) async {
          final gateway = FakeEngineGateway();
          addTearDown(gateway.dispose);
          kit.gateway = gateway;
          kit.ledger = TrajectoryLedger()
            ..reset(records: sweepChatEvents(), cursor: 4, hasMore: false);
        },
        build: (ctx, kit) => TrajectoryPane(
          ledger: kit.ledger!,
          gateway: kit.gateway!,
          sessionId: 'sweep-session',
          subagentLabel: null,
        ),
        probes: [
          UiProbe(
            name: '点开记录看原始载荷',
            act: (tester) => sweepTapText(tester, 'mcp__demo__lookup'),
            expectAfter: ['载荷'],
          ),
        ],
      ),

      // ───── Console 附属：弹层与子页（不在任何 tab 的首屏上）─────
      //
      // 这两个界面最容易被漏检：agent 预设面板藏在顶栏 `+` 背后，team 页
      // 藏在「成员」图标背后——真机走查按 tab 走一遍的话根本不会碰到它们。
      // 清单必须登记它们，否则「巡检覆盖了所有界面」这句话是假的。
      UiSurface(
        id: 'console.agentPresetSheet',
        title: 'agent 预设面板（+ 号弹层）',
        group: 'Console 附属',
        prepare: (tester, kit) async => kit.gateway = _newGateway(tester),
        build: (ctx, kit) => const SizedBox.shrink(),
        // 刻意**不** await 这个 Future：它的返回值是「用户选完之后的结果」，
        // await 它等于等用户点一下——弹层就会永远开着，pumpAndSettle 死锁。
        // 打开就够了，断言由探针在树上做。
        openSheet: (context, kit) async {
          unawaited(showAgentPresetSheet(context, kit.gateway!));
        },
        // 快路径「直接新建」必须在第一位——默认建会话只多一击（D-073）。
        requiredCopy: [
          '直接新建（默认预设）',
          'standard',
          '默认',
          'Alpha Radar',
          'Beta Creator',
          '配置损坏',
        ],
        probes: [
          UiProbe(
            name: 'broken 预设可见但如实标注（配置损坏）',
            act: (tester) async {
              // 巡检宿主默认 zh，所以断言钉中文文案（wire 值是 'invalid
              // config'，UI 用 l10n 的 presetsBrokenChip 渲染成「配置损坏」）。
              // 拿英文去断言会得到一个「找不到元素」的假失败——D-052 的老坑：
              // 没写明语言前提的断言会在语言变化时飘。
              await tester.ensureVisible(find.textContaining('配置损坏').first);
              await tester.pumpAndSettle();
            },
            expectAfter: ['配置损坏'],
          ),
        ],
      ),
      UiSurface(
        id: 'console.team.empty',
        title: 'team 页 · 无子代理目录',
        group: 'Console 附属',
        build: (ctx, kit) => TeamPage(
          parentSessionId: 'sweep-parent',
          // 缺席 ≠ 空列表：引擎没提供目录是一种独立的诚实回答。
          projections: const SessionProjectionBaseline(
            asOfSeq: 0,
            values: Projections(),
          ),
          l10n: L10n.of(ctx),
          onOpenChild: (_) {},
        ),
      ),
      UiSurface(
        id: 'console.team.catalog',
        title: 'team 页 · 有子代理',
        group: 'Console 附属',
        build: (ctx, kit) => TeamPage(
          parentSessionId: 'sweep-parent',
          projections: SessionProjectionBaseline(
            asOfSeq: 1,
            values: Projections(
              subagentCatalog: [
                for (final raw in const [
                  {
                    'label': 'Alpha leg',
                    'mode': 'continuable',
                    'sessionId': 'child-1',
                  },
                  {
                    'label': 'Beta leg',
                    'mode': 'continuable',
                    'sessionId': 'child-2',
                  },
                ])
                  SubagentCatalogEntry.fromJson(raw),
              ],
            ),
          ),
          l10n: L10n.of(ctx),
          onOpenChild: (_) {},
        ),
        requiredCopy: ['Alpha leg', 'Beta leg'],
      ),

      // ───────── 设置 ─────────
      UiSurface(
        id: 'settings.home',
        title: '设置 · 主页',
        group: '设置',
        build: (_, kit) => SettingsPage(
          store: MachinesStore(repo: InMemoryMachinesRepository()),
          settings: SettingsStore(storage: SweepStorage()),
        ),
        requiredCopy: ['生物识别锁', '证书锁定', '语言', '关于'],
      ),
      UiSurface(
        id: 'settings.pins',
        title: '设置 · 证书锁定',
        group: '设置',
        build: (_, kit) => PinsPage(
          store: MachinesStore(repo: InMemoryMachinesRepository()),
        ),
      ),
      UiSurface(
        id: 'settings.language',
        title: '设置 · 语言',
        group: '设置',
        build: (_, kit) => LanguagePage(
          store: LocaleStore(storage: SweepStorage()),
        ),
      ),
      UiSurface(
        id: 'settings.about',
        title: '设置 · 关于',
        group: '设置',
        build: (_, kit) => const AboutPage(),
        requiredCopy: ['App 版本', '隧道协议版本', '许可', '源码'],
      ),
      UiSurface(
        id: 'settings.diagnostics',
        title: '设置 · 诊断日志',
        group: '设置',
        build: (_, kit) => const DiagnosticsPage(),
      ),
    ];

Future<void> _idle(WidgetTester tester) async {}

/// 点一段文本所在的可点控件，**先把它滚进视口**。
///
/// 真机上手指可以滑，测试里 `tap()` 不会：finder 派生的落点如果落在视口外，
/// `tap()` 只会打一条 warning 就什么也没做——然后探针报「点开之后 X 没出现」，
/// 失败原因长得像 App 坏了，其实只是目标在半屏之下。**「能不能点得到」本身就
/// 是排版该管的事**，所以这个 helper 是巡检的一部分，不是测试便利。
Future<void> sweepTapText(WidgetTester tester, String text) async {
  final finder = find.textContaining(text, findRichText: true).first;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 一个纯内存的引擎替身，供不依赖具体端点形状的界面用。
FakeEngineGateway _newGateway(WidgetTester tester) {
  final gateway = FakeEngineGateway();
  addTearDown(gateway.dispose);
  return gateway;
}

FakeEngineGateway _newJobsGateway(WidgetTester tester) {
  final gateway = FakeEngineGateway();
  addTearDown(gateway.dispose);
  return gateway;
}

Future<void> _prepareChat(
  WidgetTester tester,
  SweepKit kit, {
  required List<SessionWireEvent> events,
}) async {
  final gateway = FakeEngineGateway();
  final controller = ChatController(
    gateway: gateway,
    eventsRefreshInterval: Duration.zero,
  )..startEvents();
  addTearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });
  await controller.open('sweep-session');
  kit.chat = controller;
  kit.chatGateway = gateway;
  kit.events = events;
}

Widget _chatPane(BuildContext context, SweepKit kit) =>
    ChatPane(controller: kit.chat!);

Widget _jobsPane(BuildContext context, SweepKit kit) => JobsPane(
      gateway: kit.gateway!,
      sessionId: 'sweep-session',
      l10n: L10n.of(context),
    );

Future<void> _feedChat(WidgetTester tester, SweepKit kit) async {
  final gateway = kit.chatGateway!;
  gateway.raiseReady();
  // 只走 snapshot 的 records：真机冷开一个会话就是这个形状。
  // 额外再逐条 pushEvent 会造成同一批 seq 投两遍——气泡列表按 seq 去重，
  // 结果是「有的行出现、有的行不出现」，很容易被误读成排版问题。
  gateway.pushFrame(sweepSnapshot(
    id: 'sweep-session',
    events: kit.events,
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}
