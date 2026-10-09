import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/pairing/pairing_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

void main() {
  // 断言全是中文字符串，而 D-052 之后 App 跟随系统语言——语言前提写明在这里，
  // 不要靠测试平台默认的 en_US 恰好对上（它对不上，会让整套用例静默飘红）。
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  // A valid signed URL for the paste field (minted with the same algorithm
  // as the machine side; 24h window so the confirm step is reachable).
  // Minted relative to now — a fixed date would expire the fixture overnight.
  final validUrl = mintTestUrl();

  testWidgets('empty state → open pairing → paste → confirm card renders',
      (WidgetTester tester) async {
    final repo = InMemoryMachinesRepository();
    final store = MachinesStore(repo: repo);

    await tester.pumpWidget(DshRemoteApp(store: store));
    expect(find.text('还没有机器'), findsOneWidget);

    await tester.tap(find.text('扫码 / 粘贴链接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), validUrl.toString());
    await tester.tap(find.text('解析链接'));
    await tester.pumpAndSettle();

    // Confirm view (屏 C): relay origin, machine name, lock-and-connect.
    expect(find.text('确认机器'), findsOneWidget);
    expect(find.textContaining('mac-mini'), findsOneWidget);
    expect(find.text('锁定并连接'), findsOneWidget);
  });

  testWidgets('malformed link is refused inline with a specific copy',
      (WidgetTester tester) async {
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    await tester.pumpWidget(DshRemoteApp(store: store));

    await tester.tap(find.text('扫码 / 粘贴链接'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'https://relay.example/?token=deadbeef');
    await tester.tap(find.text('解析链接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('token 形态已退役'), findsOneWidget);
    expect(find.text('确认机器'), findsNothing);
  });

  testWidgets('verify 401 → 屏 J 失效卡（不落库）',
      (WidgetTester tester) async {
    final repo = InMemoryMachinesRepository();
    final store = MachinesStore(repo: repo);
    PairingFlowSheet.verifierOverride =
        (_) async => PairingVerifyResult.invalid;

    await tester.pumpWidget(DshRemoteApp(store: store));
    await tester.tap(find.text('扫码 / 粘贴链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), validUrl.toString());
    await tester.tap(find.text('解析链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁定并连接'));
    await tester.pumpAndSettle();

    expect(find.text('二维码已失效'), findsOneWidget);
    expect(find.textContaining('刷新后重试'), findsOneWidget);
    expect(store.machines.value, isEmpty);
    expect(repo.entries, isEmpty, reason: '死凭证绝不入库');
    PairingFlowSheet.verifierOverride = null;
  });

  testWidgets('verify 200 → 机器卡出现（屏 A 有机器态）',
      (WidgetTester tester) async {
    final repo = InMemoryMachinesRepository();
    final store = MachinesStore(repo: repo);
    PairingFlowSheet.verifierOverride =
        (_) async => PairingVerifyResult.valid;

    await tester.pumpWidget(DshRemoteApp(store: store));
    await tester.tap(find.text('扫码 / 粘贴链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), validUrl.toString());
    await tester.tap(find.text('解析链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁定并连接'));
    await tester.pumpAndSettle();

    expect(find.text('mac-mini'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:8080'), findsOneWidget);
    expect(find.textContaining('/30 天'), findsOneWidget);
    expect(repo.entries, hasLength(1));
    expect(repo.entries.first.id, 'sess_test01');
    PairingFlowSheet.verifierOverride = null;
  });

  testWidgets('expired entry renders the danger card state',
      (WidgetTester tester) async {
    final entry = expiredMachine();
    await tester.pumpWidget(DshRemoteApp(
        store: MachinesStore(repo: InMemoryMachinesRepository(), seed: [entry])));
    expect(find.text('mac-mini'), findsOneWidget);
    expect(find.text('已过期'), findsOneWidget);
    expect(find.textContaining('会话已失效'), findsOneWidget);
  });

  test('MachineEntry roundtrips through JSON', () {
    final e = machineFrom(validUrl);
    final back = MachineEntry.decodeList(MachineEntry.encodeList([e])).single;
    expect(back.id, e.id);
    expect(back.params.bearer, e.params.bearer);
    expect(back.firstPairedMs, e.firstPairedMs);
  });

  // D-029 — the pairing sheet's primary button must stay on screen while the
  // IME is up. The inset padding used to read the page's MediaQuery, whose
  // dependency lives outside the modal route, so the padding froze at the
  // keyboard height captured when the sheet first built. On a tall MIUI Sogou
  // keyboard (~960 px) that pushed 解析链接 clean off the bottom of the screen:
  // reproduced on-device with the real IME, where no mint pixel existed at all.
  group('D-029 keyboard insets', () {
    Future<void> openSheetWithKeyboard(WidgetTester tester, double inset) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        DshRemoteApp(store: MachinesStore(repo: InMemoryMachinesRepository())),
      );
      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();

      // The sheet is open; now the IME arrives, exactly as it does on a real
      // focus of the URL field.
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
    }

    testWidgets('解析链接 stays on screen with a 960px keyboard',
        (WidgetTester tester) async {
      await openSheetWithKeyboard(tester, 960);

      final button = find.text('解析链接');
      expect(button, findsOneWidget,
          reason: 'the primary action must survive the keyboard');
      expect(tester.getBottomLeft(button).dy, lessThan(2400 - 960),
          reason: 'and it must sit ABOVE the keyboard, not under it');
    });

    testWidgets('the button is tappable, not merely present',
        (WidgetTester tester) async {
      await openSheetWithKeyboard(tester, 960);
      await tester.enterText(find.byType(TextField), validUrl.toString());
      await tester.pumpAndSettle();

      // A button hidden behind the keyboard renders but never receives the tap;
      // the confirm view is the observable proof that it was actually pressed.
      await tester.tap(find.text('解析链接'));
      await tester.pumpAndSettle();
      expect(find.text('确认机器'), findsOneWidget);
    });
  });
}
