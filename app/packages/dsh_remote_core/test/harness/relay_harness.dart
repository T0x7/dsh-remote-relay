import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dsh_remote_core/credentials/signed_url.dart';

/// Integration test bed (plan T0.3): spawns the REAL relay (`server/dist`)
/// plus a fake engine, and speaks the minimal tunnel control plane
/// (`session.register` over `/ws/dsh`) so a signed-URL session exists
/// server-side. No phone, no real dsh, fully offline.
///
/// Skip discipline (repo convention): if the environment cannot provide the
/// pieces (node, built server), tests SKIP with a printed reason instead of
/// failing.
class RelayHarness {
  RelayHarness()
      : psk = 'integration-psk-${_randomHex(16)}-${DateTime.now().microsecondsSinceEpoch}';

  /// Any 64-lowercase-hex value (machine fingerprint is informational
  /// server-side); built programmatically so it can never drift in length.
  static final String defaultMid = '5ee0f${'0' * 58}9'; // 5+58+1 = 64

  final String psk;
  late final int enginePort;
  late final int relayPort;
  late final Uri relayOrigin;

  Process? _engine;
  Process? _relay;
  WebSocket? _tunnel;
  final _bridges = <String, WebSocket>{}; // ws.upgrade id → engine WS
  String? _sessionId;
  String? _plannedSessionId;
  final List<String> _relayStderr = [];
  // 子进程 stdio 订阅：stop() 必须在进程退出后取消，否则 relay 被 kill 时的
  // stderr 残尾会在测试文件结束后迟到送达——flutter_tools 的 runner 通道会被
  // 这些「文件已收盘」的写入卡死（多文件一起跑时表现为第二个文件中段整场
  // 冻结、30s 默认超时也不触发；单跑各文件一切正常。D-077 排查实锤）。
  final _procSubs = <StreamSubscription<void>>[];
  final _tmp = Directory.systemTemp.createTempSync('dsh_remote_harness');

  String? get sessionId => _sessionId;

  /// Walk up from cwd until we find the repo root (has server/dist/index.js).
  static String? findRepoRoot() {
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

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  static String _randomHex(int n) => List.generate(
      n, (_) => '0123456789abcdef'[Random.secure().nextInt(16)]).join();

  Future<void> start() async {
    final repoRoot = findRepoRoot();
    if (repoRoot == null) {
      throw StateError(
          'repo root not found — run tests from the package directory');
    }
    if (!File('$repoRoot/server/dist/index.js').existsSync()) {
      throw StateError(
          'server not built — run `pnpm build` in server/ first (skip reason)');
    }
    enginePort = await _freePort();
    relayPort = await _freePort();
    relayOrigin = Uri.parse('http://127.0.0.1:$relayPort');
    // Session id is minted BEFORE engine start: the fake engine needs it to
    // mint url-sessions (DSH_TEST_*) for the renewal-loop test.
    _plannedSessionId ??= 'sess_${_randomHex(16)}';

    _engine = await Process.start('node', [
      '$repoRoot/app/packages/dsh_remote_core/tool/fake_engine.mjs',
      '--port', '$enginePort',
    ], environment: {
      'DSH_REPO_ROOT': repoRoot,
      'DSH_TEST_PSK': psk,
      'DSH_TEST_SID': _plannedSessionId!,
      'DSH_TEST_MID': defaultMid,
    });
    _procSubs.add(_engine!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.contains('FAKE_ENGINE_READY')) return;
    }));
    _procSubs.add(_engine!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {}));

    _relay = await Process.start('node', ['$repoRoot/server/dist/index.js'],
        environment: {
          'RELAY_PSK': psk,
          'RELAY_PUBLIC_HOST': '127.0.0.1:$relayPort',
          'DSH_UPSTREAM': 'http://127.0.0.1:$enginePort',
          'PORT': '$relayPort',
          'HOST': '127.0.0.1',
          'AUDIT_DB_PATH': '${_tmp.path}/relay-audit.db',
          'STATE_DB_PATH': '${_tmp.path}/relay-state.db',
          'LOG_LEVEL': 'warn',
        });
    var relayExited = false;
    _relay!.exitCode.then((code) {
      relayExited = true;
      // D-077 排查哨兵：全量套件下 relay 曾在测试间消失且无任何线索。
      // relay（生产同源 dist）中途退出永远是信号，必须现场留痕。
      // 同步落盘：runner 的 stdout 管道在卡死场景下不可信。
      final note = '[${DateTime.now().toIso8601String()}] relay EXITED '
          'code=$code stderr:\n${_relayStderr.join('\n')}\n';
      stdout.writeln('[harness] $note');
      try {
        File('${Directory.systemTemp.path}/harness_relay_events.log')
            .writeAsStringSync(note, mode: FileMode.append);
      } catch (_) {/* 尽力而为 */}
    });
    _procSubs.add(_relay!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _relayStderr.add(line);
      if (line.isNotEmpty) stdout.writeln('[harness][relay-stderr] $line');
    }));
    _procSubs.add(_relay!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (!line.startsWith('{')) _relayStderr.add(line);
    }));

    await _waitHealthy(relayExited);
  }

  Future<void> _waitHealthy(bool relayExited) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final code = await _statusOf(Uri.parse('$relayOrigin/health'));
        if (code == 200) return;
      } on SocketException {
        // not listening yet
      }
      if (relayExited) {
        throw StateError('relay exited early:\n${_relayStderr.join('\n')}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError(
        'relay did not become healthy:\n${_relayStderr.join('\n')}');
  }

  Future<int> _statusOf(Uri uri) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  /// Register a pairing over the PSK tunnel control plane (mirrors the
  /// machine-side client) AND run the minimal data plane: fulfil `http.req`
  /// against the fake engine and bridge `ws.upgrade` — the same jobs the real
  /// `RemoteTunnelClient` does. Frame shapes hand-copied from client/src
  /// tunnel.ts (authoritative) and pinned by these very tests.
  Future<String> registerSession() async {
    if (_sessionId != null) return _sessionId!;
    final sessionId = _plannedSessionId ?? 'sess_${_randomHex(16)}';
    final pairingToken = _randomHex(64);
    _tunnel = await WebSocket.connect(
      'ws://127.0.0.1:$relayPort/ws/dsh',
      headers: {
        'Authorization': 'Bearer $psk',
        'x-session-ts': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    final registered = Completer<void>();
    _tunnel!.listen((data) {
      final msg = jsonDecode(data is String ? data : utf8.decode(data as List<int>))
          as Map<String, dynamic>;
      switch (msg['type'] as String?) {
        case 'session.registered':
          if (msg['sessionId'] == sessionId && !registered.isCompleted) {
            registered.complete();
          }
        case 'http.req':
          _fulfilHttpReq(msg);
        case 'ws.upgrade':
          _bridgeWsUpgrade(msg);
        case 'ws.frame':
          if (msg['dir'] == 'up') {
            final engineWs = _bridges[msg['id'] as String];
            engineWs?.add(msg['payload'] as String);
          }
        case 'ws.close':
          final engineWs = _bridges.remove(msg['id'] as String);
          engineWs?.close();
      }
    }, onDone: () {
      if (!registered.isCompleted) {
        registered.completeError(StateError('tunnel closed before register'));
      }
    });
    _tunnel!.add(jsonEncode({
      'type': 'session.register',
      'payload': {
        'sessionId': sessionId,
        'pairingToken': pairingToken,
        'ttlSeconds': 300,
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }));
    await registered.future.timeout(const Duration(seconds: 10));
    _sessionId = sessionId;
    return sessionId;
  }

  /// Data plane: http.req → forward to the fake engine → http.res
  /// (identity encoding, gate-cookie strip, host pin, request body —
  /// mirroring the client).
  Future<void> _fulfilHttpReq(Map<String, dynamic> msg) async {
    final id = msg['id'] as String;
    final method = (msg['method'] as String).toUpperCase();
    final path = msg['path'] as String;
    final headers =
        (msg['headers'] as Map<String, dynamic>).cast<String, String>();
    headers.removeWhere(
        (k, _) => k.toLowerCase().startsWith('dsh_remote_session'));
    // Mirrors the real client: pin the relay's PUBLIC authority (publicHost),
    // never the engine address — the engine sees relay-branded Host headers.
    headers['host'] = '127.0.0.1:$relayPort';
    headers['accept-encoding'] = 'identity';
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:$enginePort$path');
      final HttpClientRequest req;
      switch (method) {
        case 'GET':
          req = await client.getUrl(uri);
        case 'POST':
          req = await client.postUrl(uri);
        case 'DELETE':
          req = await client.deleteUrl(uri);
        default:
          req = await client.openUrl(method, uri);
      }
      headers.forEach(req.headers.set);
      // The real client writes the forwarded body verbatim
      // (client/src/tunnel.ts:673 declares `body?: string`, :775 writes it).
      // Dropping it here silently broke every POST — M1 only ever issued GETs,
      // so the gap stayed invisible until M2's JSON-RPC envelope arrived.
      final requestBody = msg['body'] as String?;
      if (requestBody != null && requestBody.isNotEmpty) {
        req.add(utf8.encode(requestBody));
      }
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      final outHeaders = <String, String>{};
      res.headers.forEach((name, values) => outHeaders[name] = values.join(', '));
      _tunnel!.add(jsonEncode({
        'v': 1,
        'type': 'http.res',
        'id': id,
        'status': res.statusCode,
        'headers': outHeaders,
        'body': body,
      }));
    } catch (e) {
      _tunnel!.add(jsonEncode(
          {'v': 1, 'type': 'error', 'id': id, 'code': 'engine_down', 'message': '$e'}));
    } finally {
      client.close(force: true);
    }
  }

  /// Data plane: ws.upgrade → connect to the fake engine → ws.accept +
  /// ws.frame(dir: down) passthrough (mirrors tunnel.ts bridge).
  Future<void> _bridgeWsUpgrade(Map<String, dynamic> msg) async {
    final id = msg['id'] as String;
    final path = msg['path'] as String; // includes search
    try {
      final engineWs =
          await WebSocket.connect('ws://127.0.0.1:$enginePort$path');
      _bridges[id] = engineWs;
      _tunnel?.add(jsonEncode({'v': 1, 'type': 'ws.accept', 'id': id}));
      engineWs.listen((data) {
        final isText = data is String;
        _tunnel?.add(jsonEncode({
          'v': 1,
          'type': 'ws.frame',
          'id': id,
          'dir': 'down',
          'opcode': isText ? 1 : 2,
          'payload': isText ? data : base64Encode(data as List<int>),
        }));
      }, onDone: () {
        _tunnel?.add(jsonEncode(
            {'v': 1, 'type': 'ws.close', 'id': id, 'code': 1000, 'reason': ''}));
      });
    } catch (e) {
      _tunnel?.add(jsonEncode(
          {'v': 1, 'type': 'error', 'id': id, 'code': 'engine_down', 'message': '$e'}));
    }
  }

  /// Mint a fresh signed URL (24h) for the registered session — the machine
  /// side of the contract, using the same PSK.
  Uri mintPairingUrl({Duration ttl = const Duration(hours: 24)}) =>
      mintSignedUrl(
        relayOrigin: relayOrigin,
        sessionId: _sessionId!,
        psk: psk,
        mid: defaultMid,
        ttl: ttl,
        name: 'fake-engine-host',
      );

  /// A plain HTTP GET returning status + decoded JSON body (if any).
  Future<(int, dynamic)> get(Uri uri, {Map<String, String>? headers}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      headers?.forEach(req.headers.set);
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      dynamic decoded;
      if (body.isNotEmpty && res.headers.value('content-type')?.contains('json') == true) {
        try {
          decoded = jsonDecode(body);
        } catch (_) {/* non-strict */}
      }
      return (res.statusCode, decoded ?? body);
    } finally {
      client.close(force: true);
    }
  }

  /// Fire the root landing URL (as a browser would) — triggers v3.204
  /// engine-wide secret rotation + eviction of cookie-era streams.
  Future<int> land(Uri signedUrl) async =>
      _statusOf(signedUrl.replace()); // no redirect-following: status only

  Future<void> stop() async {
    for (final b in _bridges.values) {
      try {
        await b.close();
      } catch (_) {/* best effort */}
    }
    _bridges.clear();
    await _tunnel?.close();
    _tunnel = null;
    _engine?.kill();
    _relay?.kill();
    await _engine?.exitCode;
    await _relay?.exitCode;
    // 进程都已退场，掐掉 stdio 订阅：残尾字节不再迟到写入 runner 通道。
    for (final sub in _procSubs) {
      sub.cancel();
    }
    _procSubs.clear();
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {/* best effort */}
  }
}
