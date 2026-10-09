import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';

/// Frame fixtures hand-copied from
/// `packages/api/gateway/src/stream-protocol.ts` (dsh-root 0.1.7-rc.2).
///
/// The host rejects any frame whose key set differs from the documented one
/// (`exactKeys`, line 340), so every test here asserts the **exact** key set —
/// not just that the expected keys are present.
void main() {
  group('uplink frames', () {
    test('open carries exactly four keys with a mandatory payload', () {
      final frame = MuxFrame.open(
        streamId: 'app-0',
        endpoint: SessionEndpoints.follow,
        payload: {
          'args': {
            'address': {'kind': 'session', 'id': 'sess_1'},
          },
        },
      );

      expect(frame.keys.toSet(), {'type', 'streamId', 'endpoint', 'payload'});
      expect(frame['type'], 'open');
      expect(frame['endpoint'], 'session/follow',
          reason: 'slash-separated endpoint (endpointOf, gateway/src/index.ts:1370)');
      expect(jsonEncode(frame), contains('session/follow'));
    });

    test('open payload is the {args} wrapper, not the bare arguments', () {
      // connection.rpc.open('/api', endpoint, { args }, signal)
      // (api/gateway/src/client/index.ts:229) — the host requires `payload` to
      // hold exactly one key, `args`.
      final frame = MuxFrame.open(
        streamId: 'app-0',
        endpoint: SessionEndpoints.follow,
        payload: {
          'args': {'address': {'id': 'sess_1'}},
        },
      );
      final payload = frame['payload']! as Map<String, dynamic>;

      expect(payload.keys.toSet(), {'args'});
    });

    test('open defaults payload to an empty object, never omits it', () {
      final frame = MuxFrame.open(streamId: 'app-0', endpoint: EventEndpoints.stream);

      expect(frame.containsKey('payload'), isTrue,
          reason: 'the host requires exactly the 4-key open form');
      expect(frame['payload'], isEmpty);
    });

    test('item without a value is the 2-key form', () {
      expect(
        MuxFrame.item('app-0').keys.toSet(),
        {'type', 'streamId'},
      );
    });

    test('item with a value is the 3-key form', () {
      final frame = MuxFrame.item('app-0', value: {'text': 'hi'}, hasValue: true);

      expect(frame.keys.toSet(), {'type', 'streamId', 'value'});
      expect(frame['value'], {'text': 'hi'});
    });

    test('an explicit JSON null value is still sent', () {
      final frame = MuxFrame.item('app-0', value: null, hasValue: true);

      expect(frame.containsKey('value'), isTrue);
      expect(frame['value'], isNull);
      expect(jsonEncode(frame), contains('"value":null'));
    });

    test('end and cancel are 2-key frames of distinct type', () {
      expect(MuxFrame.end('app-0').keys.toSet(), {'type', 'streamId'});
      expect(MuxFrame.end('app-0')['type'], 'end');
      expect(MuxFrame.cancel('app-0').keys.toSet(), {'type', 'streamId'});
      expect(MuxFrame.cancel('app-0')['type'], 'cancel');
    });

    test('no frame ever carries extra keys', () {
      final frames = [
        MuxFrame.open(streamId: 's', endpoint: 'session.follow'),
        MuxFrame.item('s'),
        MuxFrame.item('s', value: 1, hasValue: true),
        MuxFrame.end('s'),
        MuxFrame.cancel('s'),
      ];
      const allowed = {
        'open': {'type', 'streamId', 'endpoint', 'payload'},
        'item': {'type', 'streamId', 'value'},
        'end': {'type', 'streamId'},
        'cancel': {'type', 'streamId'},
      };
      for (final frame in frames) {
        final type = frame['type'] as String;
        final keys = frame.keys.toSet();
        // item has two legal forms; every other type has exactly one.
        if (type == 'item') {
          expect(keys.length, anyOf(2, 3));
          expect(keys.difference({'type', 'streamId', 'value'}), isEmpty);
        } else {
          expect(keys, allowed[type]);
        }
      }
    });
  });

  group('downlink error frames', () {
    test('error is exactly {code, message, details}', () {
      final wire = <String, dynamic>{
        'code': 'gateway/context-failed',
        'message': 'session stream unavailable',
        'details': {'endpoint': 'session.follow', 'field': 'address'},
      };
      final error = MuxStreamError.fromWire(wire);

      expect(wire.keys.toSet(), {'code', 'message', 'details'});
      expect(error.code, 'gateway/context-failed');
      expect(error.message, 'session stream unavailable');
      expect(error.details['endpoint'], 'session.follow');
      expect(error.details['field'], 'address');
    });

    test('a missing or non-map details degrades to empty, never throws', () {
      expect(
        MuxStreamError.fromWire({'code': 'x', 'message': 'y'}).details,
        isEmpty,
      );
      expect(
        MuxStreamError.fromWire({'code': 'x', 'message': 'y', 'details': 'bad'}).details,
        isEmpty,
      );
    });

    test('gateway fault details always carry the endpoint', () {
      // gateway/src/remote-error-codes.ts: every gateway/* code has
      // { endpoint } and optionally { field }.
      const details = <String, dynamic>{'endpoint': 'session.prompt', 'field': 'text'};
      final error = MuxStreamError(code: 'gateway/input-invalid', message: 'm', details: details);

      expect(error.details['endpoint'], isNotEmpty);
    });
  });

  group('session journal invariants', () {
    SessionFollowFrame snapshot({int revision = 0}) => FollowSnapshot(
          header: const SessionHeader(
            version: 4,
            id: 's1',
            createdAt: 0,
            isSeeded: false,
          ),
          cursor: 0,
          records: const [],
          hasMore: false,
          projections: const SessionProjectionBaseline(
            asOfSeq: 0,
            values: Projections(),
          ),
          assistantStream: AssistantStreamBaseline(revision: revision),
        );

    FollowAssistantStream frame(int revision) => FollowAssistantStream(
          {'type': 'chunk', 'attemptId': 'att', 'revision': revision, 'index': 0},
        );

    test('the baseline seeds the revision, so the first live token is fine', () {
      // Observed live: the engine opens at `{"revision":0}` and the first
      // assistant-stream frame carries revision 1. If the baseline were not
      // seeded, that frame would read as "arrived before its baseline" and the
      // stream would die on the first token of a real reply.
      final controller = StreamController<SessionFollowFrame>();
      addTearDown(controller.close);
      final stream = SessionEventStream.fromSource(controller.stream);
      addTearDown(stream.dispose);

      final errors = <Object>[];
      stream.errors.listen(errors.add);

      controller.add(snapshot());
      controller.add(frame(1));

      return Future<void>.delayed(Duration.zero).then((_) {
        expect(errors, isEmpty, reason: 'the first live token must be accepted');
      });
    });

    test('a skipped revision is refused as a desynchronised journal', () {
      final controller = StreamController<SessionFollowFrame>();
      addTearDown(controller.close);
      final stream = SessionEventStream.fromSource(controller.stream);
      addTearDown(stream.dispose);

      final errors = <Object>[];
      stream.errors.listen(errors.add);

      controller.add(snapshot());
      controller.add(frame(5));

      return Future<void>.delayed(Duration.zero).then((_) {
        expect(errors, hasLength(1));
      });
    });

    test('a second snapshot is refused', () {
      final controller = StreamController<SessionFollowFrame>();
      addTearDown(controller.close);
      final stream = SessionEventStream.fromSource(controller.stream);
      addTearDown(stream.dispose);

      final errors = <Object>[];
      stream.errors.listen(errors.add);

      controller.add(snapshot());
      controller.add(snapshot());

      return Future<void>.delayed(Duration.zero).then((_) {
        expect(errors, hasLength(1));
      });
    });
  });

  group('mux endpoint path', () {
    test('maps an http origin to ws', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('http://127.0.0.1:8080'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      // `WebSocket.connect` rejects an `http://` URL outright.
      expect(mux.endpoint.toString(), 'ws://127.0.0.1:8080/api/remote.mux');
    });

    test('maps an https origin to wss — the production case', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      expect(mux.endpoint.toString(), 'wss://relay.example.com/api/remote.mux');
    });

    test('leaves an already-WebSocket origin alone', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('wss://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      expect(mux.endpoint.scheme, 'wss');
    });

    test('resolves to /api/remote.mux', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      expect(mux.endpoint.toString(), 'wss://relay.example.com/api/remote.mux');
    });

    test('stream ids are unique and non-empty', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      final ids = <String>{
        for (var i = 0; i < 5; i++) mux.open(SessionEndpoints.follow).streamId,
      };
      expect(ids.length, 5);
      for (final id in ids) {
        expect(id, isNotEmpty, reason: 'the host rejects an empty streamId');
      }
    });

    test('cancelling a stream twice sends one frame', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      final stream = mux.open(SessionEndpoints.follow);
      stream.cancel();
      expect(stream.terminated, isTrue);
      stream.cancel();
    });

    test('sending after half-close is a no-op', () {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      final stream = mux.open(EventEndpoints.stream);
      stream.end();
      // Neither throws nor resurrects the stream.
      stream.send({'late': true});
      expect(stream.terminated, isFalse);
    });

    test('stop() before any connection strands nothing', () async {
      final pinned = PinnedHttpClient(pinTable: const {});
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: pinned,
        bearerProvider: () async => null,
      );
      addTearDown(mux.dispose);
      addTearDown(pinned.client.close);

      final stream = mux.open(SessionEndpoints.follow);
      final ended = <bool>[];
      stream.done.listen((_) => ended.add(true));

      // stop() is a deliberate shutdown, not a carrier loss: it must not fire
      // the resume machinery.
      await mux.stop();
      expect(ended, isEmpty, reason: 'no streams exist before a connection');
      expect(stream.terminated, isFalse);
      expect(stream.detached, isFalse);
    });

    test('D-027: a carrier loss detaches live streams, it does not end them',
        () async {
      // The bug this pins: a dropped socket used to terminate every logical
      // stream, and nothing ever re-opened them, so the console stayed
      // permanently blind while unary calls kept succeeding.
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
      );
      addTearDown(mux.dispose);

      final stream = mux.open(SessionEndpoints.follow,
          args: {'request': {'address': 'x'}});
      final ended = <bool>[];
      stream.done.listen((_) => ended.add(true));
      await carrier.settle();

      expect(stream.detached, isFalse, reason: 'live carrier');
      carrier.drop();
      await carrier.settle();

      expect(ended, isEmpty, reason: 'a lost carrier is not a stream end');
      expect(stream.terminated, isFalse);
      expect(stream.detached, isTrue, reason: 'waiting for a new carrier');
    });

    test('D-027: the reconnected carrier re-opens the detached stream',
        () async {
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
        // Zero base so the mux's OWN reconnect timer fires inside the test's
        // settle window — the production backoff is 1s, which would make this
        // test sleep for a second per assertion.
        backoffBase: Duration.zero,
        backoffMax: Duration.zero,
      );
      addTearDown(mux.dispose);

      final stream = mux.open(SessionEndpoints.follow,
          args: {'request': {'address': 'x'}});
      await carrier.settle();
      final before = carrier.sentFrames.length;

      carrier.drop();
      await carrier.settle();

      final replayed = carrier.sentFrames.skip(before).where(
        (f) => f['type'] == 'open' && f['streamId'] == stream.streamId,
      );
      expect(replayed, hasLength(1),
          reason: 'the reconnected carrier must re-open the same streamId');
      expect((replayed.first['payload']! as Map)['args'],
          {'request': {'address': 'x'}},
          reason: 'replayed with the same args, so the host can rebuild it');
      expect(stream.detached, isFalse, reason: 'live again');
    });

    test('D-027: a stream cancelled while detached is not re-opened', () async {
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
        // Long enough that the carrier is still down when the cancel lands,
        // short enough that the re-dial fits in the test's own wait.
        backoffBase: const Duration(milliseconds: 150),
        backoffMax: const Duration(milliseconds: 150),
      );
      addTearDown(mux.dispose);

      final stream = mux.open(SessionEndpoints.follow);
      await carrier.settle();
      carrier.drop();
      await carrier.settle();
      expect(stream.detached, isTrue, reason: 'carrier is down');

      stream.cancel();
      expect(
        carrier.sentFrames.where((f) => f['type'] == 'cancel'),
        isEmpty,
        reason: 'a cancel for a stream the new carrier never opened is not sent',
      );

      final before = carrier.sentFrames.length;
      await carrier.settle(400);
      final opens = carrier.sentFrames
          .skip(before)
          .where((f) => f['type'] == 'open' && f['streamId'] == stream.streamId);
      expect(opens, isEmpty, reason: 'a cancelled stream stays cancelled');
    });

    test('D-028: a 4001 eviction heals with no backoff', () async {
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
        // A 1s base would make this test fail for the wrong reason if the heal
        // path regressed into the backoff path.
        backoffBase: const Duration(seconds: 5),
        backoffMax: const Duration(seconds: 30),
      );
      addTearDown(mux.dispose);

      mux.open(SessionEndpoints.follow);
      await carrier.settle();
      final before = carrier.sentFrames.length;

      carrier.drop(4001);
      await carrier.settle();

      expect(carrier.connects, greaterThan(1),
          reason: 'a 4001 must re-dial immediately, not after the backoff');
      expect(
        carrier.sentFrames.skip(before).where((f) => f['type'] == 'open'),
        isNotEmpty,
        reason: 'the re-dialed carrier re-opens the live streams',
      );
    });

    test('D-083: stop() must not leave a dead carrier referenced', () async {
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
      );
      addTearDown(mux.dispose);

      mux.open(EventEndpoints.stream);
      await carrier.settle();
      expect(carrier.connects, 1);

      // design §5「切后台即断 WS」, then back to the foreground.
      await mux.stop();
      mux.start();

      // The first open after the resume is the one that used to throw: `stop`
      // left `_ws` pointing at the socket it had just closed, so this wrote
      // onto a dead sink synchronously (真机 20:48 实证：解锁回前台必炸，
      // 45s 首帧看门狗随后报错，用户看到「会话打不开」而毫无线索).
      expect(() => mux.open(EventEndpoints.stream), returnsNormally,
          reason: 'a resumed app must not throw out of open()');
      await carrier.settle();

      expect(carrier.connects, 2,
          reason: 'resume must dial a fresh carrier, not reuse the closed one');
    });

    test('D-083: a write onto a carrier that died unobserved never throws '
        'through the caller', () async {
      final carrier = _FakeCarrier();
      final mux = EngineMux(
        origin: Uri.parse('https://relay.example.com'),
        pinned: PinnedHttpClient(pinTable: const {}),
        bearerProvider: () async => null,
        carrierFactory: carrier.connect,
        // The heal goes through the normal backoff (there was no observed
        // onDone, so no close code and no 4001 fast path). Production backoff
        // starts at seconds; the assertion only cares that a redial happens,
        // so shrink it to land inside `settle`.
        backoffBase: const Duration(milliseconds: 1),
      );
      addTearDown(mux.dispose);

      mux.open(EventEndpoints.stream);
      await carrier.settle();

      // A socket that dies without delivering onDone — the mobile network
      // dropping mid-write, a relay restart, a doze timeout. dart:io raises
      // on the write; the mux still holds the reference.
      carrier.dieSilently();

      expect(() => mux.open(EventEndpoints.stream), returnsNormally,
          reason: 'a dead carrier is a disconnect to heal, not a crash to throw');
      await carrier.settle();

      expect(carrier.connects, greaterThan(1),
          reason: 'the dead carrier must be replaced by a fresh one');
    });
  });
}

/// D-027 test seam: a stand-in carrier so the drop → reconnect → re-open
/// contract is testable without a live relay. Records every frame written and
/// lets the test kill the socket on demand.
class _FakeCarrier {
  _FakeSocket? _socket;

  /// Every frame written to every carrier, in order — a reconnect starts a new
  /// socket but the test still wants one timeline.
  final sentFrames = <Map<String, dynamic>>[];
  var connects = 0;

  Future<MuxCarrier> connect(Uri url, {Duration? timeout}) async {
    connects++;
    final socket = _FakeSocket(sentFrames);
    _socket = socket;
    return socket;
  }

  /// Let the mux's microtask/timer queue drain.
  Future<void> settle([int milliseconds = 20]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  void drop([int? code]) => _socket?.simulateClose(code);

  void reconnect() => connect(Uri.parse('wss://relay.example.com/api/remote.mux'));

  /// D-083: the current carrier starts throwing on every write while the mux
  /// still holds a reference to it.
  void dieSilently() => _socket?.dieSilently = true;
}

class _FakeSocket implements MuxCarrier {
  _FakeSocket(this._timeline);

  final List<Map<String, dynamic>> _timeline;
  final _inbound = StreamController<String>();
  int? _closeCode;

  /// D-083: the real dart:io contract the fakes used to gloss over — a write
  /// onto a closed socket throws synchronously (`StateError: StreamSink is
  /// closed`), it does not vanish into the void.
  var _closedForWrites = false;

  /// D-083: models a socket that died without the mux observing it — writes
  /// throw, but `texts` never delivers onDone, so `_ws` stays stale non-null.
  var dieSilently = false;

  @override
  void addText(String text) {
    if (_closedForWrites || dieSilently) {
      throw StateError('StreamSink is closed');
    }
    _timeline.add(jsonDecode(text) as Map<String, dynamic>);
  }

  @override
  Stream<String> get texts => _inbound.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    _closedForWrites = true;
    if (!_inbound.isClosed) await _inbound.close();
  }

  void simulateClose([int? code]) {
    _closeCode = code;
    _closedForWrites = true;
    if (!_inbound.isClosed) _inbound.close();
  }
}
