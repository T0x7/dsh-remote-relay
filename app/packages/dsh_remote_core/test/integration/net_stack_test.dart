import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/events_socket.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:test/test.dart';

import '../harness/relay_harness.dart';

/// T1.4/T1.5 — the M1 network layer against the REAL relay + fake engine:
/// typed snapshot fetch, the full 24h-renewal loop (mint → new Bearer → gate
/// accepts), and EventsSocket's 4001 self-heal (heal NOW, no backoff).
void main() {
  late RelayHarness h;
  late SignedUrlParams params;
  late PinnedHttpClient pinned;
  late RelayClient client;

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
    pinned = PinnedHttpClient.fromStore(MemoryPinStore());
    client = RelayClient(
      origin: h.relayOrigin,
      pinned: pinned,
      bearerProvider: () async => params.bearer,
    );
  });

  tearDown(() async {
    await h.stop();
    pinned.close();
  });

  test('typed session snapshot parses through RelayClient', () async {
    final snap = await client.fetchSessionSnapshot();
    expect(snap, isNotNull);
    expect(snap!.tunnel.state, TunnelState.connected);
  });

  test('full renewal loop: mint url-session → new Bearer accepted by gate',
      () async {
    final mint = await client.mintUrlSession();
    expect(mint, isNotNull, reason: 'fake engine mints with the same PSK');
    final renewed = parseSignedUrl(Uri.parse(mint!.url));
    expect(renewed.relayOrigin, h.relayOrigin);
    expect(renewed.sessionId, params.sessionId);

    // The freshly minted Bearer (different t/exp/hash) passes the gate.
    final pinned2 = PinnedHttpClient.fromStore(MemoryPinStore());
    final client2 = RelayClient(
      origin: h.relayOrigin,
      pinned: pinned2,
      bearerProvider: () async => renewed.bearer,
    );
    addTearDown(pinned2.close);
    final (status, body) = await client2.get('/api/ping');
    expect(status, 200);
    expect((body as Map<String, dynamic>)['pong'], isTrue);
  });

  test('tunnel toggle route round-trips (fake engine stub)', () async {
    expect(await client.setTunnel(TunnelAction.disconnect), isTrue);
    expect(await client.setTunnel(TunnelAction.connect), isTrue);
  });

  test('transport failure maps to network.unreachable AppError', () async {
    final deadPinned = PinnedHttpClient.fromStore(MemoryPinStore());
    final deadClient = RelayClient(
      origin: Uri.parse('http://127.0.0.1:1'),
      pinned: deadPinned,
      bearerProvider: () async => params.bearer,
    );
    addTearDown(deadPinned.close);
    await expectLater(
      deadClient.get('/api/ping'),
      throwsA(isA<AppError>().having((AppError e) => e.code.id, 'id', 'network.unreachable')),
    );
  });

  test('EventsSocket heals on 4001 immediately (same bearer, no backoff)',
      () async {
    final socket = EventsSocket(
      uri: h.relayOrigin
          .replace(scheme: 'ws')
          .resolve('/api/events.mux'),
      bearerProvider: () async => params.bearer,
      pinned: pinned,
    );
    addTearDown(socket.dispose);

    final states = <EventsSocketState>[];
    socket.states.listen(states.add);
    final hellos = <Map<String, dynamic>>[];
    final gotHello = Completer<void>();
    final gotSecondHello = Completer<void>();
    var helloCount = 0;
    socket.messages.listen((m) {
      if (m['type'] == 'hello') {
        hellos.add(m);
        helloCount++;
        if (helloCount == 1 && !gotHello.isCompleted) gotHello.complete();
        if (helloCount == 2 && !gotSecondHello.isCompleted) {
          gotSecondHello.complete();
        }
      }
    });

    socket.start();
    await gotHello.future.timeout(const Duration(seconds: 10));
    expect(socket.state, EventsSocketState.connected);

    // Another device lands → v3.204 eviction → 4001 → immediate heal.
    await h.land(h.mintPairingUrl());
    await gotSecondHello.future.timeout(const Duration(seconds: 15));

    expect(hellos, hasLength(2), reason: 'reconnected and re-received hello');
    // healing state must have been observed between the two connections.
    expect(states.contains(EventsSocketState.healing), isTrue,
        reason: '4001 path skips backoff (§4.1(3))');
  });

  test('plain http relay never trips the pin table (no cert checks)',
      () async {
    await client.get('/api/ping');
    expect(pinned.rejectedHosts, isEmpty);
  });

  // Silence "unused import" if IO helpers are refactored.
  final _ = Platform.isMacOS;
}
