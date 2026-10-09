import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:test/test.dart';

import '../harness/relay_harness.dart';

/// One long-lived subscription over a single-subscription WebSocket —
/// `.first` would cancel the subscription and CLOSE the socket, and a second
/// `listen` would throw; this pipe keeps both next() and done alive.
class WsPipe {
  WsPipe(this.ws) {
    _sub = ws.listen(_onData, onDone: _onDone, onError: _onDone);
  }
  final WebSocket ws;
  late final StreamSubscription<Object?> _sub;
  final _pending = <Map<String, dynamic>>[];
  final _waiters = <Completer<Map<String, dynamic>>>[];
  final done = Completer<int?>();

  void _onData(Object? data) {
    final msg = jsonDecode(data is String ? data : utf8.decode(data as List<int>))
        as Map<String, dynamic>;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else {
      _pending.add(msg);
    }
  }

  void _onDone([Object? _]) {
    if (!done.isCompleted) done.complete(ws.closeCode);
  }

  Future<Map<String, dynamic>> next(
      {Duration timeout = const Duration(seconds: 10)}) {
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final c = Completer<Map<String, dynamic>>();
    _waiters.add(c);
    return c.future.timeout(timeout);
  }

  Future<void> close() async {
    await _sub.cancel();
    await ws.close();
  }
}

/// T0.6 — 实测② WS `?token=` 桥接 + 4001 自愈（local stack, no phone）:
///
/// 1. bridged events WS connects with the URL-session token and receives the
///    engine hello (relay → ws.upgrade → tunnel bridge → fake engine);
/// 2. uplink frames echo back (bidirectional bridge);
/// 3. another device LANDS the signed URL (root gate) → v3.204 rotation
///    evicts our stream with close(4001, 'device_replaced');
/// 4. reconnecting with the SAME Bearer heals (HTTP cred unaffected by
///    rotation) — the self-heal contract §4.1(3) the app depends on.
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

  Future<WsPipe> connectBridged() async {
    final ws = await WebSocket.connect(
      '${h.relayOrigin.replace(scheme: 'ws')}/api/events.mux?token=${params.bearer}',
    ).timeout(const Duration(seconds: 10));
    return WsPipe(ws);
  }

  test('bridged events WS receives engine hello through the tunnel', () async {
    final pipe = await connectBridged();
    addTearDown(pipe.close);
    final hello = await pipe.next();
    expect(hello['type'], 'hello');
    expect(hello['engine'], 'fake');
  });

  test('uplink frame echoes back (bidirectional bridge)', () async {
    final pipe = await connectBridged();
    addTearDown(pipe.close);
    await pipe.next(); // hello
    pipe.ws.add(jsonEncode({'type': 'ping', 'n': 1}));
    final echoed = await pipe.next();
    expect(echoed['type'], 'echo');
    expect(echoed['of'] as String, contains('"ping"'));
  });

  test('landing by another device evicts the stream with close(4001)',
      () async {
    final pipe = await connectBridged();
    await pipe.next(); // hello
    await h.land(h.mintPairingUrl()); // another device lands → rotation
    final code = await pipe.done.future.timeout(const Duration(seconds: 15));
    expect(code, 4001, reason: 'v3.205 real-time eviction close code');
  });

  test('SAME bearer heals after 4001 (HTTP cred survives rotation)', () async {
    final pipe = await connectBridged();
    await pipe.next(); // hello
    await h.land(h.mintPairingUrl());
    final code = await pipe.done.future.timeout(const Duration(seconds: 15));
    expect(code, 4001);

    // Self-heal: reconnect with the same Bearer, expect the engine hello.
    final pipe2 = await connectBridged();
    addTearDown(pipe2.close);
    final hello2 = await pipe2.next();
    expect(hello2['type'], 'hello');

    // And plain HTTP still works with the same bearer post-rotation.
    final (status, _) = await h.get(
      h.relayOrigin.resolve('/api/ping'),
      headers: {'Authorization': 'Bearer ${params.bearer}'},
    );
    expect(status, 200);
  });
}
