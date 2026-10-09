// D-033 — landscape layout compatibility.
library;
///
/// The app declares landscape support on both platforms (AndroidManifest leaves
/// orientation to the sensor; iOS lists both landscape directions), so every
/// key screen must survive a 2400×1080 viewport without RenderFlex overflow
/// and with its primary action still reachable — including the pairing sheet
/// under a tall keyboard, where landscape leaves very little vertical room.
///
/// Overflow in a widget test surfaces as a thrown exception (Flutter paints
/// the yellow-black stripes and reports it in debug), which fails the test.
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

void main() {
  // Landscape phone: the long edge across, same pixel density as portrait.
  Future<void> useLandscape(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 这套断言全是中文字符串，而 D-052 之后 App 跟随系统语言——语言前提
    // 必须写出来，不能靠测试平台默认的 en_US 恰好对上。
    pinChineseSystemLocaleFor(tester);
  }

  Future<MachinesStore> pumpApp(
    WidgetTester tester, {
    List<MachineEntry> seed = const [],
  }) async {
    final store = MachinesStore(repo: InMemoryMachinesRepository(), seed: seed);
    await tester.pumpWidget(DshRemoteApp(store: store));
    await tester.pumpAndSettle();
    return store;
  }

  group('D-033 landscape', () {
    testWidgets('machines empty state renders without overflow',
        (tester) async {
      await useLandscape(tester);
      await pumpApp(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('扫码 / 粘贴链接'), findsOneWidget);
    });

    testWidgets('machines list with a card renders without overflow',
        (tester) async {
      await useLandscape(tester);
      final entry = machineFrom(mintTestUrl());
      await pumpApp(tester, seed: [entry]);
      expect(tester.takeException(), isNull);
      expect(find.text('mac-mini'), findsOneWidget);
    });

    testWidgets('pairing sheet: 解析链接 stays on screen under a 590px keyboard',
        (tester) async {
      await useLandscape(tester);
      final store = await pumpApp(tester);
      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();

      // Landscape keyboard: shorter in px than portrait's, but a much larger
      // share of the now-short screen.
      tester.view.viewInsets = FakeViewPadding(bottom: 590);
      await tester.pumpAndSettle();

      final button = find.text('解析链接');
      expect(button, findsOneWidget);
      final dy = tester.getBottomLeft(button).dy;
      expect(dy, lessThanOrEqualTo(1080),
          reason: 'button must be inside the landscape viewport');
      expect(tester.takeException(), isNull);
      // Sanity: the store is the one we opened (guards against a rewritten
      // helper silently changing the fixture).
      expect(store.machines.value, isEmpty);
    });

    testWidgets('pairing sheet: paste + parse still works in landscape',
        (tester) async {
      await useLandscape(tester);
      await pumpApp(tester);
      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), mintTestUrl().toString());
      await tester.tap(find.text('解析链接'));
      await tester.pumpAndSettle();

      expect(find.text('确认机器'), findsOneWidget,
          reason: 'landscape parse must reach the confirm step');
      expect(tester.takeException(), isNull);
    });
  });
}
