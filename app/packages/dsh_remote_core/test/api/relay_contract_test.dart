import 'package:dsh_remote_core/api/error_code.dart';
import 'package:test/test.dart';

import 'package:dsh_remote_core/api/relay.dart';

/// Contract fixtures hand-copied from client/src/tunnel.ts field shapes —
/// if the upstream changes a field, these turn red together with the
/// integration bed (belt and braces).
void main() {
  test('RemoteSessionSnapshot parses the full card payload', () {
    final snap = RemoteSessionSnapshot.fromJson({
      'tunnel': {
        'state': 'connected',
        'relayUrl': 'https://relay.example.com',
        'manualOff': false,
        'engine': 'unreachable',
      },
      'active': {
        'sessionId': 'sess_abc',
        'pairingToken': 'f' * 64,
        'qrUrl': 'https://relay.example.com/?sessionId=sess_abc&hash=x',
        'expiresAt': 1780000000000,
        'createdAt': 1779900000000,
      },
      'sessions': [
        {
          'sessionId': 'sess_abc',
          'pairingToken': 'f' * 64,
          'qrUrl': '',
          'expiresAt': 1780000000000,
          'createdAt': 1779900000000,
        },
      ],
      'devices': [
        {
          'sessionId': 'sess_abc',
          'createdAt': 1779900000000,
          'lastSeen': 1779950000000,
          'onlineWs': 1,
          'online': true,
          'paired': true,
        },
        {
          'sessionId': 'sess_def',
          'createdAt': 1779900000000,
          'lastSeen': null,
          'onlineWs': 0,
          'online': false,
          'paired': false,
        },
      ],
    });
    expect(snap.tunnel.state, TunnelState.connected);
    expect(snap.tunnel.relayUrl, 'https://relay.example.com');
    expect(snap.tunnel.engine, EngineHealth.unreachable);
    expect(snap.active?.sessionId, 'sess_abc');
    expect(snap.active?.createdAt, 1779900000000);
    expect(snap.sessions, hasLength(1));
    expect(snap.devices, hasLength(2));
    expect(snap.onlineCount, 1);
    expect(snap.devices!.first.paired, isTrue);
    expect(snap.devices!.last.lastSeen, isNull);
  });

  test('devices: null when relay unreachable (degrade, never break)', () {
    final snap =
        RemoteSessionSnapshot.fromJson({'tunnel': {}, 'devices': null});
    expect(snap.devices, isNull);
    expect(snap.onlineCount, 0);
    expect(snap.tunnel.state, TunnelState.unknown);
  });

  test('TunnelState maps all five literals + unknown', () {
    for (final (lit, expected) in [
      ('connected', TunnelState.connected),
      ('connecting', TunnelState.connecting),
      ('reconnecting', TunnelState.reconnecting),
      ('disabled', TunnelState.disabled),
      ('manual-off', TunnelState.manualOff),
      ('future-literal', TunnelState.unknown),
      (null, TunnelState.unknown),
    ]) {
      expect(TunnelState.fromJson(lit), expected);
    }
  });

  test('EngineHealth parses the v3.177 field; absent/junk → unknown', () {
    expect(
        TunnelConnectionState.fromJson({
          'state': 'connected',
          'engine': 'ok',
        }).engine,
        EngineHealth.ok);
    expect(
        TunnelConnectionState.fromJson({
          'state': 'connected',
          'engine': 'unreachable',
        }).engine,
        EngineHealth.unreachable);
    // Old-client snapshot without the field must not read as a fault.
    expect(
        TunnelConnectionState.fromJson({'state': 'connected'}).engine,
        EngineHealth.unknown);
    expect(
        TunnelConnectionState.fromJson({
          'state': 'connected',
          'engine': 'future-literal',
        }).engine,
        EngineHealth.unknown);
  });

  test('RevokeAllResult and UrlSessionMint parse', () {
    expect(RevokeAllResult.fromJson({'ok': true, 'revoked': 3}).revoked, 3);
    expect(UrlSessionMint.fromJson({'url': 'https://r/?sessionId=x'}).url,
        contains('sessionId='));
  });

  test('error-code module still importable beside contract (sanity)', () {
    expect(AppError(ErrorCode.authExpired).presentation,
        ErrorPresentation.fullScreen);
  });
}
