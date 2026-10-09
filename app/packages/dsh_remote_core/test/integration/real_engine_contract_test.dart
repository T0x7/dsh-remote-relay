@Timeout(Duration(minutes: 2))
library;


import 'dart:io';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:test/test.dart';

/// The **real engine** contract guard (added 2026-10-02 after a live probe).
///
/// Everything else in this package proves the Dart side agrees with the
/// hand-copied contract — including the integration bed, whose fake engine I
/// wrote. Only this suite can catch a transcription error, and one did: the
/// wire `args` is keyed by the endpoint's **declared parameter name**
/// (`{request: {…}}`, `{_request: {}}` for `session/list`), not by the
/// business fields. 288 green tests had missed it because the fake engine had
/// been flattened to match the same misreading.
///
/// Every probe here is read-only or targets a nonexistent session, so it fails
/// closed at the domain layer instead of starting real agent work:
///
/// - correct shape → a domain verdict (`session/not-found`, `ok null`, …)
/// - wrong shape   → `gateway/arguments-invalid`
///
/// Skip discipline (repo convention): no engine on the port → SKIP with a
/// printed reason, never a silent pass.
const engineOrigin = 'http://127.0.0.1:3080';

/// Build a client that talks straight to a local engine, bypassing the relay.
///
/// Plain http means the TOFU pin table is never consulted, so the real
/// [RelayClient] works unchanged — no test double on the transport, only the
/// endpoint address differs. The mux is constructed but never started: this
/// suite is unary-only, and an unstarted mux opens no socket.
EngineClient? _liveClient() {
  final origin = Uri.parse(engineOrigin);
  final pinned = PinnedHttpClient(pinTable: const {});
  return EngineClient(
    rpc: EngineRpc(
      relay: RelayClient(
        origin: origin,
        pinned: pinned,
        bearerProvider: () async => null,
      ),
    ),
    mux: EngineMux(
      origin: origin,
      pinned: pinned,
      bearerProvider: () async => null,
    ),
  );
}

Future<bool> _engineIsUp() async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('$engineOrigin/'));
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode == 200;
  } on SocketException {
    return false;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late EngineClient engine;

  setUpAll(() async {
    final up = await _engineIsUp();
    if (!up) {
      markTestSkipped('no dsh engine on $engineOrigin (skip reason)');
    }
    engine = _liveClient()!;
  });

  test('the shared channel is a prefix, never a bare POST /api', () async {
    // Confirmed live: POST /api answers 404 while /api/session/list works.
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$engineOrigin/api'));
      req.headers.contentType = ContentType.json;
      req.write('{}');
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 404);
    } finally {
      client.close(force: true);
    }
  });

  test('session/list needs the _request wrapper, not {}', () async {
    // The regression this suite exists for: a flat or empty `args` is refused.
    final flat = await _raw(engine, 'session/list', const {});
    expect(flat.error!.code, 'gateway/arguments-invalid');

    final nested = await _raw(engine, 'session/list', {'_request': const {}});
    expect(nested.isOk, isTrue,
        reason: 'real rows prove the wrapper name: ${nested.error}');
  });

  test('listSessions decodes the real machine\'s rows', () async {
    final result = await engine.listSessions();
    expect(result.isOk, isTrue, reason: '${result.error}');
    final items = (result.value! as Map<String, dynamic>)['items']! as List<SessionSummary>;
    for (final item in items) {
      expect(item.sessionId, isNotEmpty);
      expect(item.updatedAt, greaterThan(0));
    }
  });

  test('session/projections on an unknown session is ok null, not a failure',
      () async {
    final result = await engine.projections('__probe_no_such_session__');
    expect(result.isOk, isTrue, reason: '${result.error}');
    expect(result.value, isNull);
  });

  test('business fields nest under `request` for every endpoint', () async {
    // Flat args are refused; the nested form reaches the domain and yields
    // the domain's own verdict.
    final flat = await _raw(engine, 'session/cancel', {'sessionId': 'nope'});
    expect(flat.error!.code, 'gateway/arguments-invalid');

    final nested = await _raw(engine, 'session/cancel', {
      'request': {'sessionId': '__probe_no_such_session__'},
    });
    expect(nested.isOk, isFalse);
    expect(nested.error!.code, 'session/not-found',
        reason: 'a real domain verdict proves the shape was accepted');
  });

  test('the real error code folds into the app error model', () async {
    final result = await engine.projections('__probe_no_such_session__');
    expect(result.isOk, isTrue);

    final flat = await _raw(engine, 'session/rename', {
      'request': {'sessionId': '__probe_no_such_session__', 'title': 'x'},
    });
    expect(flat.error!.code, 'session/not-found');
    expect(flat.error!.toAppError().code.name, 'engineSessionGone');
  });

  test('job/kill and subagents/prompt use the same nesting', () async {
    final job = await _raw(engine, 'job/kill', {
      'request': {'sessionId': 'nope', 'jobId': 'nope'},
    });
    expect(job.error!.code, 'job/not-found');

    final sub = await _raw(engine, 'subagents/prompt', {
      'request': {
        'requestId': 'probe',
        'parentSessionId': '__probe_none__',
        'childSessionId': 'child',
        'mode': 'continuable',
        'delivery': 'queue',
        'content': [
          {'type': 'text', 'text': 'x'},
        ],
      },
    });
    expect(sub.error!.code, 'subagent/parent-unavailable');
  });

  test('modelCatalog takes no wrapper and comes entirely from the engine',
      () async {
    final result = await engine.modelCatalog();
    expect(result.isOk, isTrue, reason: '${result.error}');

    final catalog = result.value! as ModelCatalog;
    expect(catalog.defaultSelection.provider, isNotEmpty);
    expect(catalog.defaultSelection.model, isNotEmpty);
    expect(catalog.groups, isNotEmpty,
        reason: 'the machine has configured providers');
    // Efforts are engine-defined; the App must not assume four fixed levels.
    for (final group in catalog.groups) {
      for (final model in group.models) {
        for (final effort in model.efforts) {
          expect(effort.id, isNotEmpty);
        }
      }
    }
  });

  test('a stream endpoint called unary fails on arguments first', () async {
    // Order verified live: the engine validates `args` before the signature,
    // so an empty-args probe reports the missing parameter, not signature.
    final emptyArgs = await _raw(engine, 'session/follow', const {});
    expect(emptyArgs.error!.code, 'gateway/arguments-invalid');

    final wellFormed = await _raw(engine, 'session/follow', {
      'request': {
        'address': {'kind': 'session', 'sessionId': '__probe_none__'},
      },
    });
    expect(wellFormed.error!.code, 'gateway/signature-invalid');
  });
}

/// Issue a raw call with explicit args, bypassing the facade's wrapping — used
/// to prove which shape the engine accepts.
Future<EngineRpcResult> _raw(EngineClient engine, String method, Map<String, dynamic> args) =>
    engine.rpc.call(method, args: args);
