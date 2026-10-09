import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/lock/biometric_gate.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/machines/machine_detail_page.dart';
import 'package:dsh_remote_app/machines/session_expired_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// In-memory secure storage for widget tests (no platform channel).
class MemStorage extends FlutterSecureStorage {
  final map = <String?, String>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      map[key];

  @override
  Future<void> write({
    required String key,
    String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    map[key] = value ?? '';
  }
}

/// Synchronous snapshot source for the detail tests (fake-async: no sockets).
Future<RemoteSessionSnapshot?> Function(MachineEntry) fetchOk = (_) async =>
    RemoteSessionSnapshot.fromJson(const {
      'tunnel': {'state': 'connected', 'relayUrl': 'http://127.0.0.1:8080', 'manualOff': false},
      'sessions': [],
      'devices': [
        {'sessionId': 'sess_test01', 'createdAt': 0, 'lastSeen': 1, 'onlineWs': 1, 'online': true, 'paired': true},
      ],
    });

/// 屏 D/I/G/H widget coverage: three-tab root, detail sections + actions,
/// expired-page three-cause copy, settings toggles, lock gate.
void main() {
  // 断言含中文字符串，而 D-052 之后 App 跟随系统语言——语言前提写明在这里。
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  Widget host(Widget child) => MaterialApp(
        theme: ThemeData.dark(),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('zh'),
        home: child,
      );

  group('root shell (导航)', () {
    testWidgets('three tabs switch: 机器 / 控制 / 设置', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository());
      final settings = SettingsStore(storage: MemStorage());
      await tester.pumpWidget(DshRemoteApp(store: store, settings: settings));
      await tester.pumpAndSettle();

      expect(find.text('还没有机器'), findsOneWidget);
      await tester.tap(find.text('控制'));
      await tester.pumpAndSettle();
      // The console mounts on first open and, with no machine bound yet,
      // explains what it needs rather than showing the old placeholder.
      expect(find.text('还没有可控制的机器'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('生物识别锁'), findsOneWidget);
    });
  });

  group('屏 D 详情', () {
    testWidgets('renders two clocks + actions for a live machine',
        (tester) async {
      final entry = machineFrom(mintTestUrl());
      await tester.pumpWidget(
          host(MachineDetailPage(entry: entry, fetchOverride: fetchOk)));
      await tester.pumpAndSettle();

      expect(find.text('隧道'), findsOneWidget);
      expect(find.text('会话'), findsOneWidget);
      expect(find.textContaining('/ 30 天'), findsOneWidget);
      expect(find.textContaining('在浏览器打开完整 Web 界面'), findsOneWidget);
      expect(find.text('断开中继'), findsOneWidget);
      expect(find.textContaining('吊销全部配对'), findsOneWidget);
    });

    testWidgets('revoke asks for confirmation first', (tester) async {
      final entry = machineFrom(mintTestUrl());
      await tester.pumpWidget(
          host(MachineDetailPage(entry: entry, fetchOverride: fetchOk)));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.textContaining('吊销全部配对'), 120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('吊销全部配对'));
      await tester.pumpAndSettle();
      expect(find.text('吊销全部配对？'), findsOneWidget);
      expect(find.textContaining('所有设备'), findsOneWidget);
    });
  });

  group('屏 I 失效页（三因）', () {
    testWidgets('expired → 24h copy', (tester) async {
      final entry = expiredMachine();
      await tester.pumpWidget(host(SessionExpiredPage(
        entry: entry,
        onRepair: () {},
        onDelete: () {},
      )));
      expect(find.text('会话已失效'), findsOneWidget);
      expect(find.text('24h 窗口已过期'), findsOneWidget);
      expect(find.textContaining('自动续期未能完成'), findsOneWidget);
      expect(find.textContaining('仅此机器受影响'), findsOneWidget);
    });

    testWidgets('revoked cause (relay verdict) → 吊销 copy', (tester) async {
      final entry = machineFrom(mintTestUrl());
      await tester.pumpWidget(host(SessionExpiredPage(
        entry: entry,
        onRepair: () {},
        onDelete: () {},
        lastAuthCause: AuthCause.revoked,
      )));
      expect(find.text('已被吊销'), findsOneWidget);
    });

    testWidgets('30-day cap → maxAge copy', (tester) async {
      final entry = machineFrom(mintTestUrl(
          now: DateTime.now().subtract(const Duration(days: 31))));
      await tester.pumpWidget(host(SessionExpiredPage(
        entry: entry,
        onRepair: () {},
        onDelete: () {},
        lastAuthCause: AuthCause.maxAge,
      )));
      expect(find.text('达 30 天上限'), findsOneWidget);
    });
  });

  group('屏 G 设置 + 屏 H 锁', () {
    testWidgets('toggles flip and persist through the store', (tester) async {
      final settings = SettingsStore(storage: MemStorage());
      final store = MachinesStore(repo: InMemoryMachinesRepository());
      await tester.pumpWidget(DshRemoteApp(store: store, settings: settings));
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(settings.notifier.value.lockEnabled, isFalse);
      await tester.tap(find.text('生物识别锁'));
      await tester.pumpAndSettle();
      expect(settings.notifier.value.lockEnabled, isTrue);
      expect(settings.notifier.value.remindersEnabled, isTrue);
    });

    testWidgets('lock gate shows when enabled on boot', (tester) async {
      final settings = SettingsStore(storage: MemStorage());
      await settings.setLockEnabled(true);
      // D-056: 屏 H 现在真的会调系统认证，测试平台没有那条通道
      // （`authenticate` 会一直挂着，`pumpAndSettle` 直接超时）。注入一个
      // 「设备不支持」的 gate，既让测试跑得起来，也顺带钉住第三档降级：
      // 不支持的设备退回手动解锁，而不是卡在认证上。
      await tester.pumpWidget(DshRemoteApp(
        store: MachinesStore(repo: InMemoryMachinesRepository()),
        settings: settings,
        biometricGate: _NoBiometricsGate(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('dsh remote 已锁定'), findsOneWidget);
      expect(find.text('这台设备没有可用的生物识别'), findsOneWidget);
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(find.text('还没有机器'), findsOneWidget);
    });
  });
}

/// D-056: 一台没有生物识别的设备。锁屏据此退回手动解锁。
class _NoBiometricsGate implements BiometricGate {
  @override
  Future<bool> isDeviceSupported() async => false;

  @override
  Future<bool> get canCheckBiometrics async => false;

  @override
  Future<List<BiometricKind>> getAvailableBiometrics() async => const [];

  @override
  Future<BiometricResult> authenticate({required String reason}) async =>
      const BiometricResultUnavailable();
}
