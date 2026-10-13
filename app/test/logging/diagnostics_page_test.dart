import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/logging/diagnostics_page.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 屏 G「诊断日志」页（logging plan P4）：渲染行、元信息、空态、清空确认流。
///
/// 刻意不点的两个按钮：复制（Clipboard 平台通道）与分享（share_plus 平台
/// 通道）——widget 测试环境没有它们，点了只会验证 MissingPluginException。
/// 两个动作都只有一两行胶水，真实通道行为留给真机。
void main() {
  final previousSink = AppLog.sink;

  setUp(() {
    AppLog.sink = MemoryLogSink();
  });

  tearDown(() {
    AppLog.sink = previousSink;
  });

  MemoryLogSink sink() => AppLog.sink! as MemoryLogSink;

  void seed() {
    for (final message in [
      'I/[relay] first sanitized line',
      'W/[tofu] PIN MISMATCH host=relay.example.com',
    ]) {
      sink().write(LogLine(
          ts: DateTime(2026, 10, 7, 12, 30),
          level: LogLevel.info,
          tag: 'seed',
          message: message));
    }
  }

  /// 三个通道各一行——用来验通道筛选。
  void seedChannels() {
    sink().write(LogLine(
        ts: DateTime(2026, 10, 13, 10),
        level: LogLevel.info,
        tag: 'relay',
        message: 'APP channel line'));
    sink().write(LogLine(
        ts: DateTime(2026, 10, 13, 10),
        level: LogLevel.error,
        tag: 'flutter',
        message: 'CRASH channel line',
        channel: LogChannel.crash));
    sink().write(LogLine(
        ts: DateTime(2026, 10, 13, 10),
        level: LogLevel.audit,
        tag: 'audit',
        message: 'AUDIT channel line',
        channel: LogChannel.audit));
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: Locale('zh'),
      home: DiagnosticsPage(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders lines monospace + meta line', (tester) async {
    seed();
    await pump(tester);

    expect(find.textContaining('first sanitized line'), findsOneWidget);
    expect(find.textContaining('PIN MISMATCH host=relay.example.com'),
        findsOneWidget);
    // 元信息：字节 + 行数（zh 文案「{size} · 共 {lines} 行」）
    expect(find.textContaining('共 2 行'), findsOneWidget);
  });

  testWidgets('empty sink shows the empty state', (tester) async {
    await pump(tester);

    expect(find.text('暂无日志。'), findsOneWidget);
  });

  testWidgets('clear asks for confirmation, then empties the sink',
      (tester) async {
    seed();
    await pump(tester);

    await tester.tap(find.byTooltip('清空日志'));
    await tester.pumpAndSettle();
    expect(find.text('清空日志？'), findsOneWidget);

    // 先取消：sink 必须原封不动。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sink().cleared, isFalse);

    // 再来一次，这次确认。
    await tester.tap(find.byTooltip('清空日志'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空日志'));
    await tester.pumpAndSettle();

    expect(sink().cleared, isTrue);
    expect(sink().lines, isEmpty);
    expect(find.text('暂无日志。'), findsOneWidget);
  });

  // D-107：诊断页按通道切换。真机上那份日志的病是「打开只能看到一屏
  // FollowAssistantStream」——崩溃与操作记录挤不出来，就等于没记。
  testWidgets('channel filter shows only that channel', (tester) async {
    seedChannels();
    await pump(tester);

    // 默认「全部」：三个通道都在。
    expect(find.textContaining('APP channel line'), findsOneWidget);
    expect(find.textContaining('CRASH channel line'), findsOneWidget);
    expect(find.textContaining('AUDIT channel line'), findsOneWidget);

    await tester.tap(find.text('崩溃'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CRASH channel line'), findsOneWidget);
    expect(find.textContaining('APP channel line'), findsNothing);
    expect(find.textContaining('AUDIT channel line'), findsNothing);
    expect(find.textContaining('共 1 行'), findsOneWidget,
        reason: '元信息行必须跟着筛选走，不能还报全量');

    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AUDIT channel line'), findsOneWidget);
    expect(find.textContaining('CRASH channel line'), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 3 行'), findsOneWidget);
  });

  testWidgets('empty channel says so, not "the app never ran"',
      (tester) async {
    seed();
    await pump(tester);

    await tester.tap(find.text('崩溃'));
    await tester.pumpAndSettle();

    expect(find.text('该通道暂无日志。'), findsOneWidget);
    expect(find.text('暂无日志。'), findsNothing,
        reason: '「这个通道没有记录」和「App 没在跑」是两回事');
  });
}
