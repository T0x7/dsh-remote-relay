import 'package:dsh_remote_app/console/agent_preset_sheet.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-073：新会话的 agent 预设选择面板。
///
/// dsh web 在新建会话旁常驻 preset 下拉（「标准模式 ▾」），手机收进
/// 「新会话」第一跳。三条约定：
/// 1. **直接新建永远第一颗**——默认 preset 的快路径保持一击可达，
///    选预设是可选项不是强制步骤；
/// 2. `broken` 的预设可见但**不可选**——引擎自己都标了配置损坏；
/// 3. 列表拉取失败时给出退路文案，「直接新建」仍然可用（此时建出来的
///    会话不带 preset，引擎默认 standard）。
///
/// 测试注意：指示器/模态路由动画无限或较长，一律定长 pump，不用
/// pumpAndSettle；每条用例只开一次面板，返回 Future 由 _openSheet 捕获。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// 打开面板并捕获其返回值。
Future<({FakeEngineGateway gateway, Future<NewSessionChoice?> picked})>
    _openSheet(
  WidgetTester tester,
  FakeEngineGateway gateway, {
  List<WorkspaceView> workspaces = const [],
}) async {
  Future<NewSessionChoice?>? picked;
  await tester.pumpWidget(_host(
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            picked = showAgentPresetSheet(context, gateway,
                workspaces: workspaces);
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return (gateway: gateway, picked: picked!);
}

WorkspaceView _ws(String id, String title) => WorkspaceView(
      workspaceId: id,
      path: '/host/work/$id',
      title: title,
      sessionIds: const [],
      createdAt: '2026-10-01T00:00:00Z',
      updatedAt: '2026-10-02T00:00:00Z',
    );

void main() {
  testWidgets('列出预设：默认标记、描述、坏预设标损坏', (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    await _openSheet(tester, gateway);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('直接新建（默认预设）'), findsOneWidget);
    expect(find.text('Alpha Radar'), findsOneWidget);
    // 「默认」角标只属于 standard 行——用精确匹配，别和「直接新建（默认
    // 预设）」的文案撞车。
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('配置损坏'), findsOneWidget,
        reason: '坏预设可见——告诉用户它存在但不可用');
  });

  testWidgets('选预设：pop 回 preset id，createSession 带上 agentPreset', (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    final sheet = await _openSheet(tester, gateway);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Alpha Radar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // createSession 由调用方（console_page._newSession）负责，fab 测试已
    // 端到端覆盖；面板的契约就是把选择如实 pop 回来。
    final choice = await sheet.picked;
    expect(choice!.preset, 'alpha-radar');
    expect(choice.workspaceId, isNull,
        reason: '没有工作区段（未传列表）时不可能带 workspaceId');
  });

  testWidgets('直接新建：返回空串，createSession 不带 preset', (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    final sheet = await _openSheet(tester, gateway);

    await tester.tap(find.text('直接新建（默认预设）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final choice = await sheet.picked;
    expect(choice!.preset, '', reason: '空串 = 不带 preset，引擎默认 standard');
    expect(choice.workspaceId, isNull);
  });

  testWidgets('broken 预设不可选：点了不关面板也不建会话', (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    await _openSheet(tester, gateway);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Beta Creator'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('配置损坏'), findsOneWidget,
        reason: '面板仍开着——不可选的行点了没反应');
    expect(find.text('Alpha Radar'), findsOneWidget,
        reason: '列表原样还在，可以改选别的');
  });

  testWidgets('拉取失败：退路文案可见，直接新建仍可用', (tester) async {
    final gateway = FakeEngineGateway()..agentPresetsError = 'relay/timeout';
    addTearDown(gateway.dispose);
    final sheet = await _openSheet(tester, gateway);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('预设读取失败'), findsOneWidget);
    expect(find.text('直接新建（默认预设）'), findsOneWidget);

    await tester.tap(find.text('直接新建（默认预设）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect((await sheet.picked)!.preset, '');
  });

  group('工作区 chips（combined 方案）', () {
    testWidgets('传入工作区时显示段落：默认 chip + 各工作区按序', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      await _openSheet(tester, gateway, workspaces: [
        _ws('w-jobs', '定时任务'),
        _ws('w-plan', '规划工作区'),
      ]);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('在哪个工作区打开'), findsOneWidget);
      expect(find.text('引擎默认'), findsOneWidget);
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('规划工作区'), findsOneWidget);
    });

    testWidgets('不传工作区时整段隐藏（registry 未就绪的退化形态）', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      await _openSheet(tester, gateway);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('在哪个工作区打开'), findsNothing);
      expect(find.text('引擎默认'), findsNothing);
    });

    testWidgets('选中工作区后选预设：pop 回的 choice 两半都对', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final sheet = await _openSheet(tester, gateway, workspaces: [
        _ws('w-jobs', '定时任务'),
        _ws('w-plan', '规划工作区'),
      ]);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('规划工作区'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Alpha Radar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final choice = await sheet.picked;
      expect(choice!.preset, 'alpha-radar');
      expect(choice.workspaceId, 'w-plan',
          reason: '工作区选择必须随预设一起 pop——这正是 combined 方案的产出');
    });

    testWidgets('工作区默认是「引擎默认」：不点 chips 时 workspaceId 为 null', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final sheet = await _openSheet(tester, gateway, workspaces: [
        _ws('w-jobs', '定时任务'),
      ]);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('直接新建（默认预设）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final choice = await sheet.picked;
      expect(choice!.preset, '');
      expect(choice.workspaceId, isNull,
          reason: '快路径的 wire 请求必须与功能上线前逐字节一致');
    });

    testWidgets('先选了工作区还能改回「引擎默认」', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      final sheet = await _openSheet(tester, gateway, workspaces: [
        _ws('w-jobs', '定时任务'),
      ]);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('定时任务'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('引擎默认'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('直接新建（默认预设）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final choice = await sheet.picked;
      expect(choice!.workspaceId, isNull);
    });
  });
}
