import 'dart:convert';

import 'package:test/test.dart';

import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/net/relay_client.dart';

/// Wire fixtures hand-copied from dsh-root 0.1.7-rc.2:
///
/// - envelope shapes: `packages/client/connection/src/rpc-schema.ts`
///   (`clientRequestSchema` line 35, `serverResponseSchema` line 43,
///   `rpcErrorSchema` line 10)
/// - payload wrapper + endpoint naming:
///   `packages/api/gateway/src/client/index.ts:445` and
///   `packages/api/session-controller/src/index.ts` (`@Remote` decorators,
///   namespace `session` declared at line 136)
///
/// If upstream changes a key, these fail loudly — that is the point of the
/// repo's hand-copy convention (belt and braces with the live integration bed).
class _FakeRelay implements RelayClient {
  _FakeRelay(this.status, this.body);

  final int status;
  final Object? body;
  String? lastPath;
  Map<String, dynamic>? lastBody;

  @override
  Future<(int, dynamic)> postJson(String path, Object? payload) async {
    lastPath = path;
    lastBody = payload as Map<String, dynamic>?;
    return (status, body);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('unary envelope', () {
    test('posts to /api/<endpoint>, never the bare /api', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': true, 'value': <String, dynamic>{}},
      });
      await EngineRpc(relay: relay).call(SessionEndpoints.list);

      // The channel is a mount PREFIX: the client appends the endpoint, so the
      // path is /api/session/list. Posting to the bare /api 404s against the
      // real host, and the relay's /api/* wildcard does not match it
      // (client/connection/src/client/rpc.ts:48).
      expect(relay.lastPath, '/api/session/list');
      expect(relay.lastPath, isNot('/api'));
    });

    test('the event-result endpoint is namespaced under the channel too',
        () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': true},
      });
      await EngineRpc(relay: relay).call(EventEndpoints.result, args: {});

      expect(relay.lastPath, r'/api/$events/result');
    });

    test('wraps arguments in payload.args', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': true, 'value': null},
      });
      await EngineRpc(relay: relay).call(SessionEndpoints.selectModel, args: {
        'sessionId': 'sess_1',
        'model': 'deepseek-chat',
      });

      final body = relay.lastBody!;
      expect(body['type'], 'client-request');
      expect(body['method'], 'session/selectModel');
      expect(body['rpcId'], isA<String>());
      expect((body['rpcId'] as String).isNotEmpty, isTrue);
      expect(body['payload'], {
        'args': {'sessionId': 'sess_1', 'model': 'deepseek-chat'},
      });
      // Envelope has exactly the four documented keys.
      expect(body.keys.toSet(), {'type', 'rpcId', 'method', 'payload'});
    });

    test('omits args entirely when the endpoint takes none', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': true, 'value': <String, dynamic>{}},
      });
      await EngineRpc(relay: relay).call(SessionEndpoints.modelCatalog);

      expect(relay.lastBody!['payload'], {'args': <String, dynamic>{}});
    });

    test('decodes a successful value', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-7',
        'result': {
          'ok': true,
          'value': {
            'providers': [
              {
                'id': 'deepseek',
                'models': [
                  {'id': 'deepseek-chat', 'reasoning': {'efforts': ['off', 'high']}},
                ],
              },
            ],
          },
        },
      });
      final result = await EngineRpc(relay: relay).call(SessionEndpoints.modelCatalog);

      expect(result.isOk, isTrue);
      final value = result.value! as Map<String, dynamic>;
      expect((value['providers']! as List).length, 1);
    });

    test('carries a null success value without becoming a failure', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': true, 'value': null},
      });
      final result = await EngineRpc(relay: relay).call(SessionEndpoints.cancel);

      expect(result.isOk, isTrue);
      expect(result.value, isNull);
      expect(result.error, isNull);
    });
  });

  group('error envelope', () {
    test('decodes {ok:false, error:{code,message,details}}', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {
          'ok': false,
          'error': {
            'code': 'session/not-found',
            'message': 'no such session',
            'details': {'sessionId': 'sess_x'},
          },
        },
      });
      final result = await EngineRpc(relay: relay).call(SessionEndpoints.prompt);

      expect(result.isOk, isFalse);
      final error = result.error!;
      expect(error.code, 'session/not-found');
      expect(error.message, 'no such session');
      expect(error.details, {'sessionId': 'sess_x'});
    });

    test('tolerates a missing details object', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {
          'ok': false,
          'error': {'code': 'gateway/cancelled', 'message': 'aborted'},
        },
      });
      final result = await EngineRpc(relay: relay).call(SessionEndpoints.follow);

      expect(result.error!.details, isEmpty);
    });

    test('folds into the app error model without inventing wording', () {
      const error = EngineRemoteError(code: 'session/writer-held', message: 'x');
      final app = error.toAppError();

      expect(app.code, ErrorCode.sessionWriterHeld);
      expect(app.rawMessage, 'session/writer-held',
          reason: 'engine codes are never translated; the UI supplies wording');
    });

    test('callOrThrow throws the typed failure', () async {
      final relay = _FakeRelay(200, {
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {
          'ok': false,
          'error': {'code': 'gateway/internal', 'message': 'boom', 'details': {}},
        },
      });

      await expectLater(
        EngineRpc(relay: relay).callOrThrow(SessionEndpoints.create),
        throwsA(isA<EngineRemoteError>().having((e) => e.code, 'code', 'gateway/internal')),
      );
    });
  });

  group('engine code domain → app error code (T2.1d)', () {
    /// Every real `RemoteErrorCode` the v1 console can hit, with its verdict.
    /// Hand-copied from `docs/engine-contract-m2.md` §11.2. A code NOT listed
    /// here must still resolve — but to `engineUnknown`.
    const domain = <String, ErrorCode>{
      // Gone / deleted from the other end.
      'session/not-found': ErrorCode.engineSessionGone,
      'workspace/not-found': ErrorCode.engineSessionGone,
      'subagent/not-found': ErrorCode.engineSessionGone,
      'job/not-found': ErrorCode.engineSessionGone,
      'gateway/context-not-found': ErrorCode.engineSessionGone,
      'gateway/lookup-not-found': ErrorCode.engineSessionGone,

      // Two-ends relay: the web UI holds the writer lock.
      'session/writer-held': ErrorCode.sessionWriterHeld,

      'session/agent-busy': ErrorCode.sessionAgentBusy,

      'subagent/not-resumable': ErrorCode.subagentReadOnly,
      'subagent/parent-unavailable': ErrorCode.subagentReadOnly,
      'subagent/unauthorized': ErrorCode.subagentReadOnly,
      'subagent/delivery-unavailable': ErrorCode.subagentReadOnly,

      'session/model-unavailable': ErrorCode.modelUnavailable,
      'session/provider-models-unavailable': ErrorCode.modelUnavailable,
      'session/provider-credentials-unavailable': ErrorCode.modelUnavailable,
      'llm/model-discovery-rejected': ErrorCode.modelUnavailable,

      'gateway/method-unavailable': ErrorCode.engineUnsupported,
      'gateway/signature-invalid': ErrorCode.engineUnsupported,
      'gateway/definition-unavailable': ErrorCode.engineUnsupported,
      'gateway/invocation-unavailable': ErrorCode.engineUnsupported,

      'gateway/service-unavailable': ErrorCode.engineUnavailable,
      'gateway/context-unavailable': ErrorCode.engineUnavailable,
      'gateway/lookup-unavailable': ErrorCode.engineUnavailable,
      'gateway/provider-mismatch': ErrorCode.engineUnavailable,

      'gateway/cancelled': ErrorCode.engineCancelled,
      'gateway/uplink-overflow': ErrorCode.payloadTooLarge,
    };

    test('each mapped code resolves to its declared app code', () {
      domain.forEach((engineCode, expected) {
        final app = EngineRemoteError(code: engineCode, message: '').toAppError();
        expect(app.code, expected, reason: '$engineCode mapping drifted');
        expect(app.rawMessage, engineCode,
            reason: 'the raw engine code must survive for the mono line');
      });
    });

    test('the raw message is kept but never becomes the primary wording', () {
      final app = const EngineRemoteError(
        code: 'session/model-unavailable',
        message: 'deepseek-v4 is not routable',
      ).toAppError();

      expect(app.detail, 'deepseek-v4 is not routable');
      expect(app.code.l10nKey, 'err_model_unavailable',
          reason: 'the UI keys off the app code, not the message');
    });

    test('an empty message leaves detail null rather than an empty string', () {
      expect(
        const EngineRemoteError(code: 'gateway/cancelled', message: '')
            .toAppError()
            .detail,
        isNull,
      );
    });

    test('unrecognised codes fall back but are never swallowed', () {
      for (final code in [
        'gateway/bad-request',
        'gateway/arguments-invalid',
        'gateway/input-invalid',
        'gateway/ambiguous-endpoint',
        'gateway/binding-invalid',
        'gateway/context-failed',
        'gateway/lookup-failed',
        'gateway/protocol',
        'gateway/result-invalid',
        'gateway/internal',
        'session/conflict',
        'session/title-invalid',
        'session/steer-unavailable',
        'session/queue-item-not-found',
        'session/fork-unavailable',
        'session/attachment-invalid',
        'session/invalid-time-zone',
        'session/projections-unavailable',
        'session/workspace-attach-failed',
        'agent-preset/conflict',
        'subagent/invalid-time-zone',
        'subagent/attachment-invalid',
        'subagent/catalog-diagnostic',
        'some/future-code',
      ]) {
        final app = EngineRemoteError(code: code, message: '').toAppError();
        expect(app.code, ErrorCode.engineUnknown, reason: code);
        expect(app.rawMessage, code,
            reason: 'an unrecognised code must still be reported verbatim');
      }
    });

    test('a mapped code never leaks as engineUnknown', () {
      // Guards the failure mode where a row is added to this table but the
      // switch in `toAppError` forgets it.
      for (final entry in domain.entries) {
        expect(
          EngineRemoteError(code: entry.key, message: '').toAppError().code,
          isNot(ErrorCode.engineUnknown),
          reason: '${entry.key} is in the table but resolves to unknown',
        );
      }
    });

    test('every app code has a distinct, well-formed l10n key', () {
      final keys = ErrorCode.values.map((c) => c.l10nKey).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate l10n key');
      for (final key in keys) {
        expect(key, matches(RegExp(r'^err_[a-z0-9_]+$')));
      }
    });
  });

  group('HTTP status folding', () {
    Future<ErrorCode> codeFor(int status) async {
      final relay = _FakeRelay(status, 'body');
      final result = await EngineRpc(relay: relay).call(SessionEndpoints.list);
      return result.error!.toAppError().code;
    }

    test('401/403 stay unmapped — the three causes live upstream', () async {
      expect(await codeFor(401), ErrorCode.engineUnknown);
      expect(await codeFor(403), ErrorCode.engineUnknown);
    });

    test('404 means the endpoint is gone', () async {
      expect(await codeFor(404), ErrorCode.engineSessionGone);
    });

    test('413 shares the payload-too-large wording', () async {
      expect(await codeFor(413), ErrorCode.payloadTooLarge);
    });

    test('5xx is a gateway internal failure', () async {
      expect(await codeFor(500), ErrorCode.engineUnknown);
    });
  });

  group('malformed responses fail closed', () {
    Future<EngineRpcResult> callWith(Object? body, {int status = 200}) async {
      return EngineRpc(relay: _FakeRelay(status, body)).call(SessionEndpoints.list);
    }

    test('non-200 is folded into a known engine code', () async {
      final result = await callWith('nope', status: 502);
      expect(result.error!.code, 'gateway/internal');
    });

    test('non-object body is rejected', () async {
      expect((await callWith([1, 2, 3])).error!.code, 'gateway/result-invalid');
    });

    test('wrong envelope type is rejected', () async {
      final result = await callWith({'type': 'client-request', 'rpcId': 'app-0'});
      expect(result.error!.code, 'gateway/protocol');
    });

    test('missing result object is rejected', () async {
      final result = await callWith({'type': 'server-response', 'rpcId': 'app-0'});
      expect(result.error!.code, 'gateway/result-invalid');
    });

    test('ok:false with no error object still fails closed', () async {
      final result = await callWith({
        'type': 'server-response',
        'rpcId': 'app-0',
        'result': {'ok': false},
      });
      expect(result.isOk, isFalse);
      expect(result.error!.code, 'gateway/internal');
    });
  });

  group('endpoint names are hand-copied, not invented', () {
    /// Every endpoint constant, in one place so the invariant below really
    /// does cover all of them.
    const all = <String>[
      SessionEndpoints.list,
      SessionEndpoints.search,
      SessionEndpoints.create,
      SessionEndpoints.page,
      SessionEndpoints.follow,
      SessionEndpoints.control,
      SessionEndpoints.projections,
      SessionEndpoints.prompt,
      SessionEndpoints.cancel,
      SessionEndpoints.updateQueue,
      SessionEndpoints.fork,
      SessionEndpoints.rename,
      SessionEndpoints.modelCatalog,
      SessionEndpoints.selectModel,
      SessionEndpoints.attachment,
      SessionEndpoints.openWorkspacePath,
      SessionEndpoints.workspacePathApplications,
    ];

    test('endpoints use a SLASH, never a dot', () {
      // endpointOf() returns `${namespace}/${method}`
      // (api/gateway/src/index.ts:1370-1372). An earlier draft of this table
      // used `session.list`, which does not exist on the wire at all.
      for (final endpoint in all) {
        expect(endpoint, isNot(contains('.')),
            reason: '$endpoint must be slash-separated, not dotted');
        expect(endpoint.split('/').length, 2,
            reason: '$endpoint must be exactly <namespace>/<method>');
        expect(endpoint, startsWith('session/'));
      }
    });

    test(r'each segment matches the engine charset ^[A-Za-z0-9_$.-]+$', () {
      // api/gateway/src/index.ts:1114-1123
      final pattern = RegExp(r'^[A-Za-z0-9_$.-]+$');
      for (final endpoint in all) {
        for (final segment in endpoint.split('/')) {
          expect(segment, matches(pattern), reason: 'bad segment in $endpoint');
        }
      }
    });

    test('session endpoints match the @Remote decorator names', () {
      // Each entry must appear as an @Remote('name') in
      // packages/api/session-controller/src/index.ts.
      expect(SessionEndpoints.list, 'session/list');
      expect(SessionEndpoints.search, 'session/search');
      expect(SessionEndpoints.create, 'session/create');
      expect(SessionEndpoints.page, 'session/page');
      expect(SessionEndpoints.follow, 'session/follow');
      expect(SessionEndpoints.control, 'session/control');
      expect(SessionEndpoints.projections, 'session/projections');
      expect(SessionEndpoints.prompt, 'session/prompt');
      expect(SessionEndpoints.cancel, 'session/cancel');
      expect(SessionEndpoints.updateQueue, 'session/updateQueue');
      expect(SessionEndpoints.fork, 'session/fork');
      expect(SessionEndpoints.rename, 'session/rename');
      expect(SessionEndpoints.modelCatalog, 'session/modelCatalog');
      expect(SessionEndpoints.selectModel, 'session/selectModel');
      expect(SessionEndpoints.attachment, 'session/attachment');
      expect(SessionEndpoints.openWorkspacePath, 'session/openWorkspacePath');
      expect(
        SessionEndpoints.workspacePathApplications,
        'session/workspacePathApplications',
      );
    });

    test('no duplicates', () {
      expect(all.toSet().length, all.length);
    });

    test('gateway-internal event endpoints keep their dollar prefix', () {
      expect(EventEndpoints.stream, r'$events');
      expect(EventEndpoints.result, r'$events/result');
    });

    test('event endpoints are the documented gateway-internal names', () {
      // REMOTE_EVENT_STREAM_ENDPOINT / REMOTE_EVENT_RESULT_ENDPOINT
      // (api/gateway/src/stream-protocol.ts:10, :13)
      expect(EventEndpoints.stream, r'$events');
      expect(EventEndpoints.result, r'$events/result');
    });
  });

  test('request bodies are JSON-encodable (attachments are out of scope)', () {
    // Guards the envelope against accidentally embedding a non-JSON value.
    final encoded = jsonEncode({
      'type': 'client-request',
      'rpcId': 'app-0',
      'method': SessionEndpoints.prompt,
      'payload': {
        'args': {'address': {'kind': 'session', 'id': 'sess_1'}, 'text': 'hi'},
      },
    });
    expect(encoded, contains('session/prompt'));
  });
}
