import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes/fake_engine_gateway.dart';
import 'factories.dart';

/// D-059：工作区列表只有 session id，因为注册表**在 wire 上就没有 title**
///（`WorkspaceView.sessionIds` 是 `readonly SessionId[]`）。引擎的
/// `SessionSummary` 同样没有 title 字段——dsh web 读的是另一个 namespace
///（`session-reference` 的 `@Remote('candidates')`），那是 SPA 常驻连接才用得起的。
///
/// 结论：不追求「全量标题」，只做**打开过��会话有标题**。
/// `session/follow` 的首帧 header 里带 `title`（`SessionHeader.title`），而 App
/// 为了打开这个会话已经付过那笔请求了——顺手把 title 记下来是零成本。
///
/// 剩下的会话如实显示 id。`job-cnradar-20260924-110450` 这种 id 本身带任务名和
/// 时间戳，对定时任务够读；真正读不出的是子代理那批裸 uuid，而它们多数正是
/// 用户会点进去看的。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

Map<String, dynamic> _baseline({List<String> sessions = const ['s-1', 's-2']}) =>
    {
      'type': 'baseline',
      'value': {
        'items': [
          {
            'workspaceId': 'w-1',
            'path': '/tmp/jobs',
            'title': '定时任务',
            'sessionIds': sessions,
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-05T01:00:00Z',
          },
        ],
        'archivedSessionIds': <String>[],
        'pinnedSessionIds': <String>[],
      },
    };

void main() {
  late FakeEngineGateway gateway;
  late SessionTitleCache titles;

  setUp(() {
    pinChineseSystemLocale();
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    // App 层从 follow 首帧里攒下来的「会话 id → 标题」。
    titles = SessionTitleCache.inMemory();
    addTearDown(titles.dispose);
  });

  tearDown(unpinSystemLocale);

  Future<WorkspaceRegistryController> mount(WidgetTester tester) async {
    gateway.seedWorkspaces([_baseline()]);
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    final controller = WorkspaceRegistryController(gateway, titles: titles);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: (_) {},
    )));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    return controller;
  }

  testWidgets('有标题的会话显示标题，没有的仍显示 id', (tester) async {
    await mount(tester);

    // 打开过 s-1，controller 记下了它的标题。
    await titles.remember('s-1', 'nightly-backtest 复盘');
    await tester.pumpAndSettle();

    expect(find.text('nightly-backtest 复盘'), findsOneWidget);
    expect(find.text('s-1'), findsNothing);
    // s-2 没打开过，如实显示 id —— 不编一个假标题。
    expect(find.text('s-2'), findsOneWidget);
  });

  testWidgets('标题参与搜索：搜标题能命中，搜 id 也能', (tester) async {
    await mount(tester);
    await titles.remember('s-1', 'nightly-backtest 复盘');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '复盘');
    await tester.pumpAndSettle();
    expect(find.text('nightly-backtest 复盘'), findsOneWidget);
    expect(find.text('s-2'), findsNothing,
        reason: '搜不到就该不显示，而不是把所有行都留着');

    // 搜 id 也要能命中（用户记得住从别处抄来的 id）。
    await tester.enterText(find.byType(TextField), 's-2');
    await tester.pumpAndSettle();
    // 排除搜索框自己：它也含 's-2' 这段文字。
    expect(
      find.descendant(of: find.byType(Scaffold), matching: find.text('s-2')),
      findsWidgets,
    );
    expect(find.text('nightly-backtest 复盘'), findsNothing);
  });

  testWidgets('D-062：标题活过 App 重启（持久化）', (tester) async {
    // 第一段「进程」：cache 用**真存储**（inMemory 不落盘，测不了这个）。
    final fakePlatform = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = fakePlatform;
    addTearDown(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });
    final first = SessionTitleCache(storage: SharedPreferencesAsync());
    await first.load();
    await first.remember('s-1', 'nightly-backtest 复盘');

    await mount(tester);
    await titles.remember('s-1', 'nightly-backtest 复盘');
    await tester.pumpAndSettle();
    expect(find.text('nightly-backtest 复盘'), findsOneWidget);

    // 第二段「进程」：全新 cache 指向同一份存储。第一版的纯内存 Map 在这里
    // 就露馅了——真机上重启 App 后所有标题退回 id，用户看到的正是这个。
    final revived = SessionTitleCache(storage: SharedPreferencesAsync());
    await revived.load();
    expect(revived.titleOf('s-1'), 'nightly-backtest 复盘',
        reason: '标题是用户已经付过钱的信息（打开会话时顺带拿到的），'
            '重启就丢等于白付');

    // 恢复出来的标题要能上屏。
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    final controller = WorkspaceRegistryController(gateway, titles: revived);
    addTearDown(controller.dispose);
    gateway.seedWorkspaces([_baseline()]);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('nightly-backtest 复盘'), findsOneWidget);
  });

  test('空白标题回落到 id，而不是渲染一个空行', () async {
    final cache = SessionTitleCache.inMemory();
    await cache.remember('a', '   ');
    await cache.remember('b', '');
    await cache.remember('c', '真名');
    // 一个都记不进去：还没命名的会话的 header.title 是空的，把它存下来等于
    // 用空白替换掉本来可读的 job-cnradar-2026…。
    expect(cache.length, 1);
    expect(cache.titleOf('a'), 'a');
    expect(cache.titleOf('b'), 'b');
    expect(cache.titleOf('c'), '真名');
    expect(cache.titleOf('never-seen'), 'never-seen');
  });
}
