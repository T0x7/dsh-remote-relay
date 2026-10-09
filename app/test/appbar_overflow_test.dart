import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/models/model_picker.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-038 — the console's app bar must survive a long machine and model name.
///
/// Found on device: with the machine chip reading `example-workstation.local` and
/// the model chip showing a real catalog entry, the row overflowed and Flutter
/// printed the striped "A RenderFlex overflowed" banner over the bar. Both
/// chips are `Row(mainAxisSize: MainAxisSize.min)` with an **unconstrained**
/// `Text`, so neither can shrink: the bar's width is the sum of two labels
/// that both refuse to ellipsize.
///
/// The fix is a constraint, not a shorter string — a model name is whatever
/// the engine's catalog says, and the machine name is whatever the host
/// reports.
Widget _host(Widget child, {Size size = const Size(360, 800)}) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(body: child),
      ),
    );

/// Mirrors the machine chip's shell: the app bar wraps each chip in a
/// , so this is the width the chip really gets.
class _ChipShell extends StatelessWidget {
  const _ChipShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Flexible(child: child), const Icon(Icons.arrow_drop_down, size: 16)],
        ),
      );
}

void main() {
  group('D-038 app bar chips fit', () {
    testWidgets('a long model name does not overflow the bar', (tester) async {
      late L10n l10n;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        l10n = L10n.of(context);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            title: Row(
              children: [
                Flexible(
                  child: _ChipShell(
                    child: const Text('example-workstation.local',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: ModelChip(
                    selection: ModelSelection(
                      provider: 'host-app engine',
                      model: 'claude-opus-4-6-thinking-extended',
                      reasoningEffort: 'max',
                    ),
                    followsDefault: false,
                    l10n: l10n,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        );
      })));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'the bar must lay out without an overflow');
    });

    testWidgets('a long machine name does not overflow the bar', (tester) async {
      late L10n l10n;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        l10n = L10n.of(context);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            title: Row(
              children: [
                Flexible(
                  child: _ChipShell(
                    child: const Text('a-very-long-machine-name-that-keeps-going.local',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: ModelChip(
                    selection: null,
                    followsDefault: true,
                    l10n: l10n,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        );
      })));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the model chip ellipsizes rather than pushing the bar',
        (tester) async {
      late L10n l10n;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        l10n = L10n.of(context);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            title: Row(
              children: [
                Flexible(
                  child: _ChipShell(
                      child: const Text('mini',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: ModelChip(
                    selection: ModelSelection(
                      provider: 'p',
                      model: 'an-extremely-long-model-identifier-for-testing',
                      reasoningEffort: 'high',
                    ),
                    followsDefault: false,
                    l10n: l10n,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        );
      })));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The label is clipped to one line, so the chip stays inside the bar.
      final text = tester.widget<Text>(find.descendant(
        of: find.byType(ModelChip),
        matching: find.byType(Text),
      ).first);
      expect(text.maxLines, isNotNull);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });
}
