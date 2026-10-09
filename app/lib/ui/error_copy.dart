import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';

/// Resolve an [AppError] to its localized copy.
///
/// The error layer deliberately stops at codes: the network layer never
/// invents wording and the engine's `code` travels through untouched
/// (design §7.2). This is the one place the code becomes text.
///
/// The table is exhaustive over `ErrorCode`; `error_copy_linkage_test.dart`
/// fails if a code is added without a row, so the switch needs no default arm
/// returning raw code.
String errorCopy(AppError error, L10n l10n) =>
    switch (error.code) {
      ErrorCode.networkUnreachable => l10n.err_network_unreachable,
      ErrorCode.tlsCertChanged => l10n.err_tls_cert_changed,
      ErrorCode.authExpired => l10n.err_auth_expired,
      ErrorCode.authRevoked => l10n.err_auth_revoked,
      ErrorCode.authMaxAge => l10n.err_auth_max_age,
      ErrorCode.authMissing => l10n.err_auth_missing,
      ErrorCode.ratelimitHit => l10n.err_ratelimit_hit,
      ErrorCode.engineDown => l10n.err_engine_down,
      ErrorCode.payloadTooLarge => l10n.err_payload_too_large,
      ErrorCode.concurrencyExceeded => l10n.err_concurrency_exceeded,
      ErrorCode.apiPrivileged => l10n.err_api_privileged,
      ErrorCode.wsDeviceReplaced => l10n.err_ws_device_replaced,
      ErrorCode.pairQrInvalid => l10n.err_pair_qr_invalid,
      ErrorCode.renewFailed => l10n.err_renew_failed,
      ErrorCode.storageError => l10n.err_storage_error,
      ErrorCode.engineUnknown => l10n.err_engine_unknown,
      ErrorCode.engineSessionGone => l10n.err_engine_session_gone,
      ErrorCode.sessionWriterHeld => l10n.err_session_writer_held,
      ErrorCode.sessionAgentBusy => l10n.err_session_agent_busy,
      ErrorCode.subagentReadOnly => l10n.err_subagent_read_only,
      ErrorCode.modelUnavailable => l10n.err_model_unavailable,
      ErrorCode.engineUnsupported => l10n.err_engine_unsupported,
      ErrorCode.engineUnavailable => l10n.err_engine_unavailable,
      ErrorCode.engineCancelled => l10n.err_engine_cancelled,
      ErrorCode.engineTimeout => l10n.err_engine_timeout,
    };

/// The mono fallback line: the raw upstream code and message, shown only
/// beneath the human copy so a bug report carries the real identifier.
///
/// Never the primary copy — that is the three-段式 contract in design §7.2.
/// Returns null when there is nothing worth showing.
String? errorDetailLine(AppError error) {
  final parts = [error.rawMessage, error.detail]
      .where((part) => part != null && part.isNotEmpty)
      .map((part) => redactHomePath(part!))
      .toList(growable: false);
  return parts.isEmpty ? null : parts.join(' · ');
}

/// D-081: collapse the host account's home directory to `~`.
///
/// The privacy table (design §8) keeps the host for debugging, but a full
/// `/Users/<name>/…` path on a phone screen carries the account name and
/// nothing else is gained — the tail identifies the file. Live case: a
/// plugin switch failure printed a `/Users/someone/.dsh-host/dsh-home/
/// profiles/web/package.json.lock` straight onto the console.
String redactHomePath(String text) => text.replaceAll(
      RegExp(r'/Users/[^/\s]+(?=(/|\\))'),
      '~',
    );

/// Whether the UI should render this error at all.
///
/// A cancelled call is a normal outcome of reconnecting or of the user backing
/// out, not a failure; rendering it would be noise.
bool isSilentError(AppError error) => error.code == ErrorCode.engineCancelled;
