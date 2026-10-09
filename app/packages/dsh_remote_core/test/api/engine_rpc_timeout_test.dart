/// D-026 — a unary call that never answers must fail as a typed
/// `client/timeout` (UI renders an inline card + retry) instead of leaving the
/// caller awaiting forever. Real-device E2E motivation: through the tunnel a
/// call can sit for tens of seconds when a mux stream is bridged on the same
/// pairing, and the console showed an endless spinner with no way out.
library;

import 'dart:async';

import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:test/test.dart';

/// A relay whose POST never completes (the stalled-tunnel shape).
class _StalledRelayClient extends RelayClient {
  _StalledRelayClient()
      : super(
          origin: Uri.parse('https://relay.example'),
          pinned: PinnedHttpClient(pinTable: MemoryPinStore().pins),
          bearerProvider: () async => 'sid.exp.mid.t.hash',
        );

  @override
  Future<(int, dynamic)> postJson(String path, Object? body) =>
      Completer<(int, dynamic)>().future;
}

void main() {
  test('a stalled call fails as client/timeout → engineUnavailable', () async {
    final rpc = EngineRpc(
      relay: _StalledRelayClient(),
      callTimeout: const Duration(milliseconds: 300),
    );
    final result = await rpc.call(SessionEndpoints.list, args: const {});
    expect(result.isOk, isFalse);
    expect(result.error!.code, 'client/timeout');
    expect(result.error!.toAppError().code, ErrorCode.engineUnavailable);
  });

  // D-045: the App's unary ceiling has to sit **above** the relay's proxy
  // ceiling, and the two live in different languages. A Dart test cannot read
  // the TypeScript constant, so it is restated here on purpose — the coupling
  // is the whole point, and a test that silently drifted from the relay would
  // be worse than no test at all.
  //
  // The bug this exists to prevent is the one you get for free if only one
  // side moves: raise the relay to 180 s, leave the App at 35 s, and every call
  // still dies at 35 s with the relay still patiently waiting.
  group('D-045 the App ceiling tracks the relay proxy ceiling', () {
    /// Mirrors `WSS_PROXY_TIMEOUT_MS` in `server/src/index.ts`. Keep the two
    /// in step; each file says so at the constant.
    const relayProxyCeiling = Duration(seconds: 180);

    test('the App gives up only after the relay has had its chance', () {
      expect(EngineRpc.defaultCallTimeout, greaterThan(relayProxyCeiling),
          reason: 'a shorter App ceiling makes the relay timeout unreachable');
    });

    test('but not so much later that a dead relay reads as a slow engine', () {
      expect(
        EngineRpc.defaultCallTimeout - relayProxyCeiling,
        lessThan(const Duration(seconds: 30)),
        reason: 'the App must not hang long past the point the relay gave up',
      );
    });
  });

  // D-044, found on a real device: the relay answered 504 and the card said
  // 「引擎返回了未知错误」 with `engine.timeout` printed right underneath it.
  //
  // D-039 taught the two *producers* of these codes (the HTTP status table and
  // the RPC status switch) but not the one *consumer*: `toAppError` looks the
  // string up and had never heard of `engine.timeout` / `engine.unavailable`,
  // so both fell through to `engineUnknown`. A code that no consumer knows
  // about is the same as no code at all.
  group('D-044 a wire code someone produces must be one someone reads', () {
    test('engine.timeout maps to engineTimeout, not engineUnknown', () {
      final mapped = const EngineRemoteError(
        code: 'engine.timeout',
        message: 'engine RPC session/list returned HTTP 504',
      ).toAppError();

      expect(mapped.code, ErrorCode.engineTimeout);
      expect(mapped.code, isNot(ErrorCode.engineUnknown));
    });

    test('engine.unavailable maps to engineUnavailable', () {
      const mapped = EngineRemoteError(
        code: 'engine.unavailable',
        message: 'engine RPC session/list returned HTTP 503',
      );
      expect(mapped.toAppError().code, ErrorCode.engineUnavailable);
    });

    test('the raw code still travels through for the bug report', () {
      // The mono line under the card is how this whole thing got noticed;
      // collapsing it would make the next occurrence undiagnosable.
      const err = EngineRemoteError(
        code: 'engine.timeout',
        message: 'engine RPC session/list returned HTTP 504',
      );
      expect(err.toAppError().rawMessage, 'engine.timeout');
    });
  });
}
