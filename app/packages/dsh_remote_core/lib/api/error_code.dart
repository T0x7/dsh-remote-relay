/// Unified error object model (design §7.2) — the ONLY thing UI renders.
///
/// Mapping rules (pinned by table-driven tests):
/// - HTTP 401 → `auth.*` (three-cause local disambiguation via SessionClock)
/// - HTTP 429 → `ratelimit.hit`
/// - relay `error` frames → direct code mapping (`engine_down`,
///   `payload_too_large`, `concurrency_exceeded`)
/// - TLS/timeout/DNS → `network.*` (certificate-pin mismatch → `tls.certChanged`)
/// - local → `pair.*` / `renew.*` / `storage.*`
/// - unknown engine errors → `engine.unknown` (never silent; raw message kept)
library;

/// Presentation layer (design §7.2 ①): decides the widget family.
enum ErrorPresentation {
  /// L1 full-screen page — must act to proceed (red family).
  fullScreen,

  /// L2 inline card — handled in context (approval/task-failure style).
  inlineCard,

  /// L3 banner — auto-recovering; amber family; disappears on recovery.
  banner,

  /// L4 snackbar — light feedback, auto-dismisses.
  snackbar,
}

/// Retry policy attached to every code.
enum RetryPolicy {
  /// Automatic with exponential backoff.
  autoBackoff,

  /// Automatic, queued behind the concurrency cap.
  autoQueued,

  /// Manual retry button.
  manual,

  /// No retry — user action required (or nothing to retry).
  none,
}

/// The app-wide error code. Namespaced `family.detail`, stable string ids —
/// these ARE the contract between network layer, UI and intl resources.
enum ErrorCode {
  networkUnreachable('network.unreachable'),
  tlsCertChanged('tls.cert_changed'),
  authExpired('auth.expired'),
  authRevoked('auth.revoked'),
  authMaxAge('auth.max_age'),
  authMissing('auth.missing'),
  ratelimitHit('ratelimit.hit'),
  engineDown('engine.down'),
  payloadTooLarge('payload_too_large'),
  concurrencyExceeded('concurrency_exceeded'),
  apiPrivileged('api.privileged'),
  wsDeviceReplaced('ws.device_replaced'),
  pairQrInvalid('pair.qr_invalid'),
  renewFailed('renew.failed'),
  storageError('storage.error'),
  engineUnknown('engine.unknown'),

  // --- M2 console domain (T2.1d) ------------------------------------------
  // Engine business failures that carry a distinct, user-actionable meaning.
  // Everything NOT listed here falls back to [engineUnknown] with the raw
  // engine code preserved in `rawMessage` — the App never invents wording for
  // a code it has not been taught.

  /// The addressed session / child / job does not exist — typically deleted
  /// from the other end. `session/not-found` and friends.
  engineSessionGone('engine.session_gone'),

  /// Another client holds the writer lock for this session. This is the
  /// **two-ends relay** case, not a fault: the web UI is mid-edit.
  sessionWriterHeld('session.writer_held'),

  /// The agent owns the target (a subagent child addressed as a plain
  /// session). `session/agent-busy`.
  sessionAgentBusy('session.agent_busy'),

  /// A subagent refuses input: one-shot terminal, parent offline, or
  /// unauthorized. The console hides the composer for these, so this is a
  /// backstop rather than the primary signal.
  subagentReadOnly('subagent.read_only'),

  /// The selected model or its provider credentials are gone.
  modelUnavailable('model.unavailable'),

  /// This engine build does not expose the requested method — an App/engine
  /// version skew, not a transient fault.
  engineUnsupported('engine.unsupported'),

  /// The engine is up but a dependency is not; usually self-recovering.
  engineUnavailable('engine.unavailable'),
  engineTimeout('engine.timeout'),

  /// The call was cancelled (user action, reconnect, or stream teardown).
  /// Carries a code so the UI can **suppress** it instead of rendering noise.
  engineCancelled('engine.cancelled');

  const ErrorCode(this.id);
  final String id;

  /// L10n resource key: `err.<id with dots → underscores>` in en/zh arb files.
  String get l10nKey => 'err_${id.replaceAll('.', '_')}';
}

/// The single error object the UI consumes.
class AppError implements Exception {
  const AppError(
    this.code, {
    this.detail,
    this.rawMessage,
    this.retryAfter,
    this.limit,
  });

  final ErrorCode code;

  /// Short machine-readable context (e.g. relay hint, frame message).
  final String? detail;

  /// Original upstream message for the mono fallback line — NEVER shown as the
  /// primary copy (three-段式 contract), never contains credentials (network
  /// layer must sanitize before construction).
  final String? rawMessage;

  /// For `ratelimit.hit` / backoff consumers, when known.
  final Duration? retryAfter;
  final int? limit;

  ErrorPresentation get presentation => switch (code) {
        ErrorCode.tlsCertChanged ||
        ErrorCode.authExpired ||
        ErrorCode.authRevoked ||
        ErrorCode.authMaxAge ||
        ErrorCode.storageError =>
          ErrorPresentation.fullScreen,
        ErrorCode.apiPrivileged ||
        ErrorCode.pairQrInvalid ||
        ErrorCode.engineUnknown ||
        ErrorCode.engineSessionGone ||
        ErrorCode.sessionWriterHeld ||
        ErrorCode.sessionAgentBusy ||
        ErrorCode.subagentReadOnly ||
        ErrorCode.modelUnavailable ||
        ErrorCode.engineUnsupported =>
          ErrorPresentation.inlineCard,
        ErrorCode.networkUnreachable ||
        ErrorCode.engineDown ||
        ErrorCode.wsDeviceReplaced ||
        ErrorCode.renewFailed ||
        // D-039: 504 is the same user-facing situation as 503 — the engine is
        // not answering right now — so it rides the same banner.
        ErrorCode.engineUnavailable ||
        ErrorCode.engineTimeout =>
          ErrorPresentation.banner,
        ErrorCode.ratelimitHit ||
        ErrorCode.payloadTooLarge ||
        ErrorCode.concurrencyExceeded ||
        ErrorCode.authMissing ||
        ErrorCode.engineCancelled =>
          ErrorPresentation.snackbar,
      };

  RetryPolicy get retry => switch (code) {
        ErrorCode.networkUnreachable => RetryPolicy.autoBackoff,
        ErrorCode.ratelimitHit => RetryPolicy.autoBackoff,
      // A 504 is our own ceiling, not a rejection: retrying is the whole point.
      ErrorCode.engineTimeout => RetryPolicy.autoBackoff,
        ErrorCode.concurrencyExceeded => RetryPolicy.autoQueued,
        ErrorCode.renewFailed => RetryPolicy.autoBackoff,
        ErrorCode.wsDeviceReplaced => RetryPolicy.autoBackoff,
        ErrorCode.engineUnavailable => RetryPolicy.autoBackoff,
        ErrorCode.sessionWriterHeld => RetryPolicy.autoBackoff,
        ErrorCode.engineDown ||
        ErrorCode.payloadTooLarge ||
        ErrorCode.pairQrInvalid =>
          RetryPolicy.manual,
        _ => RetryPolicy.none,
      };

  @override
  String toString() => 'AppError(${code.id}${detail != null ? ', $detail' : ''})';
}

/// Map an HTTP status (+ optional body hint) to an AppError.
///
/// 401 is NOT disambiguated here — the caller folds in SessionClock's
/// three-cause verdict (design §4.1/§7.2): pass [authCause] when status is 401.
AppError mapHttpError(
  int status, {
  String? body,
  AuthCause? authCause,
  int? retryAfterSeconds,
}) {
  switch (status) {
    case 401:
      final cause = authCause ?? AuthCause.unknown;
      return AppError(switch (cause) {
        AuthCause.expired => ErrorCode.authExpired,
        AuthCause.revoked => ErrorCode.authRevoked,
        AuthCause.maxAge => ErrorCode.authMaxAge,
        AuthCause.unknown => ErrorCode.authMissing,
      }, detail: 'http 401', rawMessage: body);
    case 403:
      return AppError(ErrorCode.apiPrivileged,
          detail: 'http 403', rawMessage: body);
    case 503:
      return AppError(ErrorCode.engineUnavailable,
          detail: 'http 503', rawMessage: body);
    case 504:
      // D-039: 504 is the relay'''s own ceiling for a slow-but-healthy engine
      // (server WSS_PROXY_TIMEOUT_MS = 30s), and it means "retry later", not
      // "something unknown". Folding it into engineUnknown is what made a
      // busy engine read as a mystery instead of a wait.
      return AppError(ErrorCode.engineTimeout,
          detail: 'http 504', rawMessage: body);
    case 429:
      return AppError(ErrorCode.ratelimitHit,
          detail: 'http 429',
          retryAfter: retryAfterSeconds == null
              ? null
              : Duration(seconds: retryAfterSeconds));
    default:
      return AppError(ErrorCode.engineUnknown,
          detail: 'http $status', rawMessage: body);
  }
}

/// Map a relay tunnel `error` frame code to an AppError.
AppError mapRelayFrameError(String frameCode, {String? message}) =>
    AppError(switch (frameCode) {
      'engine_down' => ErrorCode.engineDown,
      'payload_too_large' => ErrorCode.payloadTooLarge,
      'concurrency_exceeded' => ErrorCode.concurrencyExceeded,
      _ => ErrorCode.engineUnknown,
    }, detail: frameCode, rawMessage: message);

/// Map a transport-level failure to an AppError.
///
/// [certificatePinMismatch] is decided by the pinning layer (TOFU table miss);
/// everything else connection-shaped collapses to `network.unreachable`.
AppError mapTransportError(Object error, {bool certificatePinMismatch = false}) {
  if (certificatePinMismatch) {
    return AppError(ErrorCode.tlsCertChanged, detail: 'tofu pin mismatch');
  }
  return AppError(ErrorCode.networkUnreachable,
      rawMessage: error.toString());
}

/// The SessionClock three-cause verdict (see session_clock.dart).
enum AuthCause { expired, revoked, maxAge, unknown }
