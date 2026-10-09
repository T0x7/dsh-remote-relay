import 'package:dsh_remote_app/console/console_page.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-085 — the five-tab bar has to survive a narrow phone in English.
///
/// 真机 L3 实证：英文下 "Workspace" 在格子宽度里换行成 "Workspac / e"，
/// 把整条 tab 栏撑高了一行——于是你正要点的那个 tab 在你点下去的瞬间
/// 往下挪了，而中文（「工作区」两个字）永远碰不到这个边界，所以这个洞
/// 只在英文界面显形。
Widget _host(Widget child, Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

/// The console keeps live timers, so `pumpAndSettle` never returns (D-032).
Future<void> settle(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

MachinesStore _seededStore() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return MachinesStore(
    repo: InMemoryMachinesRepository(),
    seed: [
      MachineEntry(
        id: 'relay-session',
        name: 'test-mini',
        firstPairedMs: now,
        params: SignedUrlParams(
          relayOrigin: Uri.parse('http://127.0.0.1:8080'),
          sessionId: 'relay-session',
          hash: 'h',
          mid: 'm',
          tMs: now,
          expMs: now + 3600 * 1000,
        ),
      ),
    ],
  );
}

/// Height of the rendered label — a wrapped label is roughly twice as tall as
/// a scaled-down single-line one, which is exactly the difference we care about.
double _labelHeight(WidgetTester tester, String label) =>
    tester.getSize(find.text(label).first).height;

void main() {
  testWidgets('D-085: 英文段栏五个 tab 都是单行', (tester) async {
    // A small-but-real phone width (Pixel-class), where the bar is tightest.
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);

    await tester.pumpWidget(_host(
      ConsolePage(store: _seededStore(), gatewayFactory: (_) => gateway),
      const Locale('en'),
    ));
    await settle(tester);

    // "Workspace" is the longest label and the one that used to wrap; every
    // tab is asserted so a future translation cannot silently reintroduce it.
    for (final label in const [
      'Chat',
      'Tasks',
      'Host',
      'Workspace',
      'Trace',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'segment $label renders');
      expect(_labelHeight(tester, label), lessThan(20),
          reason: '"$label" must stay on one line — a wrapped label makes the '
              'bar taller and moves the tab out from under the finger');
    }
  });

  testWidgets('D-085: 英文段栏与中文段栏等高（文案长短不该改变布局）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<double> barHeight(Locale locale, String firstLabel) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);
      await tester.pumpWidget(_host(
        ConsolePage(store: _seededStore(), gatewayFactory: (_) => gateway),
        locale,
      ));
      await settle(tester);
      // The label's own box is a faithful proxy for the bar: it is what grows
      // when a line wraps.
      return _labelHeight(tester, firstLabel);
    }

    final en = await barHeight(const Locale('en'), 'Chat');
    final zh = await barHeight(const Locale('zh'), '对话');

    // Chinese needs no shrink; English may shrink a little. A wrapped label
    // would be ~2× taller, so this bounds the damage without pinning pixels.
    expect(en, lessThan(zh * 1.5));
  });
}