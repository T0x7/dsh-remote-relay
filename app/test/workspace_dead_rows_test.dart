import 'dart:async';

import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';
import 'fakes/fake_engine_gateway.dart';

/// D-067：工作区树里有一类行，注册表里有 id、引擎的 `session/list` 里却没有
/// ——宿主侧任务绕过引擎直写 journal（`job-scheduled-column-*` 这批），或 journal
/// 被清理后注册表残留（回测研究那 139 条）。引擎对它们一律 `session/not-found`，
/// 用户点开后永远进不了对话页（docs/internal/engine-ghost-session-rows-report-20261006.md）。
///
/// App 侧的修法分三条边界：
/// 1. **判死必须有正据**：后台 `session/list` 刷新成功之后才允许把一个 id
///    标成「已失效」；刷新没回来 / 刷新失败，行保持原样可点——把没核实过的
///    id 标死，和把点不开的行画成正常行，是同一种撒谎。
/// 2. 死行**不可打开**（点了必然失败），但保留「归档」入口：这是用户唯一
///    能自己清理这些行的路径；置顶按钮对死行没有意义，不画。
/// 3. 死行排在工作区列表末尾——卡片只预览 3 行，别让一行引擎里早就没有的
///    记录占掉有用名额。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

Map<String, dynamic> _baseline({
  List<String> sessions = const ['s-live', 's-ghost'],
}) =>
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
            'updatedAt': '2026-10-06T01:00:00Z',
          },
        ],
        'archivedSessionIds': <String>[],
        'pinnedSessionIds': <String>[],
      },
    };

SessionSummary _summary(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1791000000000,
      running: false,
      blank: false,
      agentAvailable: true,
    );

void main() {
  late FakeEngineGateway gateway;
  late SessionTitleCache titles;

  setUp(() {
    pinChineseSystemLocale();
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    titles = SessionTitleCache.inMemory();
    addTearDown(titles.dispose);
  });

  tearDown(unpinSystemLocale);

  testWidgets('刷新成功后：引擎没有的 id 显示已失效、点不开，活的照常',
      (tester) async {
    final opened = <String>[];
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    gateway.seedWorkspaces([_baseline()]);
    final controller = WorkspaceRegistryController(gateway, titles: titles);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: opened.add,
      // 模拟宿主把 session/list 刷回来：只有 s-live 是活的。
      refreshSessions: () async {
        sessions.value = [_summary('s-live')];
      },
    )));
    await tester.pumpAndSettle();

    // 死行有「已失效」徽标，活的没有。
    expect(find.text('已失效'), findsOneWidget);

    // 死行点了不开对话；活行照常。
    await tester.tap(find.text('s-ghost'));
    await tester.pump();
    expect(opened, isEmpty, reason: '点必然失败的行，等于把失败画成可点');
    await tester.tap(find.text('s-live'));
    await tester.pump();
    expect(opened, ['s-live']);

    // 死行保留归档（唯一自助清理路径），没有置顶。
    expect(find.byTooltip('归档'), findsNWidgets(2));
    expect(find.byTooltip('置顶'), findsOneWidget);
  });

  testWidgets('刷新没回来之前：不把未知 id 误判成死行', (tester) async {
    final never = Completer<void>();
    final opened = <String>[];
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    gateway.seedWorkspaces([_baseline()]);
    final controller = WorkspaceRegistryController(gateway, titles: titles);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: opened.add,
      refreshSessions: () => never.future,
    )));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(find.text('已失效'), findsNothing);
    await tester.tap(find.text('s-ghost'));
    await tester.pump();
    expect(opened, ['s-ghost'],
        reason: '没有正据就不能拦：此时它只是「还没核实」');
  });

  testWidgets('刷新失败（引擎降级/超时）：保持不判死，也不崩', (tester) async {
    final opened = <String>[];
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    gateway.seedWorkspaces([_baseline()]);
    final controller = WorkspaceRegistryController(gateway, titles: titles);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: opened.add,
      refreshSessions: () async => throw Exception('engine degraded'),
    )));
    await tester.pumpAndSettle();

    expect(find.text('已失效'), findsNothing);
    await tester.tap(find.text('s-ghost'));
    await tester.pump();
    expect(opened, ['s-ghost']);
  });

  testWidgets('死行排在活行后面：卡片预览不让死行占名额', (tester) async {
    final sessions = ValueNotifier<List<SessionSummary>>(const []);
    addTearDown(sessions.dispose);
    gateway.seedWorkspaces([
      _baseline(sessions: ['s-ghost', 's-live', 's-ghost-2']),
    ]);
    final controller = WorkspaceRegistryController(gateway, titles: titles);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: (_) {},
      refreshSessions: () async {
        sessions.value = [_summary('s-live')];
      },
    )));
    await tester.pumpAndSettle();

    final live = tester.getRect(find.text('s-live'));
    final ghost = tester.getRect(find.text('s-ghost'));
    final ghost2 = tester.getRect(find.text('s-ghost-2'));
    expect(live.top, lessThan(ghost.top), reason: '活行排最前');
    expect(ghost.top, lessThan(ghost2.top), reason: '死行按注册表原序垫底');
  });
}
