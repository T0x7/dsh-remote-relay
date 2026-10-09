import 'dart:io';

import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:test/test.dart';

import '../harness/relay_harness.dart';

/// T0.4 — 实测① Bearer 过闸（full chain, no phone）:
/// signed URL → Bearer → relay gate → tunnel frame → fake engine → back.
/// Negative paths pinned alongside: tampered hash, missing credentials,
/// unknown session. Skip-with-reason if the bed is unavailable.
void main() {
  late RelayHarness h;
  late SignedUrlParams params;

  setUp(() async {
    h = RelayHarness();
    try {
      await h.start();
    } on StateError catch (e) {
      if (e.message.contains('skip reason')) {
        markTestSkipped('integration bed unavailable: ${e.message}');
      }
      rethrow;
    }
    await h.registerSession();
    params = parseSignedUrl(h.mintPairingUrl());
  });

  tearDown(() => h.stop());

  test('GET /dsh-remote/session with Bearer passes the gate end-to-end',
      () async {
    final (status, body) = await h.get(
      h.relayOrigin.resolve('/dsh-remote/session'),
      headers: {'Authorization': 'Bearer ${params.bearer}'},
    );
    expect(status, 200,
        reason: 'gate must accept a valid URL-session Bearer (body: $body)');
    expect((body as Map<String, dynamic>)['engine'], 'fake',
        reason: 'body must come from the fake engine through the tunnel');
  });

  test('GET /api/ping with Bearer is proxied to the engine', () async {
    final (status, body) = await h.get(
      h.relayOrigin.resolve('/api/ping'),
      headers: {'Authorization': 'Bearer ${params.bearer}'},
    );
    expect(status, 200);
    expect((body as Map<String, dynamic>)['pong'], isTrue);
  });

  test('tampered hash is refused with 401 (fail closed)', () async {
    final bad = params.bearer.replaceRange(
        params.bearer.length - 2, params.bearer.length, 'zz');
    final (status, _) = await h.get(
      h.relayOrigin.resolve('/api/ping'),
      headers: {'Authorization': 'Bearer $bad'},
    );
    expect(status, 401);
  });

  test('no credentials is refused with 401', () async {
    final (status, _) = await h.get(h.relayOrigin.resolve('/api/ping'));
    expect(status, 401);
  });

  test('unknown sessionId is refused (session existence check)', () async {
    final url = mintSignedUrl(
      relayOrigin: h.relayOrigin,
      sessionId: 'sess_${'ab' * 8}',
      psk: h.psk,
      mid: RelayHarness.defaultMid,
    );
    final (status, _) = await h.get(
      h.relayOrigin.resolve('/api/ping'),
      headers: {'Authorization': 'Bearer ${parseSignedUrl(url).bearer}'},
    );
    expect(status, 401);
  });

  test('landing the signed URL issues a pairing cookie (302 to /auth)',
      () async {
      final client = HttpClient();
    try {
      final req = await client.getUrl(h.mintPairingUrl())
        ..followRedirects = false;
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 302);
      expect(
        res.headers.value('set-cookie'),
        allOf(isNotNull, contains('dsh_remote_session__')),
      );
    } finally {
      client.close(force: true);
    }
  });

  test('health endpoint needs no credentials', () async {
    final (status, _) = await h.get(h.relayOrigin.resolve('/health'));
    expect(status, 200);
  });
}
