import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../harness/relay_harness.dart';

/// T0.5 — 实测③（pinned 2026-09-30, Dart 3.9.4 / macOS arm64）:
///
/// 1. `HttpClient.badCertificateCallback` fires for **https** and its
///    accept/reject return value decides the outcome (TOFU pin-table seat);
/// 2. **`WebSocket.connect(url, customClient: pinnedClient)` routes the wss
///    handshake through that same client** — the callback fires there too
///    (primary path for the app; no global state needed);
/// 3. rejecting in the callback fails the handshake (fail-closed TOFU).
///
/// Fallback (also verified by the probe, kept as a test): the global
/// `HttpOverrides` client serves `WebSocket.connect` as well.
void main() {
  late Directory tmp;
  late Process server;
  late int port;
  final repoRoot = RelayHarness.findRepoRoot();

  Future<(bool, String)> startBed() async {
    tmp = await Directory.systemTemp.createTemp('dsh_tls_pin');
    final cert = '${tmp.path}/cert.pem';
    final key = '${tmp.path}/key.pem';
    final openssl = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', key, '-out', cert, '-days', '1',
      '-subj', '/CN=localhost',
    ]);
    if (openssl.exitCode != 0) return (false, 'openssl unavailable');
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = sock.port;
    await sock.close();
    server = await Process.start('node', [
      '$repoRoot/app/packages/dsh_remote_core/tool/tls_echo_server.mjs',
      '--port', '$port',
      '--cert', cert,
      '--key', key,
    ], environment: {'DSH_REPO_ROOT': repoRoot!});
    final ready = Completer<void>();
    server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.contains('TLS_ECHO_READY') && !ready.isCompleted) {
        ready.complete();
      }
    });
    await ready.future.timeout(const Duration(seconds: 10));
    return (true, '');
  }

  setUpAll(() async {
    final repoOk =
        repoRoot != null && File('$repoRoot/server/node_modules/ws/index.js').existsSync();
    final hasOpenssl = await Process.run('which', ['openssl']).then((r) => r.exitCode == 0);
    if (!repoOk || !hasOpenssl || !Platform.isMacOS && !Platform.isLinux) {
      markTestSkipped('tls bed unavailable (repo=$repoOk openssl=$hasOpenssl)');
      return;
    }
    final (ok, reason) = await startBed();
    if (!ok) markTestSkipped('tls bed unavailable: $reason');
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {/* best effort */}
  });

  HttpClient pinnedClient(
      bool Function(String host) acceptHost, List<String> seenHosts) {
    final c = HttpClient();
    c.badCertificateCallback = (cert, host, port) {
      seenHosts.add(host);
      return acceptHost(host);
    };
    return c;
  }

  test('https: callback fires and accept lets the self-signed cert through',
      () async {
    final seen = <String>[];
    final client = pinnedClient((_) => true, seen);
    addTearDown(() => client.close(force: true));
    final req =
        await client.getUrl(Uri.parse('https://127.0.0.1:$port/'));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(body, contains('"tls":true'));
    expect(seen, contains('127.0.0.1'));
  });

  test('https: rejecting in the callback fails closed (TOFU pin mismatch)',
      () async {
    final client = pinnedClient((_) => false, []);
    addTearDown(() => client.close(force: true));
    await expectLater(
      client.getUrl(Uri.parse('https://127.0.0.1:$port/')).then((r) => r.close()),
      throwsA(isA<Exception>()),
    );
  });

  test('wss: WebSocket.connect(customClient:) fires the same callback (primary path)',
      () async {
    final seen = <String>[];
    final client = pinnedClient((_) => true, seen);
    final ws = await WebSocket.connect('wss://127.0.0.1:$port/echo',
        customClient: client);
    final first = await ws.first.timeout(const Duration(seconds: 8)) as String;
    expect(jsonDecode(first), containsPair('transport', 'wss'));
    expect(seen, contains('127.0.0.1'),
        reason: 'wss handshake must route through the custom client');
    await ws.close();
    client.close(force: true);
  });

  test('wss: rejecting in customClient fails the handshake (fail closed)',
      () async {
    final client = pinnedClient((_) => false, []);
    await expectLater(
      WebSocket.connect('wss://127.0.0.1:$port/echo', customClient: client)
          .timeout(const Duration(seconds: 8)),
      throwsA(isA<Exception>()),
    );
    client.close(force: true);
  });

  test('wss: global HttpOverrides fallback path also works', () async {
    // Dart 3.9: read via `current` (zone-aware), write via `global=`.
    final previous = HttpOverrides.current;
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    HttpOverrides.global = _SingleClientOverrides(client);
    try {
      final ws = await WebSocket.connect('wss://127.0.0.1:$port/echo')
          .timeout(const Duration(seconds: 8));
      await ws.first; // hello
      await ws.close();
    } finally {
      HttpOverrides.global = previous;
      client.close(force: true);
    }
  });
}

class _SingleClientOverrides extends HttpOverrides {
  _SingleClientOverrides(this.client);
  final HttpClient client;

  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}
