import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/settings/about_info.dart';
import 'package:dsh_remote_app/settings/about_page.dart';
import 'package:dsh_remote_app/settings/language_page.dart';
import 'package:dsh_remote_app/settings/locale_store.dart';
import 'package:dsh_remote_app/settings/pins_page.dart';
import 'package:dsh_remote_app/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

/// 屏 G 的三个二级页（PRD §7 信息架构：证书锁定管理 / 语言 / 关于）。
///
/// 覆盖重点是**行为**而不是文案：pin 页要按 certPin 的有无分别说明、语言页
/// 要真的持久化、关于页的版本号必须来自常量而不是页面里的字面量。
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

/// 带 pin 的 https 机器。`MachineEntry.copyWith` 不接受 certPin（续期时
/// 刻意保持原 pin，见 D-025），所以这里直接构造。
MachineEntry pinnedMachine({String host = 'relay.example.com'}) {
  final p = parseSignedUrl(
      mintTestUrl(relay: 'https://$host:8443', sessionId: 'sess_pin01'));
  return MachineEntry(
    id: p.sessionId,
    name: p.name ?? 'mac',
    params: p,
    firstPairedMs: p.tMs,
    certPin: 'a1b2c3d4e5f6' '00112233445566778899aabbccddeeff',
  );
}

void main() {
  Widget host(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
        theme: ThemeData.dark(),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: locale,
        home: child,
      );

  group('屏 G · 证书锁定（TOFU）管理页', () {
    testWidgets('空列表给出空态，而不是空白页', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository());
      await tester.pumpWidget(host(PinsPage(store: store)));
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('尚未钉住任何中继'), findsOneWidget);
    });

    testWidgets('https 机器显示 host + 指纹', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository(),
          seed: [pinnedMachine()]);
      await tester.pumpWidget(host(PinsPage(store: store)));

      expect(find.text('relay.example.com'), findsOneWidget);
      expect(find.textContaining('a1b2c3d4e5f6'), findsOneWidget);
      expect(find.text('证书指纹 (SHA-256)'), findsOneWidget);
    });

    testWidgets('http 机器说明「无需 pin」且不显示指纹', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository(),
          seed: [machineFrom(mintTestUrl(relay: 'http://127.0.0.1:8080'))]);
      await tester.pumpWidget(host(PinsPage(store: store)));

      expect(find.text('http 链路，无需 pin'), findsOneWidget);
      expect(find.text('证书指纹 (SHA-256)'), findsNothing);
    });

    testWidgets('只读：没有删除 pin 的入口（删 pin 需在电脑上重配）', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository(),
          seed: [pinnedMachine()]);
      await tester.pumpWidget(host(PinsPage(store: store)));

      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.text('吊销'), findsNothing);
      // 明确说明只读的理由，而不是留一个没有出口的死页面。
      expect(find.textContaining('只读'), findsOneWidget);
    });
  });

  group('屏 G · 语言页', () {
    testWidgets('中文 / English 二选一', (tester) async {
      final locale = LocaleStore(storage: MemStorage());
      await tester.pumpWidget(host(LanguagePage(store: locale)));

      expect(find.text('中文'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('当前生效语言反映真实 locale（宿主是 zh 时显示中文）', (tester) async {
      final locale = LocaleStore(storage: MemStorage());
      await tester
          .pumpWidget(host(LanguagePage(store: locale), locale: const Locale('zh')));
      expect(find.textContaining('当前生效：中文'), findsOneWidget);
    });

    testWidgets('选 English 会持久化，重开后保持选中', (tester) async {
      final storage = MemStorage();
      final locale = LocaleStore(storage: storage);
      await locale.hydrate();
      await tester.pumpWidget(host(LanguagePage(store: locale)));

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(locale.notifier.value?.languageCode, 'en');

      // 重开一个 store 指向同一份存储：偏好必须活过进程。
      final reopened = LocaleStore(storage: storage);
      await reopened.hydrate();
      expect(reopened.notifier.value?.languageCode, 'en');
    });
  });

  group('屏 G · 关于页', () {
    testWidgets('版本 / 协议 / 许可 / 源码四项都在', (tester) async {
      await tester.pumpWidget(host(const AboutPage()));

      expect(find.text('App 版本'), findsOneWidget);
      expect(find.text('隧道协议版本'), findsOneWidget);
      expect(find.text('许可'), findsOneWidget);
      expect(find.text('源码'), findsOneWidget);
    });

    testWidgets('版本号来自常量，不在页面里写死', (tester) async {
      await tester.pumpWidget(host(const AboutPage()));

      expect(find.text(kAppVersion), findsOneWidget);
      expect(find.text('$kTunnelProtocolVersion'), findsOneWidget);
      expect(find.text(kLicense), findsOneWidget);
      expect(find.text(kSourceRepository), findsOneWidget);
    });
  });

  group('屏 G · 英文界面（i18n 不是摆设）', () {
    testWidgets('合规声明在 en 下也成立——它之前只对中文用户可见', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository());
      final settings = SettingsStore(storage: MemStorage());
      await tester.pumpWidget(host(
        SettingsPage(store: store, settings: settings),
        locale: const Locale('en'),
      ));

      expect(
        find.textContaining('Zero telemetry'),
        findsOneWidget,
        reason: '这是全 App 唯一的常驻合规声明，英文用户同样必须看到',
      );
    });

    testWidgets('三个二级页在 en 下不出中文', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository(),
          seed: [pinnedMachine()]);
      await tester.pumpWidget(host(
        PinsPage(store: store),
        locale: const Locale('en'),
      ));
      expect(find.text('relay.example.com'), findsOneWidget);
      expect(find.text('Certificate fingerprint (SHA-256)'), findsOneWidget);

      await tester.pumpWidget(host(
        const AboutPage(),
        locale: const Locale('en'),
      ));
      expect(find.text('Tunnel protocol version'), findsOneWidget);
      expect(find.text(kAppVersion), findsOneWidget);
    });

    testWidgets('语言页在 en 下把「当前生效」如实报成 English', (tester) async {
      final locale = LocaleStore(storage: MemStorage());
      await tester.pumpWidget(host(LanguagePage(store: locale),
          locale: const Locale('en')));
      expect(find.textContaining('In effect now: English'), findsOneWidget);
    });
  });

  group('屏 G · 导航接线', () {
    /// 不能用 `tester.pageBack()`：它找的是英文 'Back' tooltip（或
    /// CupertinoBackButton），而宿主跑在 zh locale 下，AppBar 的返回按钮
    /// tooltip 是本地化过的。这里直接点 Material 的返回按钮，等价于用户操作。
    Future<void> back(WidgetTester tester) async {
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }

    testWidgets('三个 navTile 都能点进去（不再是空壳）', (tester) async {
      final store = MachinesStore(repo: InMemoryMachinesRepository(),
          seed: [pinnedMachine()]);
      final settings = SettingsStore(storage: MemStorage());
      final locale = LocaleStore(storage: MemStorage());
      await tester.pumpWidget(host(SettingsPage(
        store: store,
        settings: settings,
        localeStore: locale,
      )));

      await tester.tap(find.text('证书锁定 (TOFU)'));
      await tester.pumpAndSettle();
      expect(find.byType(PinsPage), findsOneWidget);
      expect(find.text('relay.example.com'), findsOneWidget);

      await back(tester);

      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePage), findsOneWidget);

      await back(tester);

      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
    });
  });
}
