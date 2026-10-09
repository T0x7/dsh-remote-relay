import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/error_copy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The App renders zero hardcoded copy: every [ErrorCode] resolves to an intl
/// resource. A code with no resource is not a compile error — it is a missing
/// string at runtime, in that language only — so the linkage is pinned here.
///
/// This is the test that would have caught the eight T2.1d console codes
/// landing without their zh/en entries.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late L10n zh;
  late L10n en;

  setUpAll(() async {
    zh = await L10n.delegate.load(const Locale('zh'));
    en = await L10n.delegate.load(const Locale('en'));
  });

  test('every ErrorCode has copy in both languages', () {
    // The switch in `errorCopy` is exhaustive, so this also proves the switch
    // itself compiles for every variant.
    for (final code in ErrorCode.values) {
      for (final l10n in [zh, en]) {
        final text = errorCopy(AppError(code), l10n);
        expect(text, isNotEmpty, reason: '${code.id} has no ${l10n.localeName} copy');
      }
    }
  });

  test('zh and en are genuinely different documents', () {
    var translated = 0;
    for (final code in ErrorCode.values) {
      if (errorCopy(AppError(code), zh) != errorCopy(AppError(code), en)) {
        translated++;
      }
    }
    expect(translated, greaterThanOrEqualTo(ErrorCode.values.length - 2),
        reason: 'zh/en copy look like the same text — a paste slipped through');
  });

  test('no copy leaks a raw wire code as the primary wording', () {
    // The engine's `code` reaches the UI only through the mono fallback line.
    // Match the namespaced wire form (`session/not-found`), not a bare slash —
    // Chinese copy legitimately uses `/` as a separator.
    final wireCode = RegExp(r'\b[a-z]+[a-z-]*/[a-z-]+\b');
    for (final code in ErrorCode.values) {
      for (final l10n in [zh, en]) {
        final text = errorCopy(AppError(code), l10n);
        expect(wireCode.hasMatch(text), isFalse,
            reason: '${code.id} copy looks like a raw wire code: $text');
      }
    }
  });

  test('copy fits the card or banner it renders in', () {
    for (final code in ErrorCode.values) {
      for (final l10n in [zh, en]) {
        expect(errorCopy(AppError(code), l10n).length, lessThanOrEqualTo(90),
            reason: '${code.id} copy is too long for its presentation');
      }
    }
  });

  group('detail line is the mono fallback, never the primary copy', () {
    test('joins the raw engine code and its message', () {
      const error = AppError(
        ErrorCode.modelUnavailable,
        rawMessage: 'session/model-unavailable',
        detail: 'deepseek-v4 is not routable',
      );
      expect(errorDetailLine(error),
          'session/model-unavailable · deepseek-v4 is not routable');
    });

    test('is null when there is nothing to add', () {
      expect(errorDetailLine(const AppError(ErrorCode.networkUnreachable)), isNull);
      expect(errorDetailLine(const AppError(ErrorCode.authExpired, detail: '')),
          isNull);
    });
  });

  group('cancellation is suppressed rather than rendered', () {
    test('an engine cancel is silent', () {
      final error = const EngineRemoteError(code: 'gateway/cancelled', message: '')
          .toAppError();
      expect(isSilentError(error), isTrue);
    });

    test('a real failure is not silent', () {
      final error = const EngineRemoteError(code: 'session/not-found', message: '')
          .toAppError();
      expect(isSilentError(error), isFalse);
    });
  });

  test('an engine failure renders the app copy plus the raw code beneath', () {
    final error = const EngineRemoteError(
      code: 'subagent/not-resumable',
      message: 'child is one-shot',
    ).toAppError();

    expect(errorCopy(error, zh), zh.err_subagent_read_only);
    expect(errorDetailLine(error), contains('subagent/not-resumable'),
        reason: 'a bug report must carry the real identifier');
  });
}
