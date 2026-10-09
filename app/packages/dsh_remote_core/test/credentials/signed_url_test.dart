import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:test/test.dart';

/// Cross-language interlock vector — HMAC-SHA256 computed independently with
/// Python's `hmac` module (std lib) on 2026-09-30; if this literal ever fails,
/// the Dart HMAC or the concatenation order drifted from the contract.
const _vectorPsk = '_integration-test-psk_';
const _vectorSid = 'sess_abcdef0123456789';
const _vectorMid =
    'a3f0000000000000000000000000000000000000000000000000000000000000';
const _vectorT = 1779913600000;
const _vectorExp = 1780000000000;
const _vectorHash = 'HDpz9tFRRtA-4DYpRT6EWTcOAtAbvb-jfZikqIzHlfE';

Uri _mintedUrl() => mintSignedUrl(
      relayOrigin: Uri.parse('https://relay.example.com'),
      sessionId: _vectorSid,
      psk: _vectorPsk,
      mid: _vectorMid,
      now: DateTime.fromMillisecondsSinceEpoch(_vectorT),
      ttl: const Duration(milliseconds: _vectorExp - _vectorT),
      name: 'mac-mini',
    );

void main() {
  group('computeSignedUrlHash (contract interlock)', () {
    test('matches Python-computed HMAC vector', () {
      expect(
        computeSignedUrlHash(
            psk: _vectorPsk,
            sessionId: _vectorSid,
            expMs: _vectorExp,
            mid: _vectorMid,
            tMs: _vectorT),
        _vectorHash,
      );
    });

    test('hash is 43 chars base64url, no padding', () {
      final h = computeSignedUrlHash(
          psk: 'x',
          sessionId: 'sess_x',
          expMs: 2,
          mid: 'b' * 64,
          tMs: 1);
      expect(h.length, 43);
      expect(h, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });
  });

  group('mintSignedUrl', () {
    test('roundtrips through parseSignedUrl with exact fields', () {
      final url = _mintedUrl();
      final p = parseSignedUrl(url);
      expect(p.relayOrigin, Uri.parse('https://relay.example.com'));
      expect(p.sessionId, _vectorSid);
      expect(p.mid, _vectorMid);
      expect(p.tMs, _vectorT);
      expect(p.expMs, _vectorExp);
      expect(p.name, 'mac-mini');
      expect(p.bearer, '$_vectorSid.$_vectorExp.$_vectorMid.$_vectorT.$_vectorHash');
    });

    test('clamps ttl into the 60s..24h relay window', () {
      final tooShort = mintSignedUrl(
          relayOrigin: Uri.parse('https://r.example'),
          sessionId: 'sess_a',
          psk: 'p',
          mid: 'c' * 64,
          now: DateTime.fromMillisecondsSinceEpoch(1000),
          ttl: const Duration(seconds: 1));
      expect(parseSignedUrl(tooShort).ttl, const Duration(seconds: 60));

      final tooLong = mintSignedUrl(
          relayOrigin: Uri.parse('https://r.example'),
          sessionId: 'sess_a',
          psk: 'p',
          mid: 'c' * 64,
          now: DateTime.fromMillisecondsSinceEpoch(1000),
          ttl: const Duration(days: 3));
      expect(parseSignedUrl(tooLong).ttl, const Duration(hours: 24));
    });
  });

  group('parseSignedUrl rejections (reason doubles as UI copy key)', () {
    SignedUrlFormatException reasonOf(Uri uri) {
      try {
        parseSignedUrl(uri);
      } on SignedUrlFormatException catch (e) {
        return e;
      }
      fail('expected SignedUrlFormatException for $uri');
    }

    test('non-http scheme', () {
      expect(reasonOf(Uri.parse('ftp://relay.example/?sessionId=x')).reason,
          contains('scheme'));
    });

    test('non-root path', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/pair?sessionId=sess_a&hash=${'h' * 43}&t=1&exp=2&mid=${'a' * 64}')).reason,
          contains('path'));
    });

    test('legacy token param is refused (v3.176.2 shape)', () {
      final reason = reasonOf(Uri.parse(
          'https://relay.example/?sessionId=sess_a&token=deadbeef'));
      expect(reason.reason, contains('token'));
    });

    test('bad sessionId', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=nope&hash=${'h' * 43}&t=1&exp=61000&mid=${'a' * 64}')).reason,
          'sessionId malformed');
    });

    test('hash too short / bad alphabet', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=short&t=1&exp=61000&mid=${'a' * 64}')).reason,
          contains('hash'));
      // '+' and '/' are base64 but not base64url — must be rejected.
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=${'+' * 43}&t=1&exp=61000&mid=${'a' * 64}')).reason,
          contains('hash'));
    });

    test('mid uppercase hex refused', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=${'h' * 43}&t=1&exp=61000&mid=${'A' * 64}')).reason,
          contains('mid'));
    });

    test('t/exp not digits', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=${'h' * 43}&t=now&exp=61000&mid=${'a' * 64}')).reason,
          contains('epoch-ms'));
    });

    test('exp <= t', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=${'h' * 43}&t=100&exp=100&mid=${'a' * 64}')).reason,
          contains('exp'));
    });

    test('ttl outside window (25h)', () {
      expect(
          reasonOf(Uri.parse(
              'https://relay.example/?sessionId=sess_a&hash=${'h' * 43}&t=0&exp=${25 * 3600 * 1000}&mid=${'a' * 64}')).reason,
          contains('window'));
    });
  });

  group('bearer & expiry', () {
    test('bearer joins with dots in sid.exp.mid.t.hash order', () {
      final p = parseSignedUrl(_mintedUrl());
      final parts = p.bearer.split('.');
      expect(parts.length, 5);
      expect(parts[0], _vectorSid);
      expect(parts[1], '$_vectorExp');
      expect(parts[2], _vectorMid);
      expect(parts[3], '$_vectorT');
      expect(parts[4], _vectorHash);
    });

    test('isExpired flips at exp', () {
      final p = parseSignedUrl(_mintedUrl());
      expect(p.isExpired(now: DateTime.fromMillisecondsSinceEpoch(_vectorT)),
          isFalse);
      expect(
          p.isExpired(
              now: DateTime.fromMillisecondsSinceEpoch(_vectorExp + 1)),
          isTrue);
    });
  });
}
