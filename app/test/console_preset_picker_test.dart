import 'package:dsh_remote_app/console/agent_preset_sheet.dart';
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
Future<({FakeEngineGateway gateway, Future<String?> picked})> _openSheet(
  WidgetTester tester,
  FakeEngineGateway gateway,
) async {
  Future<String?>? picked;
  await tester.pumpWidget(_host(
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            picked = showAgentPresetSheet(context, gateway);
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
    expect(await sheet.picked, 'alpha-radar');
  });

  testWidgets('直接新建：返回空串，createSession 不带 preset', (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    final sheet = await _openSheet(tester, gateway);

    await tester.tap(find.text('直接新建（默认预设）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(await sheet.picked, '', reason: '空串 = 不带 preset，引擎默认 standard');
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
    expect(await sheet.picked, '');
  });
}
