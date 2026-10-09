import 'dart:io';

import '../api/error_code.dart';
import '../log_hook.dart';
import 'tofu_pins.dart';

/// HttpClient whose TLS trust rides the TOFU pin table (design §8; the
/// mechanism proven by the M0 pinning tests).
///
/// `badCertificateCallback` is a SYNCHRONOUS contract, so decisions run on an
/// in-memory pin table (`pinTable`) — a handful of entries, materialized from
/// the persistent [TofuPinStore] at construction (the Flutter shell loads it
/// from `flutter_secure_storage`; tests hand over a `MemoryPinStore` table).
///
/// Verdicts:
/// - pin known + match    → proceed
/// - pin known + mismatch → reject (caller surfaces `tls.cert_changed`)
/// - no pin yet           → learn ONLY when [learnOnFirstConnect] (pairing
///                          flow); steady state fails closed — re-learning
///                          after pin loss must be a deliberate user action.
/// Learns are written back through [onLearn] for persistence.
///
/// `WebSocket.connect(url, customClient: ...)` routes wss handshakes through
/// the same callback (M0 实测③, D-003) — one table covers HTTP + WSS.
class PinnedHttpClient {
  PinnedHttpClient({
    required Map<String, String> pinTable,
    bool learnOnFirstConnect = false,
    void Function(String host, String sha256Hex)? onLearn,
    Duration? connectionTimeout = const Duration(seconds: 15),
  })  : _pinTable = pinTable,
        _learn = learnOnFirstConnect,
        _onLearn = onLearn {
    _http = HttpClient();
    _http.connectionTimeout = connectionTimeout;
    _http.badCertificateCallback = _onBadCertificate;
  }

  /// Convenience: build from a [MemoryPinStore] (tests / pre-pairing probes).
  PinnedHttpClient.fromStore(
    MemoryPinStore store, {
    bool learnOnFirstConnect = false,
  }) : this(
          pinTable: store.pins,
          learnOnFirstConnect: learnOnFirstConnect,
          onLearn: store.setPin,
        );

  final Map<String, String> _pinTable;
  final bool _learn;
  final void Function(String host, String sha256Hex)? _onLearn;
  final List<String> rejectedHosts = [];

  late final HttpClient _http;

  /// The raw client — pass to `WebSocket.connect(customClient:)` for wss.
  HttpClient get client => _http;

  bool _onBadCertificate(X509Certificate cert, String host, int port) {
    final fingerprint = fingerprintOfDer(cert.der);
    final pinned = _pinTable[host];
    switch (checkPin(pinned: pinned, fingerprint: fingerprint)) {
      case TofuVerdict.ok:
        return true;
      case TofuVerdict.learn:
        if (!_learn) {
          rejectedHosts.add(host);
          CoreLog.emit('warn', 'tofu',
              'unknown cert host=$host — fail closed (steady state, not pairing)');
          return false; // fail closed outside the pairing flow
        }
        _pinTable[host] = fingerprint;
        _onLearn?.call(host, fingerprint);
        CoreLog.emit('info', 'tofu',
            'pin learned host=$host sha256=${fingerprint.substring(0, 12)}…');
        return true;
      case TofuVerdict.mismatch:
        rejectedHosts.add(host);
        CoreLog.emit('error', 'tofu',
            'PIN MISMATCH host=$host — reject (tls.cert_changed path)');
        return false; // fail closed — tls.cert_changed path
    }
  }

  void close() => _http.close(force: true);
}

/// Transport-shaped failure classification helper: the HTTP client throws
/// `HandshakeException` for TLS rejects (pin mismatch lands here) and
/// `SocketException` for connect/timeout shapes.
AppError classifyTransportError(Object e,
    {required List<String> rejectedHosts}) {
  final pinRejected = rejectedHosts.isNotEmpty;
  return mapTransportError(e, certificatePinMismatch: pinRejected);
}
