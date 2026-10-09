import 'dart:io';

import 'package:crypto/crypto.dart';

/// TOFU certificate-pin store (design §8 传输层) — the persistent
/// implementation lands with the Flutter shell (`flutter_secure_storage`);
/// core depends on this interface only, so everything stays testable.
abstract class TofuPinStore {
  /// Pinned SHA-256 fingerprint (hex) for a relay host, or null when the
  /// host has never been pinned (first connection = learn).
  Future<String?> pinFor(String host);

  Future<void> setPin(String host, String sha256Hex);

  Future<void> removePin(String host);
}

/// In-memory store — tests and pre-pairing probes. `pins` is exposed because
/// the TLS callback is synchronous and decides on an in-memory table.
class MemoryPinStore implements TofuPinStore {
  final pins = <String, String>{};

  @override
  Future<String?> pinFor(String host) async => pins[host];

  @override
  Future<void> setPin(String host, String sha256Hex) async =>
      pins[host] = sha256Hex;

  @override
  Future<void> removePin(String host) async => pins.remove(host);
}

/// SHA-256 fingerprint of a certificate's DER bytes — the pin value.
String fingerprintOfDer(List<int> derBytes) =>
    sha256.convert(derBytes).toString();

/// Verdict of a TOFU check.
enum TofuVerdict {
  /// No pin yet → learn `fingerprint` (first connect / pairing flow).
  learn,

  /// Pin matches → proceed.
  ok,

  /// Pin mismatch → fail closed (tls.cert_changed; user must re-pair).
  mismatch,
}

TofuVerdict checkPin({String? pinned, required String fingerprint}) {
  if (pinned == null) return TofuVerdict.learn;
  return pinned == fingerprint ? TofuVerdict.ok : TofuVerdict.mismatch;
}

/// Convenience for logging/debug: fingerprint preview (first 12 hex chars).
String fingerprintPreview(String sha256Hex) =>
    sha256Hex.length <= 12 ? sha256Hex : '${sha256Hex.substring(0, 12)}…';

/// D-084 — fetch the relay's certificate fingerprint **proactively**.
///
/// The learn side of TOFU hangs off `PinnedHttpClient.badCertificateCallback`,
/// and dart:io only invokes that when certificate validation *fails*. A relay
/// presenting a publicly-trusted certificate (Let's Encrypt) validates
/// normally, so the callback never runs and the pairing flow's `onLearn` never
/// fires — the machine gets stored with `certPin: null` while the app works
/// perfectly, and every steady-state client then runs on an empty pin table.
/// 真机实证：配对的正是 https relay，pin 表却恒空，设置页还显示
/// 「No https relay yet」。
///
/// Pairing is the only moment the App is deliberately talking to the relay, so
/// this is where the pin belongs: ask for the certificate and fix it, rather
/// than waiting for something to go wrong first.
///
/// Returns null for plain http (no certificate exists), and null when the
/// handshake cannot be completed — a missing pin degrades to the pre-existing
/// fail-closed steady state, so it must never throw at the call site.
Future<String?> probePeerFingerprint(
  Uri origin, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (origin.scheme != 'https') return null;
  final port = origin.hasPort ? origin.port : 443;
  SecureSocket? socket;
  try {
    socket = await SecureSocket.connect(origin.host, port, timeout: timeout)
        .timeout(timeout);
    final cert = socket.peerCertificate;
    return cert == null ? null : fingerprintOfDer(cert.der);
  } on Object {
    // Best effort by design: see the doc comment.
    return null;
  } finally {
    socket?.destroy();
  }
}
