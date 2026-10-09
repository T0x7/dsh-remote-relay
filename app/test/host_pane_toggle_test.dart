import 'package:dsh_remote_app/console/host/host_pane.dart';
import 'package:dsh_remote_app/console/inline_error_card.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-086 — a successful RPC is not proof of a changed engine.
///
/// 真机 L3 实证（2026-10-09）：`pluginManager/setBundleEnabled` 在引擎的写路径上
/// 永久挂死（curl 直连 120s 零响应；`package.json` 的 mtime 停在 Oct 4；引擎
/// 日志里连一条插件痕迹都没有——请求卡在网关层，压根没进业务逻辑）。可 App 的
/// 开关**翻成了「关」，而且没有任何错误提示**，直到切走再切回 Host 页才自愈。
///
/// 根因在 App 的判据：D-078 定的规则是「等引擎确认才翻转」，而「确认」被实现
/// 成了 `result.isOk`。但 `isOk` 会撒谎——引擎可以在什么都没做的情况下回 ok
/// （今天就是这样），于是 `_toggle` 走 else 分支，把本地 `enabled` 直接改成
/// 目标值当成既成事实。
///
/// 这与 D-078 修的是同一族病：乐观 UI 吞掉失败。区别只在于失败这次穿的是
/// 「成功」而不是「错误」，所以连错误卡都没有——比原版更隐蔽。
///
/// 修法不是「更聪明地猜引擎想说什么」，而是**以重读为准**：切换之后重新拉一次
/// `listBundles`，用引擎自己的答案刷新列表。它对真正成功的切换同样无害（重读
/// 回来的正是刚写的值），而对「说成功其实没做」是唯一可靠的判据。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// The switch rendered for [bundleName], whichever row it sits on.
Finder _switchFinder(String bundleName) {
  final row = find.ancestor(
    of: find.text(bundleName),
    matching: find.byType(Container),
  );
  return find.descendant(of: row.first, matching: find.byType(Switch));
}

Switch _switchFor(WidgetTester tester, String bundleName) =>
    tester.widget<Switch>(_switchFinder(bundleName));

void main() {
  late L10n l10n;
  setUpAll(() async {
    l10n = await L10n.delegate.load(const Locale('zh'));
  });

  testWidgets('D-086：引擎报 applied 但没真落地时，UI 必须以重读为准',
      (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(HostPane(
      gateway: gateway,
      machineName: 'mac-mini',
      sessions: const [],
      selection: null,
      l10n: l10n,
    )));
    await tester.pumpAndSettle();

    // Before: the switch reads `true` — the engine's own answer.
    expect(_switchFor(tester, 'dsh-remote-relay-plugin').value, isTrue);

    await tester.tap(_switchFinder('dsh-remote-relay-plugin'));
    await tester.pumpAndSettle();

    // The fake answers `ok` / `application: applied` — exactly what the real
    // engine answered while doing nothing — and `listBundles` still says
    // `enabled: true`. The App must therefore conclude that the change did NOT
    // land and say so, rather than showing a switch that quietly flipped.
    expect(
      find.byType(InlineErrorCard),
      findsOneWidget,
      reason: 'engine said applied, the re-read disagrees — that contradiction '
          'is the finding, and the user is the one who has to see it',
    );
    expect(
      _switchFor(tester, 'dsh-remote-relay-plugin').value,
      isTrue,
      reason: 'the roster is the source of truth: it never changed, so the '
          'switch must not claim it did',
    );
    expect(
      gateway.pluginManagerCalls.where((c) => c['call'] == 'listBundles'),
      hasLength(greaterThanOrEqualTo(2)),
      reason: 'the toggle must re-read instead of trusting the response',
    );
  });

  testWidgets('D-086：重读失败时把错误顶给用户，不让它看起来已安定',
      (tester) async {
    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(HostPane(
      gateway: gateway,
      machineName: 'mac-mini',
      sessions: const [],
      selection: null,
      l10n: l10n,
    )));
    await tester.pumpAndSettle();

    // The toggle call succeeds; the re-read that follows it does not. That is
    // the worst case for the user — they cannot learn the real state — so it
    // must not pass silently.
    var listCalls = 0;
    gateway.onPluginManagerList = () {
      listCalls++;
      if (listCalls >= 2) gateway.failPluginManager = true;
    };
    addTearDown(() => gateway.onPluginManagerList = null);

    await tester.tap(_switchFinder('dsh-remote-relay-plugin'));
    await tester.pumpAndSettle();

    expect(find.byType(InlineErrorCard), findsOneWidget,
        reason: 'an unverifiable state change must say so rather than look '
            'settled — this is the D-078 rule applied to the success path');
  });
}