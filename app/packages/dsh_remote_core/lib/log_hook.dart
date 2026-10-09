/// Zero-dependency log seam for the UI-free core (logging plan P3).
///
/// The core must not know about sinks, files or Flutter — so it only calls
/// [CoreLog.emit] at security- and lifecycle-relevant points (transport
/// failures, TOFU verdicts, the WS reconnect loop). The app shell installs
/// exactly one [CoreLog.sink] at startup (`main.dart`) that forwards into
/// `AppLog`. The default is a no-op, so every headless test keeps its current
/// behavior for free and the core package stays dependency-free.
///
/// Call-site discipline mirrors `server/src/logger.ts` ("identifiers, never
/// secrets"): log host, path, attempt counts — never bearer tokens, pairing
/// links or URL query strings. The app-side redactor is a seatbelt, not a
/// license to log secrets here.
library;

/// Severity of one core log line. Plain strings at the boundary so the core
/// stays free of the app's enum: `debug` | `info` | `warn` | `error`.
typedef CoreLogFn = void Function(String level, String tag, String message);

/// The process-wide core → app log bridge.
abstract final class CoreLog {
  /// Installed once by the app shell. Null (default) = discard.
  static CoreLogFn? sink;

  /// Emit one line. Swallows everything: logging must never break the
  /// network stack, and a broken sink must not take it down either.
  static void emit(String level, String tag, String message) {
    final fn = sink;
    if (fn == null) return;
    try {
      fn(level, tag, message);
    } catch (_) {
      // Seatbelt: a throwing sink is worse than no sink.
    }
  }
}
