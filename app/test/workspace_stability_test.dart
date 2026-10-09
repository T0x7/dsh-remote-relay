import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';
import 'factories.dart';

/// D-057 的 **App 侧降级**（不是根因修复）。
///
/// 根因在引擎：`entity.ts:101` 的 getter 在读取时用一个还在被填充的懒索引
/// 过滤成员资格，未命中即丢弃，于是会话随机出现又消失
/// （`docs/internal/engine-workspace-membership-flicker-report-20261005.md`）。
///
/// 客户端修不了「会话消失」——拿到什么就显示什么。但**数字不该跟着抖**：
/// 一个每 4 秒变一次、跨度 35~94 的数字，用户无法对它做任何判断，而界面
/// 把它渲染成一个确定的事实。这是我们能自己解决的部分。
///
/// 三条降级：
/// 1. 成员数在引擎还在重算时显示 `—`，稳定后才显示真值（复用未分组那行
///    「说 0 是个事实，而它现在还不是」的既有约定）；
/// 2. 明确告诉用户「正在同步」，而不是让一个跳动的数字自己解释自己；
/// 3. 会话增删不重建用户正在看的那一页。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

SessionSummary s(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1790000000000,
      running: false,
      blank: false,
      agentAvailable: true,
    );

Map<String, dynamic> _baseline({
  String updatedAt = '2026-10-05T01:00:00.000Z',
  List<String> sessions = const ['job-1', 'job-2'],
}) =>
    {
      'type': 'baseline',
      'value': {
        'items': [
          {
            'workspaceId': 'w-jobs',
            'path': '/tmp/jobs',
            'title': '定时任务',
            'sessionIds': sessions,
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': updatedAt,
          },
        ],
        'archivedSessionIds': <String>[],
        'pinnedSessionIds': <String>[],
      },
    };

void main() {
  late FakeEngineGateway gateway;

  setUp(() {
    pinChineseSystemLocale();
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
  });

  tearDown(unpinSystemLocale);

  Future<void> mount(
    WidgetTester tester, {
    List<Object?>? frames,
    List<SessionSummary>? knownSessions,
  }) async {
    if (frames != null) gateway.seedWorkspaces(frames);
    final sessions = ValueNotifier<List<SessionSummary>>(
      knownSessions ?? const [],
    );
    addTearDown(sessions.dispose);
    final controller = WorkspaceRegistryController(gateway);
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
  }

  /// 引擎把 `updatedAt` 推到「刚刚」——也就是它正在重算成员资格。
  Map<String, dynamic> freshRewrite(int count) => _baseline(
        updatedAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 2)).toIso8601String(),
        sessions: List.generate(count, (i) => 'job-$i'),
      );

  testWidgets('引擎在重算时：显示「—」而不是一个每 4 秒变的数字', (tester) async {
    await mount(tester, frames: [freshRewrite(37)]);

    expect(find.text('37'), findsNothing,
        reason: '37 这个数下一帧可能就变成 82，说它是事实是在骗人');
    expect(find.textContaining('正在同步'), findsWidgets);
  });

  testWidgets('数据稳定后：显示真实数字', (tester) async {
    // updatedAt 停在 40 分钟前 = 引擎早就不改这个工作区了。
    await mount(tester, frames: [
      _baseline(
        updatedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 40))
            .toIso8601String(),
        sessions: const ['job-1', 'job-2'],
      ),
    ]);

    expect(find.text('2'), findsOneWidget,
        reason: '定时任务稳定后，2 是事实');
    // 「未分组」那行的「—」是另一回事：后台 session/list 没到，那个数我们本来
    // 就不知道。两条降级各自独立，不能互相解释。
    expect(find.text('未分组'), findsOneWidget);
  });

  testWidgets('重算中如实说明「正在同步」，而不是让数字自己解释自己',
      (tester) async {
    await mount(tester, frames: [freshRewrite(12)]);

    expect(find.textContaining('正在同步'), findsWidgets);
  });

  testWidgets('引擎只是重写时间戳、成员没变：数字收起来并说明在同步',
      (tester) async {
    await mount(tester, frames: [
      _baseline(
        updatedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 40))
            .toIso8601String(),
        sessions: const ['job-1', 'job-2'],
      ),
    ]);
    expect(find.text('job-1'), findsOneWidget);

    // 引擎又推了一帧，成员完全相同，只有 updatedAt 变了。
    gateway.seedWorkspaces([
      _baseline(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        sessions: const ['job-1', 'job-2'],
      ),
    ]);
    final controller = tester
        .widget<WorkspacePickerPage>(find.byType(WorkspacePickerPage))
        .registry;
    controller.applyFrameForTest(decodeWorkspaceFrame(_baseline(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      sessions: const ['job-1', 'job-2'],
    )));
    // 同步中的 CircularProgressIndicator 永远转，pumpAndSettle 收不住
    // （本仓的既有陷阱）；固定时长推进即可。
    await tester.pump(const Duration(milliseconds: 400));

    // 成员没变，但 updatedAt 变成「刚刚」→ 判为重算中，回到「—」。
    // 这正是想要的：引擎重写了时间戳，我们就把数字收起来。
    expect(find.text('job-1'), findsOneWidget);
    expect(find.text('2'), findsNothing);
    expect(find.textContaining('正在同步'), findsWidgets);
  });
}
