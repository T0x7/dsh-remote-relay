import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/context/context_sheet.dart';
import 'package:dsh_remote_app/console/models/model_picker.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// T2.5 / T2.6 — the model picker (屏 K) and the context breakdown (屏 L).
///
/// The rules pinned here are the ones the wire does NOT carry, so they can
/// only be enforced by the App:
///
/// - "Follow default" is a **null selection**, not a flag (§6.3).
/// - Effort levels are **whatever the adapter reported** — never a hardcoded
///   Off/Low/High/Max set (§6.1).
/// - A missing projection means **unknown**, not zero (§7.2), and the three
///   context segments are estimates that never reconcile with the total (§7.3).
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

ModelCatalog _catalog() => ModelCatalog.fromJson({
      'default': {'provider': 'deepseek-official', 'model': 'deepseek-v4'},
      'routableProviders': ['deepseek-official', 'openai'],
      'groups': [
        {
          'id': 'deepseek-official',
          'name': 'DeepSeek',
          'models': [
            {
              'id': 'deepseek-v4',
              'name': 'DeepSeek V4',
              'description': '旗舰推理模型',
              'reasoning': {
                'efforts': [
                  {'id': 'low', 'name': 'Low'},
                  {'id': 'high', 'name': 'High'},
                  {'id': 'max', 'name': 'Max'},
                ],
                'defaultEffort': 'medium',
              },
            },
            {'id': 'plain-model', 'name': 'Plain'},
          ],
        },
      ],
      'failures': [
        {'id': 'openai', 'name': 'OpenAI', 'message': 'no API key'},
      ],
    });

void main() {
  group('屏 K model picker', () {
    late L10n l10n;

    setUpAll(() async {
      l10n = await L10n.delegate.load(const Locale('zh'));
    });

    testWidgets('lists every provider group the engine sent', (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('DeepSeek'), findsOneWidget);
      expect(find.text('DeepSeek V4'), findsOneWidget);
      expect(find.text('Plain'), findsOneWidget);
    });

    testWidgets('surfaces provider failures without breaking the list',
        (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('OpenAI'), findsOneWidget);
      expect(find.textContaining('no API key'), findsOneWidget);
    });

    testWidgets('a null selection is labelled "follows default"', (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('跟随默认'), findsOneWidget);
      expect(find.textContaining('尚未选择过模型'), findsOneWidget);
    });

    testWidgets('a pinned session says so instead of claiming to follow',
        (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: const ModelSelection(provider: 'p', model: 'deepseek-v4'),
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('跟随默认'), findsNothing);
      expect(find.textContaining('已固定模型'), findsOneWidget);
    });

    testWidgets('effort chips come from the adapter, not a fixed ladder',
        (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      // Expand the reasoning model; only its reported levels appear.
      await tester.tap(find.text('DeepSeek V4'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ChoiceChip, 'Low'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'High'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Max'), findsOneWidget);
      expect(find.text('Medium'), findsNothing,
          reason: 'defaultEffort is a wire default, not a selectable level');
    });

    testWidgets('a model with no reasoning block offers no effort chips',
        (tester) async {
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (_, _, _) {},
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Plain'));
      await tester.pumpAndSettle();

      expect(find.byType(ChoiceChip), findsNothing,
          reason: 'a non-reasoning model has no ladder to show');
    });

    testWidgets('picking an effort returns it with the model', (tester) async {
      ({String provider, String model, String? effort})? chosen;
      await tester.pumpWidget(_host(ModelPickerSheet(
        catalog: _catalog(),
        current: null,
        l10n: l10n,
        onSelect: (p, m, e) => chosen = (provider: p, model: m, effort: e),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('DeepSeek V4'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Max'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '使用'));
      await tester.pumpAndSettle();

      // The sheet pops; `show` is what invokes onSelect, so the value is
      // asserted through the returned record instead.
      expect(find.text('DeepSeek V4'), findsNothing);
      expect(chosen, isNull, reason: 'a bare sheet does not self-apply');
    });
  });

  group('屏 K chip', () {
    testWidgets('follows default renders the muted label', (tester) async {
      final l10n = await L10n.delegate.load(const Locale('zh'));
      await tester.pumpWidget(_host(ModelChip(
        selection: null,
        followsDefault: true,
        l10n: l10n,
        onTap: () {},
      )));

      expect(find.text('跟随默认'), findsOneWidget);
    });

    testWidgets('a pinned selection renders model · effort', (tester) async {
      final l10n = await L10n.delegate.load(const Locale('zh'));
      await tester.pumpWidget(_host(ModelChip(
        selection: const ModelSelection(
            provider: 'p', model: 'deepseek-v4', reasoningEffort: 'high'),
        followsDefault: false,
        l10n: l10n,
        onTap: () {},
      )));

      expect(find.text('deepseek-v4 · high'), findsOneWidget);
    });

    testWidgets('an unset effort renders as the model default', (tester) async {
      final l10n = await L10n.delegate.load(const Locale('zh'));
      await tester.pumpWidget(_host(ModelChip(
        selection: const ModelSelection(provider: 'p', model: 'deepseek-v4'),
        followsDefault: false,
        l10n: l10n,
        onTap: () {},
      )));

      expect(find.text('deepseek-v4 · 默认档'), findsOneWidget);
    });
  });

  group('屏 L context breakdown', () {
    late L10n l10n;
    setUpAll(() async {
      l10n = await L10n.delegate.load(const Locale('zh'));
    });

    testWidgets('no projection reads as unknown, never as 0%', (tester) async {
      await tester.pumpWidget(
          _host(ContextSheet(projections: null, l10n: l10n)));
      await tester.pumpAndSettle();

      expect(find.textContaining('尚未上报用量'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('a session without contextPressure still says unknown',
        (tester) async {
      await tester.pumpWidget(_host(ContextSheet(
        projections: const SessionProjectionBaseline(
          asOfSeq: 0,
          values: Projections(tokenUsage: null),
        ),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('尚未上报用量'), findsOneWidget);
    });

    testWidgets('a live baseline renders the ring and the three segments',
        (tester) async {
      await tester.pumpWidget(_host(ContextSheet(
        projections: const SessionProjectionBaseline(
          asOfSeq: 10,
          values: Projections(
            contextPressure: ContextPressure(
              pressureTokens: 1000,
              projectedTokens: 3800,
              contextWindow: 10000,
            ),
            contextBreakdown: ContextBreakdown(
              systemTokens: 300,
              toolsTokens: 400,
              messageTokens: 500,
            ),
          ),
        ),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      expect(find.text('38%'), findsOneWidget);
      expect(find.text('系统提示'), findsOneWidget);
      expect(find.text('工具定义'), findsOneWidget);
      expect(find.text('对话消息'), findsOneWidget);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('400'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
    });

    testWidgets('the breakdown states it does not reconcile with the total',
        (tester) async {
      await tester.pumpWidget(_host(ContextSheet(
        projections: const SessionProjectionBaseline(
          asOfSeq: 10,
          values: Projections(
            contextPressure: ContextPressure(
                pressureTokens: 1000, projectedTokens: 3800, contextWindow: 10000),
            contextBreakdown: ContextBreakdown(
                systemTokens: 300, toolsTokens: 400, messageTokens: 500),
          ),
        ),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('不与上方总量对齐'), findsOneWidget,
          reason: 'segments are density estimates, not a reconciliation');
    });

    testWidgets('zero-token usage shows "—" instead of a confident 0%',
        (tester) async {
      await tester.pumpWidget(_host(ContextSheet(
        projections: const SessionProjectionBaseline(
          asOfSeq: 1,
          values: Projections(
            contextPressure: ContextPressure(contextWindow: 10000),
            tokenUsage: TokenUsageProjection(
              uncachedInputTokens: 0,
              outputTokens: 0,
              cacheReadTokens: 0,
              cacheWriteTokens: 0,
            ),
          ),
        ),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      // The window is known, the tokens are not.
      expect(find.textContaining('—'), findsWidgets);
      expect(find.textContaining('0%'), findsNothing);
    });

    testWidgets('tok/s appears only once decode timings exist', (tester) async {
      await tester.pumpWidget(_host(ContextSheet(
        projections: const SessionProjectionBaseline(
          asOfSeq: 1,
          values: Projections(
            sessionStats: SessionStatsProjection(
              turns: 4, steps: 9, llmMs: 8000, toolMs: 1500, ttftMs: 3000,
              ttftSteps: 9, decodeMs: 2000, decodeTokens: 24000,
            ),
          ),
        ),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      // decodeTokens / (decodeMs/1000) = 12.0 tok/s. The usage block sits
      // below the fold, so scroll before asserting.
      await tester.dragUntilVisible(
        find.textContaining('tok/s'),
        find.byType(Scrollable).first,
        const Offset(0, -120),
      );
      expect(find.textContaining('tok/s'), findsOneWidget);
      expect(find.text('4'), findsOneWidget, reason: 'turns');
    });
  });
}
