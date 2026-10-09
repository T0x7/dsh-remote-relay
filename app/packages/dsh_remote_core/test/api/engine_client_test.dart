import 'package:test/test.dart';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';

/// Records what the facade sent and replays a scripted response, so the tests
/// assert the *request* shape (which is where contract drift bites) without a
/// live engine.
class _FakeRelay implements RelayClient {
  _FakeRelay(this.value, {this.error});

  final Object? value;
  final EngineRemoteError? error;
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<(int, dynamic)> postJson(String path, Object? payload) async {
    bodies.add(payload! as Map<String, dynamic>);
    final failure = error;
    final envelope = {
      'type': 'server-response',
      'rpcId': 'r',
      'result': failure == null
          ? {'ok': true, 'value': value}
          : {
              'ok': false,
              'error': {
                'code': failure.code,
                'message': failure.message,
                'details': failure.details,
              },
            },
    };
    return (200, envelope);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EngineClient _client(_FakeRelay relay) => EngineClient(
      rpc: EngineRpc(relay: relay),
      mux: EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
      ),
    );

void main() {
  test('prompt sends the required wire fields', () async {
    final relay = _FakeRelay(null);
    final client = _client(relay);

    await client.prompt(
      sessionId: 's1',
      content: [const PromptContentPart.text('hello')],
    );

    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args['sessionId'], 's1');
    expect(args['mode'], 'queue');
    expect(args['content'], [
      {'type': 'text', 'text': 'hello'},
    ]);
    expect(args['requestId'], isA<String>());
    expect(args.keys.toSet(), {'requestId', 'sessionId', 'mode', 'content'});
  });

  test('steer mode and time zone ride along when provided', () async {
    final relay = _FakeRelay(null);
    await _client(relay).prompt(
      sessionId: 's1',
      content: [const PromptContentPart.text('go')],
      mode: PromptDelivery.steer,
      clientTimeZone: 'Asia/Shanghai',
    );

    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args['mode'], 'steer');
    expect(args['clientTimeZone'], 'Asia/Shanghai');
  });

  test('omitting optional prompt fields keeps them off the wire', () async {
    // `args` keys must match the endpoint's declared names exactly; a surplus
    // key is `gateway/arguments-invalid`.
    final relay = _FakeRelay(null);
    await _client(relay)
        .prompt(sessionId: 's1', content: [const PromptContentPart.text('x')]);

    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args.containsKey('clientTimeZone'), isFalse);
  });

  test('create omits unset optionals rather than sending nulls', () async {
    final relay = _FakeRelay({'sessionId': 'new-1'});
    await _client(relay).createSession(cwd: '/p');

    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args, {'cwd': '/p'});
  });

  test('list decodes into typed summaries', () async {
    final relay = _FakeRelay({
      'items': [
        {
          'sessionId': 's1',
          'updatedAt': 10,
          'running': true,
          'blank': false,
          'agentAvailable': true,
        },
      ],
    });
    final result = await _client(relay).listSessions();

    final value = result.value! as Map<String, dynamic>;
    final items = value['items']! as List<SessionSummary>;
    expect(items.single.sessionId, 's1');
    expect(items.single.running, isTrue);
  });

  test('list tolerates a missing items array', () async {
    final relay = _FakeRelay(const {});
    final result = await _client(relay).listSessions();

    expect((result.value! as Map<String, dynamic>)['items'], isEmpty);
  });

  test('projections decode into a typed baseline', () async {
    final relay = _FakeRelay({
      'asOfSeq': 42,
      'values': {
        'contextPressure': {
          'pressureTokens': 1000,
          'projectedTokens': 2000,
          'contextWindow': 8000,
        },
      },
    });
    final result = await _client(relay).projections('s1');

    final baseline = result.value! as SessionProjectionBaseline;
    expect(baseline.asOfSeq, 42);
    expect(baseline.values.contextPressure!.fillRatio, closeTo(0.25, 1e-9));
    expect(baseline.values.tokenUsage, isNull);
  });

  test('an unknown session decodes projections as null, not a throw', () async {
    final relay = _FakeRelay(null);
    final result = await _client(relay).projections('nope');

    expect(result.isOk, isTrue);
    expect(result.value, isNull);
  });

  test('selectModel returns the engine-normalized selection', () async {
    final relay = _FakeRelay({
      'selected': {
        'provider': 'deepseek-official',
        'model': 'deepseek-v4',
        'reasoningEffort': 'high',
      },
    });
    final result = await _client(relay).selectModel(
      sessionId: 's1',
      provider: 'deepseek-official',
      model: 'deepseek-v4',
      reasoningEffort: 'high',
    );

    expect((result.value! as ModelSelection).reasoningEffort, 'high');
    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args.keys.toSet(), {'sessionId', 'provider', 'model', 'reasoningEffort'});
  });

  test('selectModel omits reasoningEffort to mean "use the default"', () async {
    // `defaultEffort` absent from the request = the route's own default.
    final relay = _FakeRelay({
      'selected': {'provider': 'p', 'model': 'm'},
    });
    await _client(relay)
        .selectModel(sessionId: 's1', provider: 'p', model: 'm');

    final wire = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    // The engine keys `args` by the endpoint's declared parameter name
    // (verified live against dsh 0.1.7-rc.2), not by the business fields.
    final args = (wire['request'] ?? wire['_request'])! as Map<String, dynamic>;
    expect(args.containsKey('reasoningEffort'), isFalse);
  });

  test('approval answers send the bare string, not an envelope', () async {
    final relay = _FakeRelay(null);
    await _client(relay).answerEvent(
      clientId: 'c1',
      eventId: 'e1',
      value: ApprovalOutcome.allowedOnce.wire,
    );

    // D-078: `$events/result` args are the result object BARE — the gateway
    // parses this endpoint before descriptor dispatch, and the official
    // client sends `{args: result}` verbatim (remote-events.ts:218-223).
    // The old `request` wrapper failed parsing as gateway/internal, so every
    // phone approval silently never reached the engine.
    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args['clientId'], 'c1');
    expect(args['eventId'], 'e1');
    expect(args['outcome'], {
      'kind': 'result',
      'value': 'allowed-once',
    });
  });

  test('question answers send {answers:[...]} as the bare value', () async {
    final relay = _FakeRelay(null);
    await _client(relay).answerEvent(
      clientId: 'c1',
      eventId: 'e1',
      value: const AskUserQuestionAnswer([
        AskUserQuestionAnswerItem(id: 'q1', selected: ['staging']),
      ]).toJson(),
    );

    // D-078: `$events/result` args are the result object bare — no wrapper.
    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args['outcome']['value'], {
      'answers': [
        {'id': 'q1', 'selected': ['staging']},
      ],
    });
  });

  test('rejecting a question sends the plan-mode code by default', () async {
    final relay = _FakeRelay(null);
    await _client(relay)
        .rejectEvent(clientId: 'c1', eventId: 'e1', message: 'abandoned');

    // D-078: `$events/result` args are the result object bare — no wrapper.
    final args = relay.bodies.single['payload']['args'] as Map<String, dynamic>;
    expect(args['outcome'], {
      'kind': 'rejected',
      'error': {
        'name': 'UserQuestionError',
        'message': 'abandoned',
        'code': 'ASK_CANCELLED',
      },
    });
  });

  test('subagent prompt pins mode to the continuable literal', () async {
    final relay = _FakeRelay({'messageId': 'm1'});
    await _client(relay).promptSubagent(
      parentSessionId: 'p1',
      childSessionId: 'c1',
      content: [const PromptContentPart.text('go')],
    );

    final body = relay.bodies.single;
    expect(body['method'], 'subagents/prompt');
    final args = (body['payload']['args'] as Map<String, dynamic>)['request']!
        as Map<String, dynamic>;
    expect(args['mode'], 'continuable');
    expect(args['delivery'], 'queue');
  });

  test('interrupt sends three flat wire fields', () async {
    final relay = _FakeRelay({'accepted': true});
    await _client(relay)
        .interruptSubagent(parentSessionId: 'p1', childSessionId: 'c1');

    final body = relay.bodies.single;
    expect(body['method'], 'subagents/interruptByParent');
    final args = (body['payload']['args'] as Map<String, dynamic>)['request']!
        as Map<String, dynamic>;
    expect(args.keys.toSet(), {'childSessionId', 'parentSessionId', 'mode'});
    expect(args['mode'], 'continuable');
  });

  test('an engine failure propagates as a typed error, unmapped', () async {
    final relay = _FakeRelay(
      null,
      error: const EngineRemoteError(
        code: 'subagent/not-resumable',
        message: 'child is one-shot',
        details: {'childSessionId': 'c1'},
      ),
    );
    final result = await _client(relay).promptSubagent(
      parentSessionId: 'p1',
      childSessionId: 'c1',
      content: [const PromptContentPart.text('x')],
    );

    expect(result.isOk, isFalse);
    expect(result.error!.code, 'subagent/not-resumable');
    expect(result.error!.details['childSessionId'], 'c1');
  });

  test('page decodes records and hasMore', () async {
    final relay = _FakeRelay({
      'records': [
        {
          'type': 'event',
          'event': {'type': 'user/message', 'seq': 3, 'time': 1, 'data': <String, dynamic>{}},
        },
      ],
      'hasMore': false,
    });
    final result = await _client(relay).page(
      address: const PlainSessionAddress('s1'),
      throughSeq: 812,
    );

    final value = result.value! as Map<String, dynamic>;
    expect((value['records']! as List).single, isA<FollowEvent>());
    expect(value['hasMore'], isFalse);
  });

  test('kill job returns the outcome word', () async {
    final relay = _FakeRelay({'outcome': 'already-finished'});
    final result =
        await _client(relay).killJob(sessionId: 's1', jobId: 'j1');

    expect((result.value! as Map<String, dynamic>)['outcome'], 'already-finished');
  });
}
