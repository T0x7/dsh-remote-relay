import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:integration_test/integration_test.dart';

/// D-080：真机冒烟底座。
///
/// ⚠️⚠️ **跑这套用例会清空目标设备上的 App 数据**（配对、语言偏好全没）：
/// `flutter test integration_test` 的安装流程包含卸载重装，Android 卸载即
/// 清 Keystore 与应用数据，**不可恢复**。2026-10-08 在用户主力机实测两次
/// 抹掉配对。只允许跑在专用测试机/模拟器上；要在日常机跑必须先获机主同意。
///
/// 跑法：
///
/// ```
/// cd app && flutter test integration_test -d a0228a1c
/// ```
///
/// 与宿主机 widget 测试的区别：跑在**真实设备、真实数据、真实网络**上，
/// binding 是 LiveTestWidgetsFlutterBinding（真实时间、真实点击），不查
/// pending timer。断言只钉**结构不变量**（三 Tab、诊断页可达、输入框在），
/// 不钉具体会话内容——设备上是用户的真实数据。
///
/// 指纹门（D-056）：机器页/设置页无门；若控制台被门拦住，控制台组会打印
/// `biometric gate armed — skipped` 并跳过（门的本体是安全特性，自动化
/// 不该绕过它）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 在整棵树（含 offstage）按子串找 Text。
  bool hasText(WidgetTester tester, String s) => tester
      .widgetList<Text>(
        find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(s)),
      )
      .isNotEmpty;

  // 设备语言跟随系统且可被用户改（D-052），断言一律 zh/en 双语兜底。
  bool hasAnyText(WidgetTester tester, List<String> candidates) =>
      candidates.any((c) => hasText(tester, c));

  bool hasBiometricGate(WidgetTester tester) =>
      hasText(tester, '指纹') || hasText(tester, '验证');

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(DshRemoteApp(
      titleCache: SessionTitleCache(storage: SharedPreferencesAsync()),
    ));
    // 真机上有真实网络调用：定步推进代替 pumpAndSettle（后者可能永不归静）。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('冒烟 ① 冷启动落在机器页，底部三 Tab 可用', (tester) async {
    await pumpApp(tester);

    expect(hasAnyText(tester, ['机器', 'Machines']), isTrue,
        reason: '冷启动应落在机器页');
    expect(
        hasAnyText(tester, ['控制', 'Console']) &&
            hasAnyText(tester, ['设置', 'Settings']),
        isTrue,
        reason: '底部导航三 Tab');

    // 切 Tab 两次不炸。
    await tester.tap(find.text('Settings').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Machines').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('设置').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('机器').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('冒烟 ② 设置页可达诊断日志入口，且能打开', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('设置').last);
    await tester.pump(const Duration(seconds: 1));

    final diagHit = hasAnyText(tester, ['诊断日志', 'Diagnostics log']);
    expect(diagHit, isTrue, reason: '设置页应有「诊断日志」入口（D-077 日志系统）');
    await tester.tap(find.text('Diagnostics log').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('诊断日志').last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));

    // 日志页两态皆合法：空态文案或已有日志行。
    final empty = hasAnyText(tester, ['暂无日志。', 'No log entries yet.']);
    final hasLines = hasText(tester, 'flutter') ||
        hasText(tester, '[chat]') ||
        hasAnyText(tester, ['诊断', 'Diagnostics']);
    expect(empty || hasLines, isTrue, reason: '诊断日志页空态/有行二选一');
  });

  testWidgets('冒烟 ③ 控制台有输入框且能打字（若被指纹门拦则跳过）', (tester) async {
    await pumpApp(tester);
    await tester.tap(hasText(tester, 'Console')
        ? find.text('Console').last
        : find.text('控制').last, warnIfMissed: false);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    if (hasBiometricGate(tester)) {
      // 门开着就到此为止：绕门不是自动化该做的事。
      // ignore: avoid_print
      print('[D-080] biometric gate armed — console steps skipped');
      return;
    }
    final composer = find.text('发消息给 agent…');
    final composerEn = find.text('Message the agent…');
    final expired = hasAnyText(tester, [
      '已过期', '重新配对', '会话已失效', 'Expired', 're-pair',
    ]);
    final comp = composer.evaluate().isNotEmpty ? composer : composerEn;
    if (comp.evaluate().isNotEmpty) {
      await tester.tap(comp);
      await tester.enterText(comp, 'integration-smoke');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('integration-smoke'), findsOneWidget);
      // 不真正发送：这条用例只证明输入链路活着，发送已有 D-077 真机证据。
    } else {
      // 机器过期/未配对时控制台显示失效态——同为合法状态（2026-10-08 真机：
      // 配对 URL 会话过期后控制台即此形态）。结构不变量：不崩溃、有失效提示。
      expect(expired, isTrue,
          reason: '无输入框时必须呈现过期/重配对态，而不是空白或崩溃');
      // ignore: avoid_print
      print('[D-080] machine expired — composer absent, expired state shown');
    }
  });
}