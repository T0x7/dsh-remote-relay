import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/services/update_checker.dart';
import 'package:dsh_remote_app/settings/about_info.dart';
import 'package:dsh_remote_app/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试内的假安全存储（与 settings_pages_test 同形；那边是文件私有类，复制一份）。
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
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      map[key] = value!;
}

/// 「点了检查更新没反应」——真机上被运维直接指出来的 UI 缺陷。
///
/// 第一版只有「发现新版」有反馈：已是最新版时副标题回落到默认文案、网络失败时
/// 被显示成「未检查」。两处都表现为**点了跟没点一样**，而且第二条比不显示更误导。
///
/// 这条守门钉的是「**每种结局都要有话说**」，不是某一句具体文案。
void main() {
  Widget host(SettingsStore settings) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: SettingsPage(
          store: MachinesStore(repo: InMemoryMachinesRepository()),
          settings: settings,
          localeStore: null,
          biometricGate: null,
        ),
      );

  SettingsStore store() => SettingsStore(storage: MemStorage());

  /// 「线上最高版本 == 本机版本」的 release 列表。
  ///
  /// 从 `kAppVersion` 派生而不是写死一个字符串：写死 `v0.0.1` 的话，哪天版本号
  /// 升到 1.0.0，这条用例会悄悄变成「发现新版」而**依然断言「已是最新」**——
  /// 一个恒真的假绿，比没有守门更坏。
  String upToDateReleases() =>
      '[{"tag_name":"v$kAppVersion","draft":false,'
      '"assets":[{"name":"app-arm64-v8a.apk",'
      '"browser_download_url":"https://example.com/a.apk","size":31897428}]}]';

  setUp(() {
    releaseFetcher = (uri) async => throw StateError('本用例不联网');
  });

  Future<void> tapCheck(WidgetTester tester) async {
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets('已是最新版 → 明确说「已是最新版本」，不能没反应',
      (tester) async {
    releaseFetcher = (uri) async => upToDateReleases();
    final settings = store();
    await tester.pumpWidget(host(settings));
    await tester.pumpAndSettle();
    await tapCheck(tester);

    expect(find.textContaining('已是最新版本'), findsWidgets,
        reason: '已是最新的结局必须有反馈——这是「点了没反应」的直接修复');
    expect(find.textContaining(kAppVersion), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget,
        reason: '副标题是小字、容易被当成没点；一次性反馈是这条守门的重点');
  });

  testWidgets('发现新版 → 显示版本号并弹出下载对话框', (tester) async {
    releaseFetcher = (uri) async => '''
[{"tag_name":"v9.9.9","draft":false,"body":"notes",
  "assets":[{"name":"app-arm64-v8a.apk",
             "browser_download_url":"https://example.com/a.apk","size":31897428}]}]
''';
    await tester.pumpWidget(host(store()));
    await tester.pumpAndSettle();
    await tapCheck(tester);

    expect(find.textContaining('9.9.9'), findsWidgets);
    expect(find.text('打开下载页'), findsOneWidget);
  });

  testWidgets('网络失败 → 显示真实原因，不能伪装成「未检查」',
      (tester) async {
    releaseFetcher = (uri) async => throw SocketException('连接超时');
    await tester.pumpWidget(host(store()));
    await tester.pumpAndSettle();
    await tapCheck(tester);

    expect(find.textContaining('检查失败'), findsWidgets);
    expect(find.textContaining('连接超时'), findsWidgets,
        reason: '失败原因要对用户可见；用「未检查」顶替是误导');
    expect(find.textContaining('未检查'), findsNothing);
  });

  testWidgets('返回的不是 JSON → 用 l10n 文案而不是 Dart 异常原文',
      (tester) async {
    // 限流 / 网关拦截 / 5xx HTML 错误页都落在这条路径上。`jsonDecode` 抛的
    // FormatException 带换行和插入符，原样 toString() 会把这种东西甩给用户。
    releaseFetcher = (uri) async => 'not json';
    await tester.pumpWidget(host(store()));
    await tester.pumpAndSettle();
    await tapCheck(tester);

    expect(find.textContaining('不是 JSON'), findsWidgets,
        reason: 'UpdateError.badJson 必须真的有生产者，否则这句词条永远用不上');
    expect(find.textContaining('FormatException'), findsNothing,
        reason: '异常原文不是给用户看的文案');
  });

  testWidgets('检查进行中 → 明确说「正在检查…」', (tester) async {
    final gate = Completer<String>();
    releaseFetcher = (uri) => gate.future;
    await tester.pumpWidget(host(store()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pump();

    expect(find.textContaining('正在检查'), findsWidgets,
        reason: '请求期间要有反馈，否则网络慢时和「点了没反应」无法区分');

    gate.complete(upToDateReleases());
    await tester.pumpAndSettle();
    expect(find.textContaining('正在检查'), findsNothing,
        reason: '结束后不能停在「正在检查…」');
  });
}