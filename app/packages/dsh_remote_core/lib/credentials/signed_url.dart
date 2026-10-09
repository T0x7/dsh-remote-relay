/// Signed pairing URL + URL-session Bearer credentials.
///
/// Shapes are hand-copied from the repo's authoritative sources and pinned by
/// tests on both sides (repo convention, cf. docs/protocol.md):
///
/// - QR / share link (client `buildSignedUrl`, client/src/tunnel.ts):
///   `https://relay/?sessionId=sid&hash=h&t=ms&exp=ms&mid=m[&name][&app_version]`
/// - Bearer (server `verifyUrlSessionToken`, server/src/index.ts):
///   `Authorization: Bearer sid.exp.mid.t.hash`
/// - hash = base64url-no-padding(HMAC-SHA256(PSK, "sid|exp|mid|t")) → 43 chars
/// - Field grammars: sid `^sess_[A-Za-z0-9_-]+$` · exp/t `^[0-9]{1,20}$` ·
///   mid `^[a-f0-9]{64}$` (machine fingerprint, informational) ·
///   hash `^[A-Za-z0-9_-]{43}$`
/// - TTL window: 60 s … 86400 s (24 h max).
/// - `token` query param must be absent (v3.176.2: the signed-URL QR never
///   carries it; upstream SPAs 303-strip it).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Thrown when a scanned/pasted URL does not match the signed-URL contract.
class SignedUrlFormatException implements Exception {
  const SignedUrlFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'SignedUrlFormatException: $reason';
}

final _sidRe = RegExp(r'^sess_[A-Za-z0-9_-]+$');
final _tsRe = RegExp(r'^[0-9]{1,20}$');
final _midRe = RegExp(r'^[a-f0-9]{64}$');
final _hashRe = RegExp(r'^[A-Za-z0-9_-]{43}$');

const _minTtl = Duration(seconds: 60);
const _maxTtl = Duration(hours: 24);

/// Parsed and validated signed pairing URL.
class SignedUrlParams {
  const SignedUrlParams({
    required this.relayOrigin,
    required this.sessionId,
    required this.hash,
    required this.mid,
    required this.tMs,
    required this.expMs,
    this.name,
    this.appVersion,
  });

  /// Relay origin (`scheme://host[:port]`) the machine's tunnel dials out to.
  final Uri relayOrigin;

  final String sessionId;
  final String hash;
  final String mid;
  final int tMs;
  final int expMs;
  final String? name;
  final String? appVersion;

  /// The URL-session Bearer accepted by the relay gate on every path and by
  /// bridged WS upgrades as `?token=`.
  String get bearer => '$sessionId.$expMs.$mid.$tMs.$hash';

  Duration get ttl => Duration(milliseconds: expMs - tMs);

  bool isExpired({DateTime? now}) =>
      (now ?? DateTime.now()).millisecondsSinceEpoch >= expMs;
}

/// Compute the 43-char base64url (unpadded) HMAC-SHA256 signature over
/// `"<sid>|<exp>|<mid>|<t>"` with the relay PSK — identical concatenation
/// order to client `buildSignedUrl` / server `verifyUrlSessionToken`.
String computeSignedUrlHash({
  required String psk,
  required String sessionId,
  required int expMs,
  required String mid,
  required int tMs,
}) {
  final mac = Hmac(sha256, utf8.encode(psk))
      .convert(utf8.encode('$sessionId|$expMs|$mid|$tMs'));
  return base64Url.encode(mac.bytes).replaceAll('=', '');
}

/// Parse and validate a scanned/pasted pairing URL. Throws
/// [SignedUrlFormatException] with a specific reason on every malformed
/// shape — reasons double as the pairing-failure copy keys (§7.2).
SignedUrlParams parseSignedUrl(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') {
    throw const SignedUrlFormatException('scheme must be http(s)');
  }
  if (url.host.isEmpty) throw const SignedUrlFormatException('missing host');
  final path = url.path.isEmpty || url.path == '/' ? '/' : url.path;
  if (path != '/') {
    throw const SignedUrlFormatException('path must be / (root landing)');
  }
  final q = url.queryParameters;
  if (q.containsKey('token')) {
    throw const SignedUrlFormatException(
        'token param present — not a signed-URL QR (v3.176.2 shape)');
  }
  final sid = q['sessionId'] ?? '';
  final hash = q['hash'] ?? '';
  final t = q['t'] ?? '';
  final exp = q['exp'] ?? '';
  final mid = q['mid'] ?? '';
  if (!_sidRe.hasMatch(sid)) {
    throw const SignedUrlFormatException('sessionId malformed');
  }
  if (!_tsRe.hasMatch(t) || !_tsRe.hasMatch(exp)) {
    throw const SignedUrlFormatException('t/exp must be epoch-ms digits');
  }
  if (!_midRe.hasMatch(mid)) {
    throw const SignedUrlFormatException('mid must be 64 lowercase hex');
  }
  if (!_hashRe.hasMatch(hash)) {
    throw const SignedUrlFormatException('hash must be 43 base64url chars');
  }
  final tMs = int.parse(t);
  final expMs = int.parse(exp);
  if (expMs <= tMs) throw const SignedUrlFormatException('exp must be > t');
  final ttl = Duration(milliseconds: expMs - tMs);
  if (ttl < _minTtl || ttl > _maxTtl) {
    throw const SignedUrlFormatException('ttl outside 60s..24h window');
  }
  return SignedUrlParams(
    relayOrigin: Uri.parse('${url.scheme}://${url.authority}'),
    sessionId: sid,
    hash: hash,
    mid: mid,
    tMs: tMs,
    expMs: expMs,
    name: q['name'],
    appVersion: q['app_version'],
  );
}

/// Mint a signed URL with a known PSK — the machine/client side of the
/// contract. Test-harness and tooling use; the app itself only parses.
/// TTL is clamped to the relay's 60 s … 24 h window (mirrors client).
Uri mintSignedUrl({
  required Uri relayOrigin,
  required String sessionId,
  required String psk,
  required String mid,
  DateTime? now,
  Duration ttl = const Duration(hours: 24),
  String? name,
  String? appVersion,
}) {
  if (!_sidRe.hasMatch(sessionId)) {
    throw const SignedUrlFormatException('sessionId malformed');
  }
  final clampedTtl = ttl < _minTtl
      ? _minTtl
      : ttl > _maxTtl
          ? _maxTtl
          : ttl;
  final tMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final expMs = tMs + clampedTtl.inMilliseconds;
  final hash = computeSignedUrlHash(
      psk: psk, sessionId: sessionId, expMs: expMs, mid: mid, tMs: tMs);
  return relayOrigin.replace(
    path: '/',
    queryParameters: {
      'sessionId': sessionId,
      'hash': hash,
      't': '$tMs',
      'exp': '$expMs',
      'mid': mid,
      if (name != null && name.isNotEmpty) 'name': name,
      if (appVersion != null) 'app_version': appVersion,
    },
  );
}
