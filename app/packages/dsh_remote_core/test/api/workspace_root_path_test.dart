/// D-040 — the workspace root is spelled `.` on the wire.
///
/// The contract says the root is the empty string, and the listing echoes its
/// own `path` back as `''`. But the engine's argument validator rejects `''`
/// as a missing field, so the console showed `gateway/bad-request · path is
/// required` and an empty file tree on device.
///
/// Measured against the live engine on 2026-10-04 (session
/// `job-gamma-judge-20261004-201720`):
///
/// | `path` sent | result                                     |
/// |-------------|--------------------------------------------|
/// | `''`        | `gateway/bad-request` "path is required"    |
/// | `'/'`       | `workspace-file/outside-workspace`          |
/// | `'.'`       | **root listing** (`path: ''`, real entries)  |
///
/// So the App spells the root `.` on the request and keeps `''` internally.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:test/test.dart';

/// Records the bodies the engine client posts.
class _RecordingRelay extends RelayClient {
  _RecordingRelay()
      : super(
          origin: Uri.parse('https://relay.example'),
          pinned: PinnedHttpClient(pinTable: MemoryPinStore().pins),
          bearerProvider: () async => 'sid.exp.mid.t.hash',
        );

  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<(int, dynamic)> postJson(String path, Object? body) async {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    return (200, {
          'type': 'server-response',
          'result': {
            'ok': true,
            'value': {'path': '', 'entries': [], 'truncated': false},
          },
        });
  }
}

EngineGateway _gateway(_RecordingRelay relay) => EngineClient(
      rpc: EngineRpc(relay: relay),
      mux: EngineMux(
        origin: Uri.parse('https://relay.example'),
        pinned: PinnedHttpClient(pinTable: MemoryPinStore().pins),
        bearerProvider: () async => 'sid.exp.mid.t.hash',
      ),
    );

void main() {
  test('the root is requested as "." , not an empty string', () async {
    final relay = _RecordingRelay();
    await _gateway(relay).workspaceList(sessionId: 's1', path: '');

    expect(relay.bodies, hasLength(1));
    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args['path'], '.',
        reason: 'an empty path is rejected as a missing field');
    expect(args['workspaceFileScopeId'], 's1');
  });

  test('a child path is sent unchanged', () async {
    final relay = _RecordingRelay();
    await _gateway(relay).workspaceList(sessionId: 's1', path: 'src/lib');

    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args['path'], 'src/lib',
        reason: 'only the root is respelled; a real path is already correct');
  });

  test('the root listing decodes back to the empty path', () async {
    final relay = _RecordingRelay();
    final result =
        await _gateway(relay).workspaceList(sessionId: 's1', path: '');
    expect(result.isOk, isTrue);
    final listing = result.value! as WorkspaceDirectoryListing;
    expect(listing.path, isEmpty,
        reason: 'the engine echoes the root as "" — the round-trip holds');
  });
}
