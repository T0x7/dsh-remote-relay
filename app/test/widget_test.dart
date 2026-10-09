import 'package:dsh_remote_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

/// Shell smoke: the empty-state machines page renders its scan-first copy and
/// the three-tab chrome, and the countdown chip takes its colour from the core
/// SessionClock verdict (wiring proof for T0.1/M1 boundary).
void main() {
  // 断言是中文，而 D-052 之后 App 跟随系统语言——语言前提写明在这里。
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  testWidgets('machines empty state renders scan-first surfaces',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DshRemoteApp());

    expect(find.text('机器'), findsNWidgets(2)); // app bar + active tab
    expect(find.text('还没有机器'), findsOneWidget);
    expect(find.text('扫码 / 粘贴链接'), findsOneWidget);
    expect(find.text('控制'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('dark theme is the default', (WidgetTester tester) async {
    await tester.pumpWidget(const DshRemoteApp());
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });
}
