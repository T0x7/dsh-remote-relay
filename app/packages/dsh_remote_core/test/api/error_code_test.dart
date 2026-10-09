import 'dart:io';

import 'package:dsh_remote_core/api/error_code.dart';
import 'package:test/test.dart';

/// §7.2 全表表驱动断言：code → 呈现层 → 重试策略，一行不许漂。
/// HTTP / relay 帧 / 传输层三映射函数的分支覆盖。
void main() {
  group('presentation & retry table (§7.2 ①③)', () {
    // (code, presentation, retry) — mirrors docs/app-design.md §7.2 table.
    const table = <(ErrorCode, ErrorPresentation, RetryPolicy)>[
      (ErrorCode.networkUnreachable, ErrorPresentation.banner, RetryPolicy.autoBackoff),
      (ErrorCode.tlsCertChanged, ErrorPresentation.fullScreen, RetryPolicy.none),
      (ErrorCode.authExpired, ErrorPresentation.fullScreen, RetryPolicy.none),
      (ErrorCode.authRevoked, ErrorPresentation.fullScreen, RetryPolicy.none),
      (ErrorCode.authMaxAge, ErrorPresentation.fullScreen, RetryPolicy.none),
      (ErrorCode.authMissing, ErrorPresentation.snackbar, RetryPolicy.none),
      (ErrorCode.ratelimitHit, ErrorPresentation.snackbar, RetryPolicy.autoBackoff),
      (ErrorCode.engineDown, ErrorPresentation.banner, RetryPolicy.manual),
      (ErrorCode.payloadTooLarge, ErrorPresentation.snackbar, RetryPolicy.manual),
      (ErrorCode.concurrencyExceeded, ErrorPresentation.snackbar, RetryPolicy.autoQueued),
      (ErrorCode.apiPrivileged, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.wsDeviceReplaced, ErrorPresentation.banner, RetryPolicy.autoBackoff),
      (ErrorCode.pairQrInvalid, ErrorPresentation.inlineCard, RetryPolicy.manual),
      (ErrorCode.renewFailed, ErrorPresentation.banner, RetryPolicy.autoBackoff),
      (ErrorCode.storageError, ErrorPresentation.fullScreen, RetryPolicy.none),
      (ErrorCode.engineUnknown, ErrorPresentation.inlineCard, RetryPolicy.none),
      // M2 console domain (T2.1d) — rows added with the codes themselves.
      (ErrorCode.engineSessionGone, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.sessionWriterHeld, ErrorPresentation.inlineCard, RetryPolicy.autoBackoff),
      (ErrorCode.sessionAgentBusy, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.subagentReadOnly, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.modelUnavailable, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.engineUnsupported, ErrorPresentation.inlineCard, RetryPolicy.none),
      (ErrorCode.engineUnavailable, ErrorPresentation.banner, RetryPolicy.autoBackoff),
      // D-039: a 504 is our own 30s ceiling, not a rejection — retry it.
      (ErrorCode.engineTimeout, ErrorPresentation.banner, RetryPolicy.autoBackoff),
      (ErrorCode.engineCancelled, ErrorPresentation.snackbar, RetryPolicy.none),
    ];

    test('every code matches the design table', () {
      // Table must be exhaustive: one row per enum value.
      expect(table.map((r) => r.$1).toSet(), ErrorCode.values.toSet());
      for (final (code, presentation, retry) in table) {
        final e = AppError(code);
        expect(e.presentation, presentation,
            reason: '${code.id} presentation drifted from §7.2');
        expect(e.retry, retry, reason: '${code.id} retry drifted from §7.2');
      }
    });

    test('stable ids are the intl contract', () {
      expect(ErrorCode.networkUnreachable.id, 'network.unreachable');
      expect(ErrorCode.wsDeviceReplaced.id, 'ws.device_replaced');
      expect(ErrorCode.authMaxAge.l10nKey, 'err_auth_max_age');
    });
  });

  group('mapHttpError', () {
    test('401 folds in the three-cause verdict', () {
      expect(mapHttpError(401, authCause: AuthCause.expired).code,
          ErrorCode.authExpired);
      expect(mapHttpError(401, authCause: AuthCause.revoked).code,
          ErrorCode.authRevoked);
      expect(mapHttpError(401, authCause: AuthCause.maxAge).code,
          ErrorCode.authMaxAge);
      expect(mapHttpError(401).code, ErrorCode.authMissing);
    });

    test('403 → api.privileged (engine PRIVILEGED fence)', () {
      expect(mapHttpError(403).code, ErrorCode.apiPrivileged);
    });

    test('429 carries retryAfter', () {
      final e = mapHttpError(429, retryAfterSeconds: 30);
      expect(e.code, ErrorCode.ratelimitHit);
      expect(e.retryAfter, const Duration(seconds: 30));
    });

    test('any other status → engine.unknown keeping raw body', () {
      final e = mapHttpError(500, body: '{"error":"boom"}');
      expect(e.code, ErrorCode.engineUnknown);
      expect(e.rawMessage, '{"error":"boom"}');
    });
  });

  group('mapRelayFrameError', () {
    test('known frame codes map directly', () {
      expect(mapRelayFrameError('engine_down').code, ErrorCode.engineDown);
      expect(mapRelayFrameError('payload_too_large').code,
          ErrorCode.payloadTooLarge);
      expect(mapRelayFrameError('concurrency_exceeded').code,
          ErrorCode.concurrencyExceeded);
    });

    test('unknown frame code → engine.unknown with raw message kept', () {
      final e = mapRelayFrameError('new_future_code', message: 'details');
      expect(e.code, ErrorCode.engineUnknown);
      expect(e.rawMessage, 'details');
    });
  });

  group('mapTransportError', () {
    test('pin mismatch is special-cased (TOFU fail-closed)', () {
      expect(mapTransportError(const SocketException('x'),
              certificatePinMismatch: true)
          .code, ErrorCode.tlsCertChanged);
    });

    test('everything connection-shaped collapses to network.unreachable', () {
      expect(mapTransportError(const SocketException('refused')).code,
          ErrorCode.networkUnreachable);
    });
  });
}
