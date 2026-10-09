import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/services/app_lifecycle_gate.dart';
import 'package:dsh_remote_app/services/job_completion_watcher.dart';
import 'package:dsh_remote_app/services/reminder_router.dart';
import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// design §5「切后台即断 WS」— the console holds exactly one carrier, and an app
/// in the background must not hold it: 省电、省流量，也不占 relay 的桥接并发
/// (and the foreground-only reminder model makes a background socket pointless).
///
/// The hard half is the resume. Events that happened while the socket was down
/// must not read as "never happened", and the events that were already on
/// screen must not be rendered twice.
void main() {
  group('AppLifecycleGate', () {
    test('inactive is still foreground; paused/detached are not', () {
      final gate = AppLifecycleGate();
      expect(gate.foreground, isTrue, reason: 'boot state');

      gate.handle(AppLifecycleState.inactive);
      expect(gate.foreground, isTrue, reason: 'iOS app switcher: still visible');

      gate.handle(AppLifecycleState.paused);
      expect(gate.foreground, isFalse);
      expect(gate.suspended, isTrue);

      gate.handle(AppLifecycleState.detached);
      expect(gate.foreground, isFalse, reason: 'no duplicate transition');

      gate.handle(AppLifecycleState.resumed);
      expect(gate.foreground, isTrue);
      expect(gate.suspended, isFalse);
    });

    test('a repeated state is not an event', () {
      var fired = 0;
      final gate = AppLifecycleGate()..addListener(() => fired++);
      gate.handle(AppLifecycleState.paused);
      gate.handle(AppLifecycleState.paused);
      expect(fired, 1);
    });
  });

  group('DshRemoteApp wires the observer', () {
    testWidgets('a paused app closes the gate, a resumed one opens it',
        (tester) async {
      final gate = AppLifecycleGate();
      await tester.pumpWidget(DshRemoteApp(
        store: MachinesStore(repo: InMemoryMachinesRepository()),
        settings: SettingsStore(storage: _MemorySecureStorage()),
        lifecycle: gate,
      ));
      expect(gate.foreground, isTrue);

      await _lifecycle(tester, AppLifecycleState.paused);
      expect(gate.foreground, isFalse);

      await _lifecycle(tester, AppLifecycleState.resumed);
      expect(gate.foreground, isTrue);
    });
  });

  group('ChatController follows the gate (fake gateway: no carrier)', () {
    test('a background pause tears \$events down and the resume re-opens it',
        () async {
      final gateway = _FakeGateway();
      final gate = AppLifecycleGate();
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
        lifecycle: gate,
      );
      addTearDown(controller.dispose);
      controller.startEvents();
      expect(gateway.eventsOpens, 1);

      gate.enterBackground();
      await pumpEventQueue();
      expect(controller.suspended, isTrue);

      gate.enterForeground();
      await pumpEventQueue();
      expect(controller.suspended, isFalse);
      expect(gateway.eventsOpens, 2, reason: 'the waterfall channel is re-opened');
    });
  });

  group('切后台断 WS (real EngineMux over a fake carrier)', () {
    test('background closes the socket, foreground re-opens the journal — and '
        'the events the user missed are still there', () async {
      final carrier = _FakeCarrier();
      final mux = _muxFor(carrier);
      final controller = ChatController(
        gateway: _clientFor(mux),
        eventsRefreshInterval: Duration.zero,
        lifecycle: AppLifecycleGate(),
      );
      addTearDown(controller.dispose);
      final gate = _gateOf(controller);
      controller.startEvents();

      await controller.open('session-1');
      await carrier.settle();
      final follow = _streamIdFor(carrier, 'session/follow');
      expect(follow, isNotNull, reason: 'the console follows the open session');

      // The conversation so far: one user turn.
      carrier.item(follow!, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 'session-1', 'createdAt': 0, 'isSeeded': false},
        'cursor': 1,
        'records': [
          {'event': _userMessageWire(1, '第一句')},
        ],
        'hasMore': false,
      });
      await carrier.settle();
      expect(_textsOf(controller), ['第一句']);

      // ── the app goes to the background ──
      gate.enterBackground();
      await carrier.settle();
      expect(carrier.live, isFalse, reason: 'design §5: 切后台即断 WS');
      expect(controller.suspended, isTrue);

      // The engine keeps working: this event happens while we are away.
      final missed = {'event': _assistantMessageWire(2, '后台期间发生的事')};

      // ── and comes back ──
      gate.enterForeground();
      await carrier.settle();
      expect(carrier.live, isTrue, reason: 'the carrier is dialled again');

      final follow2 = _streamIdFor(carrier, 'session/follow', after: follow);
      expect(follow2, isNotNull,
          reason: 'the resume re-opens the journal (D-027/D-030)');

      // The host answers the re-open with a fresh authoritative snapshot whose
      // window includes everything up to its own cursor.
      carrier.item(follow2!, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 'session-1', 'createdAt': 0, 'isSeeded': false},
        'cursor': 2,
        'records': [
          {'event': _userMessageWire(1, '第一句')},
          missed,
        ],
        'hasMore': false,
      });
      await carrier.settle();

      expect(_textsOf(controller), ['第一句', '后台期间发生的事'],
          reason: 'the missed turn is back, and the turn already on screen is '
              'not drawn twice');
    });

    test('\$events is re-opened on resume, so a still-pending approval returns',
        () async {
      final carrier = _FakeCarrier();
      final mux = _muxFor(carrier);
      final controller = ChatController(
        gateway: _clientFor(mux),
        eventsRefreshInterval: Duration.zero,
        lifecycle: AppLifecycleGate(),
      );
      addTearDown(controller.dispose);
      final gate = _gateOf(controller);
      controller.startEvents();
      await carrier.settle();

      final events = _streamIdFor(carrier, EventEndpoints.stream);
      expect(events, isNotNull, reason: 'the waterfall channel is open');

      gate.enterBackground();
      await carrier.settle();
      expect(carrier.live, isFalse);

      // Raised while the phone was asleep: the host keeps it pending.
      gate.enterForeground();
      await carrier.settle();
      final events2 = _streamIdFor(carrier, EventEndpoints.stream, after: events);
      expect(events2, isNotNull, reason: 'D-030: the waterfall channel is re-opened');

      carrier.item(events2!, {'type': 'ready', 'clientId': 'c1'});
      carrier.item(events2, {
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'evt-1',
        'request': {'title': '写文件', 'command': 'bash', 'detail': 'rm -rf /tmp/x'},
      });
      await carrier.settle();
      expect(controller.pendingApproval, isNotNull,
          reason: 'the approval raised while we were away must not be lost');
    });
  });

  group('重放代数: a re-baseline replaces, it does not append', () {
    test('the second snapshot on one journal re-projects instead of doubling',
        () {
      final controller = ChatController(
        gateway: _FakeGateway(),
        eventsRefreshInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.applyFrame(_snapshot([
        _userMessage(1, '一'),
        _assistantMessage(2, '二'),
      ]));
      expect(_textsOf(controller), ['一', '二']);

      // D-027: after a carrier loss the host re-answers `open` with a fresh
      // snapshot whose window starts from the beginning — the new truth.
      controller.applyFrame(_snapshot([
        _userMessage(1, '一'),
        _assistantMessage(2, '二'),
        _assistantMessage(3, '断线期间'),
      ]));

      expect(_textsOf(controller), ['一', '二', '断线期间']);
    });

    test('a pending approval card survives a re-baseline (\$events owns it)',
        () async {
      final controller = ChatController(
        gateway: _FakeGateway(),
        eventsRefreshInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      controller.startEvents();

      controller.applyFrame(_snapshot([_userMessage(1, '一')]));
      _raiseApproval(controller);
      await pumpEventQueue();

      controller.applyFrame(_snapshot([
        _userMessage(1, '一'),
        _assistantMessage(2, '二'),
      ]));

      expect(controller.pendingApproval, isNotNull,
          reason: 'the card came from \$events, not from the journal window; the '
              'host re-delivers it on the next \$events frame');
      expect(_textsOf(controller), ['一', '二']);
    });
  });

  group('任务完成 (job/list terminal rows)', () {
    test('the first frame only seeds — a job that finished while the app was '
        'closed must not pop a prompt', () {
      final watcher = JobCompletionWatcher();
      expect(watcher.onRows([_job('j1', 'completed', '夜间构建')]), isEmpty);
      expect(
        watcher.onRows([_job('j1', 'completed', '夜间构建')]),
        isEmpty,
        reason: 'still terminal, already seeded',
      );
    });

    test('running → completed is the transition that reminds', () {
      final watcher = JobCompletionWatcher();
      watcher.onRows([_job('j1', 'running', '夜间构建')]);
      final done = watcher.onRows([_job('j1', 'completed', '夜间构建')]);
      expect(done, hasLength(1));
      expect(done.single.jobId, 'j1');
      expect(done.single.title, '夜间构建');
      expect(done.single.failed, isFalse);
      expect(watcher.onRows([_job('j1', 'completed', '夜间构建')]), isEmpty,
          reason: 'rows replace wholesale, so the same finished job arrives on '
              'every poll');
    });

    test('a failure is a completion too, and is flagged as such', () {
      final watcher = JobCompletionWatcher();
      watcher.onRows([_job('j1', 'running', '跑测试')]);
      final done = watcher.onRows([
        JobView(jobId: 'j1', status: 'failed', label: '跑测试', failed: true)
      ]);
      expect(done.single.failed, isTrue);
    });

    test('killed counts as done, pending does not', () {
      final watcher = JobCompletionWatcher();
      watcher.onRows([_job('j1', 'pending', '定时')]);
      expect(watcher.onRows([_job('j1', 'killed', '定时')]), hasLength(1));

      final other = JobCompletionWatcher();
      other.onRows([_job('j2', 'running', '定时')]);
      expect(other.onRows([_job('j2', 'stopping', '定时')]), isEmpty);
    });

    test('a job that disappears and comes back still reminds once', () {
      final watcher = JobCompletionWatcher();
      watcher.onRows([_job('j1', 'running', '构建')]);
      expect(watcher.onRows([]), isEmpty, reason: 'the list is shorter now');
      expect(watcher.onRows([_job('j1', 'completed', '构建')]), hasLength(1));
      expect(watcher.onRows([_job('j1', 'completed', '构建')]), isEmpty);
    });
  });

  group('ChatController feeds the router', () {
    test('a job finishing while the chat tab is open reaches the router',
        () async {
      final gateway = _FakeGateway();
      final router = ReminderRouter();
      addTearDown(router.dispose);
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
        reminders: router,
      );
      addTearDown(controller.dispose);
      controller.startEvents();
      await controller.open('session-1');

      gateway.raiseWatchedJobRows([
        {'id': 'j1', 'status': 'running', 'label': '夜间构建'},
      ]);
      await pumpEventQueue();
      expect(seen, isEmpty);

      gateway.raiseWatchedJobRows([
        {'id': 'j1', 'status': 'completed', 'label': '夜间构建'},
      ]);
      await pumpEventQueue();
      expect(seen.map((r) => r.kind), [ReminderKind.jobFinished]);
      expect(seen.single.detail, '夜间构建');
    });

    test('a muted router is asked for nothing and shows nothing', () async {
      final gateway = _FakeGateway();
      final router = ReminderRouter(enabled: false);
      addTearDown(router.dispose);
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);
      final controller = ChatController(
        gateway: gateway,
        eventsRefreshInterval: Duration.zero,
        reminders: router,
      );
      addTearDown(controller.dispose);
      controller.startEvents();
      await controller.open('session-1');

      gateway.raiseWatchedJobRows([{'id': 'j1', 'status': 'running', 'label': 'x'}]);
      gateway.raiseWatchedJobRows([{'id': 'j1', 'status': 'completed', 'label': 'x'}]);
      await pumpEventQueue();
      expect(seen, isEmpty);
    });
  });
}

// ---------------------------------------------------------------- helpers

/// Drive the real platform channel, the way a backgrounding app would.
Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage(state.toString()),
    (_) {},
  );
  await tester.pump();
}

/// The gate the controller listens to — read back so the test can drive it.
AppLifecycleGate _gateOf(ChatController controller) => controller.lifecycle;

EngineMux _muxFor(_FakeCarrier carrier) => EngineMux(
      origin: Uri.parse('https://relay.example.com'),
      pinned: PinnedHttpClient(pinTable: const {}),
      bearerProvider: () async => 'bearer',
      carrierFactory: carrier.connect,
      backoffBase: Duration.zero,
      backoffMax: Duration.zero,
    );

EngineClient _clientFor(EngineMux mux) => EngineClient(
      rpc: EngineRpc(
        relay: RelayClient(
          origin: Uri.parse('https://relay.example.com'),
          pinned: PinnedHttpClient(pinTable: const {}),
          bearerProvider: () async => 'bearer',
        ),
      ),
      mux: mux,
    );

/// The [streamId] the console opened for [endpoint]. With [after] the search
/// skips everything written before that streamId, i.e. it finds the *re-open*.
String? _streamIdFor(_FakeCarrier carrier, String endpoint, {String? after}) {
  var seenAfter = after == null;
  for (final frame in carrier.sentFrames) {
    if (frame['type'] != 'open' || frame['endpoint'] != endpoint) continue;
    if (!seenAfter) {
      if (frame['streamId'] == after) seenAfter = true;
      continue;
    }
    return frame['streamId'] as String?;
  }
  return null;
}

/// The texts of the rendered message bubbles, in order.
List<String> _textsOf(ChatController controller) => [
      for (final bubble in controller.bubbles)
        if (bubble is ChatMessage) bubble.text,
    ];

void _raiseApproval(ChatController controller) {
  final gateway = controller.gateway;
  if (gateway is! _FakeGateway) return;
  gateway.raiseWaterfall('approval/request', {
    'title': '写文件',
    'command': 'bash',
    'detail': 'echo hi',
  });
}

Map<String, dynamic> _userMessageWire(int seq, String text) => {
      'type': 'user/message',
      'seq': seq,
      'time': 1700000000000 + seq,
      'data': {
        'id': 'm$seq',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
        'role': 'user',
      },
    };

Map<String, dynamic> _assistantMessageWire(int seq, String text) => {
      'type': 'assistant/message',
      'seq': seq,
      'time': 1700000000000 + seq,
      'data': {
        'turn': 1,
        'step': seq,
        'message': {
          'id': 'a$seq',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
          'role': 'assistant',
        },
        'stream': <Object?>[],
      },
    };

SessionWireEvent _userMessage(int seq, String text) => SessionWireEvent(
      type: 'user/message',
      seq: seq,
      time: 1700000000000 + seq,
      data: {
        'id': 'm$seq',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
        'role': 'user',
      },
    );

SessionWireEvent _assistantMessage(int seq, String text) => SessionWireEvent(
      type: 'assistant/message',
      seq: seq,
      time: 1700000000000 + seq,
      data: {
        'turn': 1,
        'step': seq,
        'message': {
          'id': 'a$seq',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
          'role': 'assistant',
        },
        'stream': <Object?>[],
      },
    );

FollowSnapshot _snapshot(List<SessionWireEvent> records) => FollowSnapshot(
      header: const SessionHeader(version: 4, id: 'session-1', createdAt: 0, isSeeded: false),
      cursor: records.isEmpty ? -1 : records.last.seq,
      records: [for (final r in records) FollowEvent(r)],
      hasMore: false,
      projections:
          const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

JobView _job(String id, String status, String label) =>
    JobView(jobId: id, status: status, label: label);

/// A storage double so `DshRemoteApp` can boot without a platform channel.
class _MemorySecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      null;

  @override
  Future<void> write({
    required String key,
    String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

/// The existing fake, plus a `job/list` channel of its own so the controller's
/// own watch can be driven without the 屏 F pane's.
class _FakeGateway extends FakeEngineGateway {
  final _jobs = StreamController<Object?>.broadcast();
  var eventsOpens = 0;

  @override
  MuxStream openEventStream() {
    eventsOpens++;
    return super.openEventStream();
  }

  @override
  MuxStream listJobs({required String sessionId}) =>
      MuxStream.forTesting(_jobs.stream);

  void raiseWatchedJobRows(List<Map<String, dynamic>> jobs) =>
      _jobs.add({'type': 'rows', 'jobs': jobs});

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _jobs.close();
  }
}

/// D-027's test seam, lifted from the core contract suite: a carrier the test
/// can drop, count and push frames into.
class _FakeCarrier {
  _FakeSocket? _socket;

  final sentFrames = <Map<String, dynamic>>[];
  var connects = 0;

  /// Whether a socket is currently up — i.e. whether the app is holding a WS.
  bool get live => _socket != null && _socket!.isDone != true;

  Future<MuxCarrier> connect(Uri url, {Duration? timeout}) async {
    connects++;
    final socket = _FakeSocket(this);
    _socket = socket;
    return socket;
  }

  void item(String streamId, Object? value) => _socket?.deliver({
        'type': 'item',
        'streamId': streamId,
        'value': value,
      });

  /// Let the mux's microtask / timer queue drain: dial, flush, replay.
  Future<void> settle([int milliseconds = 60]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));
}

class _FakeSocket implements MuxCarrier {
  _FakeSocket(this._carrier);

  final _FakeCarrier _carrier;
  final _inbound = StreamController<String>();
  int? _closeCode;
  bool? isDone;

  @override
  void addText(String text) =>
      _carrier.sentFrames.add(jsonDecode(text) as Map<String, dynamic>);

  @override
  Stream<String> get texts => _inbound.stream;

  @override
  int? get closeCode => _closeCode;

  /// Push a downlink frame, as the host would.
  void deliver(Map<String, dynamic> frame) {
    if (!_inbound.isClosed) _inbound.add(jsonEncode(frame));
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    isDone = true;
    if (!_inbound.isClosed) await _inbound.close();
  }
}
