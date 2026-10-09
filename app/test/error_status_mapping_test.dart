import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/error_copy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';


/// D-039 — a 5xx must not read as a mystery.
///
/// Seen on device: a busy engine made `session/list` time out, and the card
/// said **「引擎返回了未知错误」**. The wire said HTTP 504 the whole time — the
/// relay's own 30s ceiling for a slow-but-healthy engine
/// (`server/src/index.ts:875` `WSS_PROXY_TIMEOUT_MS`) — which is a *wait*, not
/// an unknown.
///
/// The fold happened twice: the RPC layer mapped every 5xx to
/// `gateway/internal`, and `fromHttpStatus` mapped everything unrecognised to
/// `ErrorCode.engineUnknown`, whose copy is literally "unknown error".
void main() {
  group('D-039 http status → code', () {
    test('504 is a timeout, not an unknown error', () {
      final error = mapHttpError(504);
      expect(error.code, ErrorCode.engineTimeout);
      expect(error.code, isNot(ErrorCode.engineUnknown));
    });

    test('503 is engine-unavailable, not an unknown error', () {
      expect(mapHttpError(503).code, ErrorCode.engineUnavailable);
    });

    test('401 keeps its three-cause contract', () {
      // 401 must not be swept into the 5xx arm: it is the auth gate, and the
      // caller supplies the cause that decides which auth copy is shown.
      expect(
        mapHttpError(401, authCause: AuthCause.maxAge).code,
        ErrorCode.authMaxAge,
      );
    });

    test('an unmapped 5xx still has somewhere honest to go', () {
      // 500 and friends remain `engineUnknown` — but that is now the residual
      // case rather than the one every 504 lands in.
      expect(mapHttpError(500).code, ErrorCode.engineUnknown);
    });

    test('a timeout auto-retries; an unknown error does not', () {
      // The whole point of naming 504: the App is expected to try again, so
      // the code has to carry that policy instead of asking the user.
      expect(mapHttpError(504).retry, RetryPolicy.autoBackoff);
    });
  });

  group('D-039 copy', () {
    late L10n l10n;

    setUp(() async {
      l10n = await L10n.delegate.load(const Locale('zh'));
    });

    test('the timeout has its own words', () {
      final copy = errorCopy(mapHttpError(504), l10n);
      expect(copy, isNot(l10n.err_engine_unknown),
          reason: 'a 504 must never render as "unknown error"');
      expect(copy, l10n.err_engine_timeout);
    });

    test('the mono line still carries the raw status for bug reports', () {
      final detail = errorDetailLine(mapHttpError(504));
      expect(detail, contains('504'));
    });
  });

  group('D-039 rpc code', () {
    test('the transport layer keeps 504 distinct from other 5xx', () {
      // Same regression at the other end: the RPC layer produced
      // `gateway/internal` for every 5xx, so even a correct downstream mapper
      // could not tell a timeout from a crash.
      expect(EngineRemoteError(code: 'engine.timeout', message: '').code,
          'engine.timeout');
    });
  });
}
