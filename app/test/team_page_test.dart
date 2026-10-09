import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/team/team_page.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// T2.7 — the subagent team view (屏 N).
///
/// The assertions here are shaped by what the live engine actually sends,
/// measured 2026-10-02: catalog entries carry exactly `mode`, `label`, `id`,
/// `createdAt` — **no `activity`** — and `label` is a long description (median
/// 27 chars, max 64), not a short name. A screen that drew a per-child
/// "running" dot or truncated the label to one line would be fiction.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionProjectionBaseline _with(List<Map<String, dynamic>> entries) =>
    SessionProjectionBaseline(
      asOfSeq: 1,
      values: Projections(
        subagentCatalog: entries
            .map(SubagentCatalogEntry.fromJson)
            .toList(growable: false),
      ),
    );

void main() {
  late L10n l10n;
  setUpAll(() async {
    l10n = await L10n.delegate.load(const Locale('zh'));
  });

  testWidgets('an absent catalog says so, not "none"', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: const SessionProjectionBaseline(
          asOfSeq: 0, values: Projections()),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    // Absence is not an empty list — they mean different things.
    expect(find.text('该会话未提供子代理目录'), findsOneWidget);
  });

  testWidgets('an empty catalog is a real empty state', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with(const []),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('该会话还没有子代理'), findsOneWidget);
  });

  testWidgets('renders every child with its label and mode', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        {
          'id': 'c1',
          'createdAt': 1790921292457,
          'mode': 'continuable',
          'label': '盘中盯盘团队·实时热点新闻腿：news_scan 未判读快讯（≤90min 窗）',
        },
        {'id': 'c2', 'createdAt': 1790921507985, 'mode': 'one-shot'},
      ]),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('2 个子代理'), findsOneWidget);
    // A long label wraps rather than truncating to a name.
    expect(find.textContaining('实时热点新闻腿'), findsOneWidget);
    expect(find.text('可继续对话'), findsOneWidget);
    expect(find.text('终态 · 不可再派活'), findsOneWidget);
  });

  testWidgets('a one-shot child is marked read-only', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        {'id': 'c2', 'createdAt': 1, 'mode': 'one-shot'},
      ]),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('只读'), findsOneWidget);
  });

  testWidgets('a continuable child is not marked read-only', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        {
          'id': 'c1',
          'createdAt': 1,
          'mode': 'continuable',
          'label': 'researcher',
        },
      ]),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('只读'), findsNothing);
  });

  testWidgets('a child with no label falls back to its id', (tester) async {
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        {'id': 'child-abc', 'createdAt': 1, 'mode': 'continuable'},
      ]),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('child-abc'), findsOneWidget);
  });

  testWidgets('tapping a child hands the whole entry back', (tester) async {
    SubagentCatalogEntry? tapped;
    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        {
          'id': 'c1',
          'createdAt': 1,
          'mode': 'continuable',
          'label': 'researcher',
        },
      ]),
      l10n: l10n,
      onOpenChild: (child) => tapped = child,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('researcher'));
    expect(tapped?.id, 'c1');
    expect(tapped?.mode, SubagentMode.continuable);
    expect(tapped?.acceptsInput, isTrue);
  });

  testWidgets('an unknown-mode child is not offered as writable',
      (tester) async {
    // `unknown` means "read the history to find out" — the console must not
    // guess in the user's favour.
    final entry = SubagentCatalogEntry.fromJson(
        const {'id': 'c3', 'createdAt': 1, 'mode': 'unknown'});
    expect(entry.acceptsInput, isFalse);

    await tester.pumpWidget(_host(TeamPage(
      parentSessionId: 'p1',
      projections: _with([
        const {'id': 'c3', 'createdAt': 1, 'mode': 'unknown'},
      ]),
      l10n: l10n,
      onOpenChild: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('只读'), findsOneWidget);
  });
}
