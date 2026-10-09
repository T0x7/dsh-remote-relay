import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:test/test.dart';

import '../harness/relay_harness.dart';

/// T2.1e — the M2 engine control plane against the REAL relay + a fake engine
/// that enforces the same rules the real host does.
///
/// The unit tests prove the Dart side decodes what it *thinks* the wire looks
/// like. These prove the wire actually carries it, end to end:
/// phone → relay gate → PSK tunnel → fake engine, for both transports
/// (unary JSON-RPC on `/api`, multiplexed streams on `/api/remote.mux`).
///
/// The fake engine rejects a malformed envelope, a surplus `args` key, and a
/// stream endpoint called unary — so a passing test here means the App and the
/// contract agree, not merely that the App agrees with itself.
void main() {
  late RelayHarness h;
  late PinnedHttpClient pinned;
  late RelayClient relay;
  late EngineClient engine;
  late EngineMux mux;

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
    final params = parseSignedUrl(h.mintPairingUrl());
    pinned = PinnedHttpClient.fromStore(MemoryPinStore());
    relay = RelayClient(
      origin: h.relayOrigin,
      pinned: pinned,
      bearerProvider: () async => params.bearer,
    );
    mux = EngineMux(
      origin: h.relayOrigin,
      pinned: pinned,
      bearerProvider: () async => params.bearer,
    );
    engine = EngineClient(
      rpc: EngineRpc(relay: relay),
      mux: mux,
    );
  });

  tearDown(() async {
    mux.dispose();
    await h.stop();
    pinned.close();
  });

  group('unary control plane over the relay', () {
    test('create → list → the session is visible end to end', () async {
      final created = await engine.createSession(cwd: '/fake/workspace');
      expect(created.isOk, isTrue, reason: '${created.error}');
      final sessionId = (created.value! as Map<String, dynamic>)['sessionId'];
      expect(sessionId, isNotEmpty);

      final listed = await engine.listSessions();
      expect(listed.isOk, isTrue);
      final items = (listed.value! as Map<String, dynamic>)['items']! as List<SessionSummary>;
      expect(items.any((s) => s.sessionId == sessionId), isTrue);
    });

    test('prompt → follow sees the durable events', () async {
      await engine.createSession(sessionId: 'session-e2e');
      expect((await engine.createSession(sessionId: 'session-e2e')).isOk, isTrue);

      final stream = engine.follow(address: const PlainSessionAddress('session-e2e'));
      final first = await stream.frames.first.timeout(const Duration(seconds: 10));
      expect(first, isA<FollowSnapshot>());

      // Subscribe BEFORE prompting: the frame stream is a broadcast, so a
      // listener attached after the send would miss the events entirely.
      final events = <SessionWireEvent>[];
      final sub = stream.frames.listen((frame) {
        if (frame is FollowEvent) events.add(frame.event);
      });

      final sent = await engine.prompt(
        sessionId: 'session-e2e',
        content: [const PromptContentPart.text('hello from the app')],
      );
      expect(sent.isOk, isTrue, reason: '${sent.error}');

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (events.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await sub.cancel();
      stream.cancel();

      expect(events.map((e) => e.type), containsAll(['user/message', 'assistant/message']));
      final user = events.firstWhere((e) => e.type == 'user/message');
      // Real UserMessage shape: the text lives in a content block, not a flat
      // field (llm/llm/src/message.ts:162-164).
      final text = (user.dataObject['content']! as List)
          .whereType<Map<String, dynamic>>()
          .where((block) => block['type'] == 'text')
          .map((block) => block['text'])
          .join();
      expect(text, 'hello from the app');
    });

    test('projections decode with presence, not zero-collapse', () async {
      await engine.createSession(sessionId: 'session-proj');
      final result = await engine.projections('session-proj');

      expect(result.isOk, isTrue);
      final baseline = result.value! as SessionProjectionBaseline;
      expect(baseline.values.has('contextPressure'), isTrue);
      expect(baseline.values.contextPressure!.contextWindow, 128000);
      expect(baseline.values.has('subagentCatalog'), isTrue,
          reason: 'an empty array is a real value, distinct from absent');
      expect(baseline.values.has('some/unknown-capability'), isFalse);
    });

    test('an unknown session reads as null, not a failure', () async {
      final result = await engine.projections('session-does-not-exist');
      expect(result.isOk, isTrue);
      expect(result.value, isNull);
    });

    test('modelCatalog arrives with no built-in fallback list', () async {
      final result = await engine.modelCatalog();
      expect(result.isOk, isTrue);

      final catalog = result.value! as ModelCatalog;
      expect(catalog.groups, isNotEmpty);
      expect(catalog.defaultSelection.model, 'deepseek-v4');
      expect(catalog.failures.single.id, 'openai',
          reason: 'a failed provider is isolated, not fatal');
      final model = catalog.findModel('deepseek-official', 'deepseek-v4')!;
      expect(model.efforts.map((e) => e.id), ['low', 'high']);
      expect(catalog.findModel('deepseek-official', 'plain-model')!.efforts, isEmpty);
    });

    test('selectModel returns the engine-normalized selection', () async {
      await engine.createSession(sessionId: 'session-model');
      final result = await engine.selectModel(
        sessionId: 'session-model',
        provider: 'deepseek-official',
        model: 'deepseek-v4',
        reasoningEffort: 'high',
      );

      expect(result.isOk, isTrue);
      final selected = result.value! as ModelSelection;
      expect(selected.reasoningEffort, 'high');
    });

    test('a surplus business field is rejected, not swallowed', () async {
      // The host validates the request object against the endpoint's declared
      // parameters (api/gateway/src/index.ts:1465-1491). If the App ever
      // starts sending an extra field, this goes red.
      final result = await EngineRpc(relay: relay).call(
        SessionEndpoints.cancel,
        args: {
          'request': {'sessionId': 's1', 'bogusField': true},
        },
      );

      expect(result.isOk, isFalse);
      expect(result.error!.code, 'gateway/arguments-invalid');
      expect(result.error!.details['field'], 'bogusField');
    });

    test('a flat business field at the top level is also rejected', () async {
      // The real engine (dsh 0.1.7-rc.2, verified live) keys `args` by the
      // endpoint's declared parameter name. A flat `{sessionId}` — what this
      // App originally sent — never reaches the domain.
      final result = await EngineRpc(relay: relay).call(
        SessionEndpoints.cancel,
        args: {'sessionId': 's1'},
      );

      expect(result.isOk, isFalse);
      expect(result.error!.code, 'gateway/arguments-invalid');
    });

    test('calling a stream endpoint as unary is a signature mismatch', () async {
      // Argument validation runs first, so the call must be well formed to
      // reach the signature check — matching the engine's own ordering.
      final result = await EngineRpc(relay: relay).call(
        SessionEndpoints.follow,
        args: {
          'request': {
            'address': {'kind': 'session', 'sessionId': 's1'},
          },
        },
      );

      expect(result.isOk, isFalse);
      expect(result.error!.code, 'gateway/signature-invalid');
      expect(result.error!.toAppError().code, ErrorCode.engineUnsupported);
    });

    test('an unknown endpoint is a 404, folded into "gone"', () async {
      final result = await EngineRpc(relay: relay).call('session/nope');

      expect(result.isOk, isFalse);
      expect(result.error!.toAppError().code, ErrorCode.engineSessionGone);
    });

    test('null args are normalized to an empty map, never sent as null',
        () async {
      final result = await EngineRpc(relay: relay).call(
        SessionEndpoints.list,
        args: null,
      );
      expect(result.isOk, isFalse,
          reason: 'the engine still requires the _request wrapper');
    });
  });

  group('mux streams over the relay', () {
    test('follow opens with exactly one snapshot', () async {
      await engine.createSession(sessionId: 'session-mux');
      final stream = engine.follow(address: const PlainSessionAddress('session-mux'));

      final first = await stream.frames.first.timeout(const Duration(seconds: 10));
      expect(first, isA<FollowSnapshot>());

      final snapshot = first as FollowSnapshot;
      expect(snapshot.header.version, 4);
      expect(snapshot.header.id, 'session-mux');
      expect(snapshot.projections.asOfSeq, isA<int>());
      expect(snapshot.assistantStream, isNotNull,
          reason: 'assistantStream:true was requested, so the baseline must ride along');
      stream.cancel();
    });

    test('control opens with a baseline frame', () async {
      await engine.createSession(sessionId: 'session-control');
      final stream = engine.control();

      final first = await stream.items.first.timeout(const Duration(seconds: 10));
      expect(asObject(first)?['type'], 'baseline');
      stream.cancel();
    });

    test(r'the $events stream opens with a ready frame carrying a clientId',
        () async {
      final stream = engine.openEventStream();
      final first = await stream.items.first.timeout(const Duration(seconds: 10));

      final ready = asObject(first)!;
      expect(ready['type'], 'ready');
      expect(ready['clientId'], isA<String>());
      expect(asObject(ready['host'])?.containsKey('home'), isTrue);
      stream.cancel();
    });

    test('a non-stream endpoint opened as a stream is a signature mismatch',
        () async {
      final stream = mux.open(SessionEndpoints.list);
      final error = await stream.errors.first.timeout(const Duration(seconds: 10));

      expect(error.code, 'gateway/signature-invalid');
    });

    test('an unknown stream endpoint is method-unavailable', () async {
      final stream = mux.open('session/nope');
      final error = await stream.errors.first.timeout(const Duration(seconds: 10));

      expect(error.code, 'gateway/method-unavailable');
      expect(MuxStreamError(code: error.code, message: error.message).toAppError().code,
          ErrorCode.engineUnsupported);
    });

    test('several logical streams share one socket', () async {
      await engine.createSession(sessionId: 'session-a');
      await engine.createSession(sessionId: 'session-b');

      final a = engine.follow(address: const PlainSessionAddress('session-a'));
      final b = engine.follow(address: const PlainSessionAddress('session-b'));
      final c = engine.control();

      final frames = await Future.wait([
        a.frames.first.timeout(const Duration(seconds: 10)),
        b.frames.first.timeout(const Duration(seconds: 10)),
        c.items.first.timeout(const Duration(seconds: 10)),
      ]);

      expect((frames[0] as FollowSnapshot).header.id, 'session-a');
      expect((frames[1] as FollowSnapshot).header.id, 'session-b');
      expect(asObject(frames[2])?['type'], 'baseline');

      a.cancel();
      b.cancel();
      c.cancel();
    });
  });

  group('approval waterfall round trip', () {
    /// Attach ONE listener for the whole exchange: the mux item stream is a
    /// broadcast, so consuming `ready` with `.first` and re-subscribing would
    /// silently drop every frame raised in between.
    Future<_EventSink> openEvents() async {
      final stream = engine.openEventStream();
      final sink = _EventSink(stream);
      await sink.ready;
      return sink;
    }

    test('an approval request arrives and the bare answer goes back',
        () async {
      final sink = await openEvents();

      final eventId = await raiseWaterfall(h.enginePort, {
        'event': 'approval/request',
        'request': {
          'toolName': 'write_file',
          'callId': 'call-1',
          'reason': 'writes outside workspace',
        },
      });

      final frame = await sink.nextWaterfall();
      expect(frame['event'], 'approval/request');
      expect(frame['eventId'], eventId);

      final request = ApprovalRequest.fromJson(asObject(frame['request'])!);
      expect(request.toolName, 'write_file');
      expect(request.textFor('en'), 'writes outside workspace');

      // The answer is the BARE wire string, not an envelope.
      final answered = await engine.answerEvent(
        clientId: sink.clientId,
        eventId: eventId,
        value: ApprovalOutcome.allowedOnce.wire,
      );
      expect(answered.isOk, isTrue, reason: '${answered.error}');

      final mine = (await answeredWaterfalls(h.enginePort))
          .firstWhere((r) => r['eventId'] == eventId);
      expect(mine['kind'], 'result');
      expect(mine['value'], 'allowed-once');

      sink.close();
    });

    test('a declined question is rejected with the plan-mode code', () async {
      final sink = await openEvents();

      final eventId = await raiseWaterfall(h.enginePort, {
        'event': 'user-questions/request',
        'request': {
          'questions': [
            {
              'id': 'q1',
              'question': 'Which environments?',
              'options': [
                {'label': 'staging'},
                {'label': 'prod'},
              ],
            },
          ],
        },
      });

      await sink.nextWaterfall();

      final rejected = await engine.rejectEvent(
        clientId: sink.clientId,
        eventId: eventId,
        message: 'user abandoned',
      );
      expect(rejected.isOk, isTrue, reason: '${rejected.error}');

      final mine = (await answeredWaterfalls(h.enginePort))
          .firstWhere((r) => r['eventId'] == eventId);
      expect(mine['kind'], 'rejected');

      sink.close();
    });

    test('a question answer round-trips as {answers:[...]}', () async {
      final sink = await openEvents();

      final eventId = await raiseWaterfall(h.enginePort, {
        'event': 'user-questions/request',
        'request': {
          'questions': [
            {
              'id': 'plan-review',
              'question': 'Approve this plan?',
              'detail': '# plan',
              'options': [
                {'label': 'Approve'},
                {'label': 'Keep planning'},
              ],
              'intent': {'kind': 'plan-review', 'approve': 'Approve'},
            },
          ],
        },
      });

      final frame = await sink.nextWaterfall();
      final request = asObject(frame['request'])!;
      final question = AskUserQuestionItem.fromJson(
        (request['questions']! as List).first as Map<String, dynamic>,
      );

      final review = PlanReview.of([question]);
      expect(review, isNotNull, reason: 'the payload meets all six conditions');
      expect(review!.approve, 'Approve');
      expect(review.decline, 'Keep planning');

      final answered = await engine.answerEvent(
        clientId: sink.clientId,
        eventId: eventId,
        value: AskUserQuestionAnswer([
          AskUserQuestionAnswerItem(id: question.id, selected: [review.approve]),
        ]).toJson(),
      );
      expect(answered.isOk, isTrue, reason: '${answered.error}');

      final mine = (await answeredWaterfalls(h.enginePort))
          .firstWhere((r) => r['eventId'] == eventId);
      expect(mine['value'], {
        'answers': [
          {'id': 'plan-review', 'selected': ['Approve']},
        ],
      });

      sink.close();
    });
  });

  group('subagent read-only rule against a real host', () {
    test('a one-shot child is refused with subagent/not-resumable', () async {
      // The App pins the literal `continuable` on the wire, so the rejection
      // can only come from the CHILD's real mode — which is exactly why the
      // App derives read-only from the catalog rather than from the request.
      await registerSubagent(
        h.enginePort,
        childSessionId: 'child-one-shot',
        parentSessionId: 'session-parent',
        mode: 'one-shot',
      );

      final result = await engine.promptSubagent(
        parentSessionId: 'session-parent',
        childSessionId: 'child-one-shot',
        content: [const PromptContentPart.text('hi')],
      );

      expect(result.isOk, isFalse);
      expect(result.error!.code, 'subagent/not-resumable');
      expect(result.error!.toAppError().code, ErrorCode.subagentReadOnly);
    });

    test('a continuable child with a live parent is accepted', () async {
      await registerSubagent(
        h.enginePort,
        childSessionId: 'child-open',
        parentSessionId: 'session-parent',
        mode: 'continuable',
      );

      final result = await engine.promptSubagent(
        parentSessionId: 'session-parent',
        childSessionId: 'child-open',
        content: [const PromptContentPart.text('hi')],
      );

      expect(result.isOk, isTrue, reason: '${result.error}');
    });

    test('a missing parent is subagent/parent-unavailable', () async {
      await registerSubagent(
        h.enginePort,
        childSessionId: 'child-orphan',
        parentSessionId: 'session-parent',
        mode: 'continuable',
      );

      final result = await engine.promptSubagent(
        parentSessionId: 'session-nobody',
        childSessionId: 'child-orphan',
        content: [const PromptContentPart.text('hi')],
      );

      expect(result.error!.code, 'subagent/parent-unavailable');
      expect(result.error!.toAppError().code, ErrorCode.subagentReadOnly);
    });
  });

  group('jobs', () {
    test('job/list opens with a wholesale row frame', () async {
      await engine.createSession(sessionId: 'session-jobs');
      final stream = engine.listJobs(sessionId: 'session-jobs');

      final first = await stream.items.first.timeout(const Duration(seconds: 10));
      final frame = asObject(first)!;
      expect(frame['type'], 'rows');
      final jobs = (frame['jobs']! as List)
          .whereType<Map<String, dynamic>>()
          .map(JobView.fromJson)
          .toList();
      expect(jobs.map((j) => j.state).toSet(),
          {JobCardState.running, JobCardState.done, JobCardState.failed});
      stream.cancel();
    });
  });

  group('gate still applies to the M2 surface', () {
    test('no credentials is refused before reaching the engine', () async {
      final anonymous = RelayClient(
        origin: h.relayOrigin,
        pinned: PinnedHttpClient.fromStore(MemoryPinStore()),
        bearerProvider: () async => null,
      );
      final (status, _) = await anonymous.postJson('/api', {'type': 'client-request'});
      expect(status, 401, reason: 'the M2 channel sits behind the same gate');
    });
  });
}

/// Collects every frame on a `$events` stream from a single subscription.
///
/// The mux item stream is a broadcast: consuming `ready` with `.first` and
/// then re-subscribing would drop every frame raised in between, which is
/// exactly the shape of a flaky test rather than a real failure.
class _EventSink {
  _EventSink(MuxStream stream) {
    stream.items.listen((value) {
      final frame = asObject(value);
      if (frame == null) return;
      _frames.add(frame);
      if (frame['type'] == 'ready' && !_ready.isCompleted) {
        _ready.complete(frame);
      }
      // Satisfy any waiter registered before this frame arrived.
      for (final waiter in List<Completer<Map<String, dynamic>>>.from(_waiters)) {
        if (frame['type'] == 'waterfall' && !waiter.isCompleted) {
          _waiters.remove(waiter);
          waiter.complete(frame);
        }
      }
    });
  }

  final List<Map<String, dynamic>> _frames = [];
  final List<Completer<Map<String, dynamic>>> _waiters = [];
  final Completer<Map<String, dynamic>> _ready = Completer<Map<String, dynamic>>();

  String? _clientId;

  Future<Map<String, dynamic>> get ready async {
    final frame = await _ready.future.timeout(const Duration(seconds: 10));
    _clientId = frame['clientId']! as String;
    return frame;
  }

  String get clientId => _clientId!;

  /// The next `waterfall` frame raised after this call.
  Future<Map<String, dynamic>> nextWaterfall() {
    final already = _frames.where((f) => f['type'] == 'waterfall');
    if (already.isNotEmpty) {
      return Future<Map<String, dynamic>>.value(already.last);
    }
    final waiter = Completer<Map<String, dynamic>>();
    _waiters.add(waiter);
    return waiter.future.timeout(const Duration(seconds: 10));
  }

  void close() {}
}

/// Test-only control surface of the fake engine, outside the engine contract.
Future<String> raiseWaterfall(int enginePort, Map<String, dynamic> spec) async {  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$enginePort/__test/waterfall'),
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(spec));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return (jsonDecode(body) as Map<String, dynamic>)['eventId']! as String;
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> answeredWaterfalls(int enginePort) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$enginePort/__test/answered'),
    );
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } finally {
    client.close(force: true);
  }
}

/// Register a subagent child with a given lifecycle mode.
Future<void> registerSubagent(
  int enginePort, {
  required String childSessionId,
  String? parentSessionId,
  required String mode,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$enginePort/__test/subagent'),
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'childSessionId': childSessionId,
      if (parentSessionId != null) 'parentSessionId': parentSessionId,
      'mode': mode,
    }));
    final res = await req.close();
    await utf8.decoder.bind(res).join();
  } finally {
    client.close(force: true);
  }
}
