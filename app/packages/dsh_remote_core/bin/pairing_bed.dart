import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_remote_core/credentials/signed_url.dart';

/// Standalone pairing bed for DEVICE end-to-end runs (plan 门 1 设备冒烟):
/// boots the REAL relay + fake engine, registers a session over the PSK
/// tunnel control plane, prints a paste-ready signed URL, then idles until
/// killed. Pair with `adb reverse tcp:<port> tcp:<port>` so the phone's
/// 127.0.0.1 reaches this Mac.
Future<void> main() async {
  final repoRoot = _findRepoRoot();
  if (repoRoot == null) {
    stderr.writeln('repo root not found');
    exit(2);
  }
  final psk = 'device-e2e-psk-${_hex(12)}';
  final enginePort = await _freePort();
  final relayPort = await _freePort();
  final mid = '5ee0f${'0' * 58}9';
  final sessionId = 'sess_${_hex(16)}';

  final engine = await Process.start('node', [
    '$repoRoot/app/packages/dsh_remote_core/tool/fake_engine.mjs',
    '--port', '$enginePort',
  ], environment: {
    'DSH_REPO_ROOT': repoRoot,
    'DSH_TEST_PSK': psk,
    'DSH_TEST_SID': sessionId,
    'DSH_TEST_MID': mid,
  });
  final relay = await Process.start('node', ['$repoRoot/server/dist/index.js'],
      environment: {
        'RELAY_PSK': psk,
        'RELAY_PUBLIC_HOST': '127.0.0.1:$relayPort',
        'DSH_UPSTREAM': 'http://127.0.0.1:$enginePort',
        'PORT': '$relayPort',
        'HOST': '127.0.0.1',
        'AUDIT_DB_PATH': '/tmp/dsh_bed_audit.db',
        'STATE_DB_PATH': '/tmp/dsh_bed_state.db',
        'LOG_LEVEL': 'warn',
      });
  final relayOut = <String>[];
  relay.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(relayOut.add);

  // Health wait
  var healthy = false;
  for (var i = 0; i < 100 && !healthy; i++) {
    try {
      final c = HttpClient();
      final r = await c
          .getUrl(Uri.parse('http://127.0.0.1:$relayPort/health'))
          .then((rq) => rq.close());
      await r.drain<void>();
      healthy = r.statusCode == 200;
      c.close(force: true);
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
  if (!healthy) {
    stderr.writeln('relay never became healthy:\n${relayOut.join('\n')}');
    engine.kill();
    relay.kill();
    exit(1);
  }

  // Tunnel control plane: register the session (machine side).
  final tunnel = await WebSocket.connect('ws://127.0.0.1:$relayPort/ws/dsh',
      headers: {
        'Authorization': 'Bearer $psk',
        'x-session-ts': '${DateTime.now().millisecondsSinceEpoch}',
      });
  final registered = Completer<void>();
  tunnel.listen((data) {
    final msg =
        jsonDecode(data is String ? data : utf8.decode(data as List<int>))
            as Map<String, dynamic>;
    if (msg['type'] == 'session.registered' && !registered.isCompleted) {
      registered.complete();
    }
    // Minimal data plane: fulfil http.req against the fake engine.
    if (msg['type'] == 'http.req') {
      _fulfil(tunnel, msg, enginePort);
    }
    if (msg['type'] == 'ws.upgrade') {
      _bridge(tunnel, msg, enginePort);
    }
  });
  tunnel.add(jsonEncode({
    'type': 'session.register',
    'payload': {
      'sessionId': sessionId,
      'pairingToken': _hex(64),
      'ttlSeconds': 300,
    },
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  }));
  await registered.future.timeout(const Duration(seconds: 10));

  final url = mintSignedUrl(
    relayOrigin: Uri.parse('http://127.0.0.1:$relayPort'),
    sessionId: sessionId,
    psk: psk,
    mid: mid,
    name: 'mac-mini-studio',
  );
  stdout
    ..writeln('BED_READY relay_port=$relayPort engine_port=$enginePort')
    ..writeln('PAIRING_URL=$url')
    ..writeln('adb reverse tcp:$relayPort tcp:$relayPort')
    ..writeln('idling — Ctrl-C to tear down');

  await Completer<void>().future; // idle forever
}

Future<void> _fulfil(WebSocket tunnel, Map<String, dynamic> msg, int enginePort) async {
  final id = msg['id'] as String;
  final headers =
      (msg['headers'] as Map<String, dynamic>).cast<String, String>();
  headers.removeWhere((k, _) => k.toLowerCase().startsWith('dsh_remote_session'));
  headers['host'] = '127.0.0.1:$enginePort';
  headers['accept-encoding'] = 'identity';
  final client = HttpClient();
  try {
    final uri = Uri.parse('http://127.0.0.1:$enginePort${msg['path']}');
    final req = switch (msg['method']) {
      'GET' => await client.getUrl(uri),
      'POST' => await client.postUrl(uri),
      'DELETE' => await client.deleteUrl(uri),
      _ => await client.openUrl((msg['method'] as String), uri),
    };
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    final out = <String, String>{};
    res.headers.forEach((n, v) => out[n] = v.join(', '));
    tunnel.add(jsonEncode({
      'v': 1, 'type': 'http.res', 'id': id,
      'status': res.statusCode, 'headers': out, 'body': body,
    }));
  } catch (e) {
    tunnel.add(jsonEncode(
        {'v': 1, 'type': 'error', 'id': id, 'code': 'engine_down', 'message': '$e'}));
  } finally {
    client.close(force: true);
  }
}

final _bridges = <String, WebSocket>{};

Future<void> _bridge(WebSocket tunnel, Map<String, dynamic> msg, int enginePort) async {
  final id = msg['id'] as String;
  try {
    final ws = await WebSocket.connect(
        'ws://127.0.0.1:$enginePort${msg['path'] as String}');
    _bridges[id] = ws;
    tunnel.add(jsonEncode({'v': 1, 'type': 'ws.accept', 'id': id}));
    ws.listen((data) {
      final isText = data is String;
      tunnel.add(jsonEncode({
        'v': 1, 'type': 'ws.frame', 'id': id, 'dir': 'down',
        'opcode': isText ? 1 : 2,
        'payload': isText ? data : base64Encode(data as List<int>),
      }));
    });
  } catch (e) {
    tunnel.add(jsonEncode(
        {'v': 1, 'type': 'error', 'id': id, 'code': 'engine_down', 'message': '$e'}));
  }
}

String _hex(int n) =>
    List.generate(n, (_) => '0123456789abcdef'[Random.secure().nextInt(16)]).join();

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

String? _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/server/dist/index.js').existsSync() &&
        File('${dir.path}/pnpm-workspace.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}
