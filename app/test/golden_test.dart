import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';
import 'screens_dghi_test.dart' show MemStorage;

/// Golden baselines (plan §12): the three decision-critical screens of the
/// machines tab + settings, zh (app default). Run
/// `flutter test --update-goldens` to refresh after intentional design
/// changes; diffs are review artifacts, not accidents.
void main() {
  // The machine card renders a live countdown and a 30-day day counter, so the
  // clock is frozen for the whole suite: without it these baselines only match
  // during the minute they were captured.
  final frozen = DateTime.utc(2026, 10, 1, 9, 30);

  setUp(() => MachineCard.nowOverride = () => frozen);
  tearDown(() => MachineCard.nowOverride = DateTime.now);

  // D-052 之后 App 跟随系统语言（此前写死 zh），所以基线图对应的语言必须
  // 由测试显式钉住，而不是碰巧撞上测试平台的 en_US 之外的值。
  void useZhBaselines(WidgetTester tester) => pinChineseSystemLocaleFor(tester);

  testWidgets('golden · empty state', (tester) async {
    useZhBaselines(tester);
    await tester.pumpWidget(DshRemoteApp(
      store: MachinesStore(repo: InMemoryMachinesRepository()),
      settings: SettingsStore(storage: MemStorage()),
    ));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/machines_empty.png'));
  });

  testWidgets('golden · machines list (live + expired)', (tester) async {
    useZhBaselines(tester);
    // Order matters to this baseline: the live machine is seeded FIRST, so the
    // top card is the green one and the expired red-dot card is second. The
    // stored baseline was captured while the order was the other way round,
    // which is why the top card's dot and countdown chip are what this test
    // actually pins — a mismatch there means the seed order changed, not that
    // the card regressed.
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [
        machineFrom(mintTestUrl(
          name: 'mac-mini-studio',
          relay: 'https://relay.example.com',
          now: frozen.subtract(const Duration(hours: 1)),
        )),
        expiredMachine(),
      ],
    );
    await tester.pumpWidget(DshRemoteApp(
      store: store,
      settings: SettingsStore(storage: MemStorage()),
    ));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/machines_list.png'));
  });

  testWidgets('golden · settings', (tester) async {
    useZhBaselines(tester);
    final settings = SettingsStore(storage: MemStorage());
    await tester.pumpWidget(DshRemoteApp(
      store: MachinesStore(repo: InMemoryMachinesRepository()),
      settings: settings,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/settings.png'));
  });
}
