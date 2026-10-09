/// `/api/remote.mux` — the Gateway multiplexed RPC carrier (M2 / plan T2.1).
///
/// dsh 0.1.7-rc.2 routes the **whole** engine control plane through one
/// WebSocket, not through one HTTP path per method:
///
/// - unary calls go over HTTP `POST /api/<namespace>.<method>` with body
///   `{args: {...}}` → `{ok, value|error}` (see `engine_rpc.dart`)
/// - server streams (`session.follow`, `session.control`, `$events`) are
///   multiplexed onto this socket as *logical streams* keyed by `streamId`
///
/// Wire contract hand-copied from
/// `packages/api/gateway/src/stream-protocol.ts` (dsh-root 0.1.7-rc.2):
///
/// - `REMOTE_STREAM_MUX_PATH = '/api/remote.mux'`            (line 7)
/// - `RemoteStreamClientMessage`                            (lines 234-244)
/// - `RemoteStreamServerMessage`                             (lines 253-257)
/// - both are validated with `exactKeys` (line 340) — the host **rejects**
///   any frame carrying an extra or missing key, so every frame built here
///   emits exactly the documented key set. `item` is the only frame with a
///   genuinely optional `value` (lines 271-275 / 295-299).
/// - `streamId` and `endpoint` must be non-empty strings (lines 345-347).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../net/pinned_http.dart';
import 'engine_rpc.dart';
import 'error_code.dart';

/// Uplink frame kinds (host-side `RemoteStreamClientMessage`).
enum MuxClientFrameType { open, item, end, cancel }

/// Downlink frame kinds (host-side `RemoteStreamServerMessage`).
enum MuxServerFrameType { item, error, end }

/// Connection lifecycle of the mux socket, surfaced for the §7.2 L3 banner.
enum MuxState { idle, connecting, connected, reconnecting, healing }

/// A failure delivered by the Host on one logical stream.
///
/// `error` on the wire is exactly `{code, message, details}` — the host
/// validates with `exactKeys(['code','message','details'])` (line 307), so all
/// three are always present and `details` is always a JSON object.
class MuxStreamError implements Exception {
  const MuxStreamError({
    required this.code,
    required this.message,
    this.details = const <String, dynamic>{},
  });

  factory MuxStreamError.fromWire(Map<String, dynamic> error) {
    final details = error['details'];
    return MuxStreamError(
      code: error['code'] as String,
      message: error['message'] as String,
      details: details is Map<String, dynamic>
          ? details
          : const <String, dynamic>{},
    );
  }

  final String code;
  final String message;
  final Map<String, dynamic> details;

  /// Fold into the app-wide error model, through the **same** table the unary
  /// path uses.
  ///
  /// A stream and a unary call fail for the same reasons (`gateway/…` codes
  /// are shared), so re-implementing the mapping here would guarantee drift.
  AppError toAppError() => EngineRemoteError(
        code: code,
        message: message,
        details: details,
      ).toAppError();

  @override
  String toString() => 'MuxStreamError($code: $message)';
}

/// Wire-frame constructors for the mux carrier.
///
/// These exist as named functions rather than inline maps so the **exact key
/// set** is a tested artifact. The host validates every frame with
/// `exactKeys` (`stream-protocol.ts:340`) and throws on any surplus or missing
/// key, so a stray field is a hard connection failure, not a soft one.
class MuxFrame {
  MuxFrame._();

  /// `{type, streamId, endpoint, payload}` — four keys, payload mandatory
  /// (`stream-protocol.ts:277-283`).
  static Map<String, dynamic> open({
    required String streamId,
    required String endpoint,
    Object? payload,
  }) =>
      {
        'type': 'open',
        'streamId': streamId,
        'endpoint': endpoint,
        'payload': payload ?? const <String, dynamic>{},
      };

  /// `{type, streamId}` or `{type, streamId, value}` — `value` is the only
  /// genuinely optional key in the protocol (`stream-protocol.ts:271-275`).
  /// A JSON `null` value is still sent, because omitting it and sending null
  /// are different frames on this wire.
  static Map<String, dynamic> item(String streamId, {Object? value, bool hasValue = false}) =>
      {
        'type': 'item',
        'streamId': streamId,
        if (hasValue) 'value': value,
      };

  /// `{type, streamId}` (`stream-protocol.ts:266-270`).
  static Map<String, dynamic> end(String streamId) =>
      {'type': 'end', 'streamId': streamId};

  /// `{type, streamId}` (`stream-protocol.ts:266-270`).
  static Map<String, dynamic> cancel(String streamId) =>
      {'type': 'cancel', 'streamId': streamId};
}

/// The duplex the mux rides: a text sink plus a stream of inbound texts.
///
/// Production is a `dart:io` [WebSocket]; the interface exists so the
/// reconnect contract (D-027) is testable without a live relay. Deliberately
/// narrower than [WebSocket] — anything the mux does not use is not part of it.
abstract class MuxCarrier {
  void addText(String text);

  Stream<String> get texts;

  /// Close code observed when the carrier ended, if any. `4001` is the
  /// relay's "device replaced" eviction and heals immediately (D-028).
  int? get closeCode;

  Future<void> close([int? code, String? reason]);
}

/// Production [MuxCarrier] over a real `dart:io` WebSocket.
///
/// Also the only place the close code is observable — [EngineMux] needs it to
/// tell the v3.204 eviction (`4001`, heal immediately) from an ordinary drop.
class _WebSocketCarrier implements MuxCarrier {
  _WebSocketCarrier(this._ws) {
    _sub = _ws.listen(
      (Object? data) {
        if (data is String) _controller.add(data);
      },
      onDone: () {
        _closeCode = _ws.closeCode;
        if (!_controller.isClosed) _controller.close();
      },
      onError: (Object _) {
        _closeCode = _ws.closeCode;
        if (!_controller.isClosed) _controller.close();
      },
      cancelOnError: true,
    );
  }

  final WebSocket _ws;
  late final StreamSubscription<Object?> _sub;
  final _controller = StreamController<String>.broadcast();
  int? _closeCode;

  @override
  void addText(String text) => _ws.add(text);

  @override
  Stream<String> get texts => _controller.stream;

  @override
  int? get closeCode => _closeCode ?? _ws.closeCode;

  @override
  Future<void> close([int? code, String? reason]) async {
    await _sub.cancel();
    await _ws.close(code, reason);
    if (!_controller.isClosed) await _controller.close();
  }
}

/// One logical stream opened on the shared mux socket.
///
/// Handles its own `streamId` routing; the caller only sees decoded `value`
/// payloads. Closing is explicit because the Host distinguishes half-close
/// (`end` — "I'm done sending") from full teardown (`cancel`).
class MuxStream {
  MuxStream._(this._mux, this.streamId, this.endpoint);

  /// Test seam: a logical stream fed straight from a Dart stream, with no
  /// socket underneath. Sending and cancelling are no-ops.
  MuxStream.forTesting(Stream<Object?> source)
      : _mux = null,
        streamId = 'test',
        endpoint = '' {
    _items.addStream(source);
  }

  final EngineMux? _mux;
  final String streamId;
  final String endpoint;

  final _items = StreamController<Object?>.broadcast();
  final _errors = StreamController<MuxStreamError>.broadcast();
  final _done = StreamController<void>.broadcast();

  bool _halfClosed = false;
  bool _terminated = false;

  /// D-027: true while the stream is waiting for its carrier to come back.
  /// The stream is **not** terminated — frames resume on the same handle.
  bool _detached = false;

  /// Whether this stream is waiting for a new carrier (D-027). The UI reads it
  /// to render a reconnecting state instead of a dead conversation.
  bool get detached => _detached;

  /// Decoded `item` payloads, in arrival order.
  Stream<Object?> get items => _items.stream;

  /// Stream-terminating failures. Does not auto-close [items].
  Stream<MuxStreamError> get errors => _errors.stream;

  /// Fires once when the Host ends (`end`) or fails (`error`) the stream.
  Stream<void> get done => _done.stream;

  bool get terminated => _terminated;

  /// Send one `item` up this stream. [value] is omitted from the frame when
  /// null — the host accepts both `['type','streamId']` and the 3-key form.
  void send(Object? value) {
    if (_terminated || _halfClosed) return;
    _mux?._sendFrame(MuxFrame.item(streamId, value: value, hasValue: value != null));
  }

  /// Half-close the uplink: no more items, but keep receiving.
  void end() {
    if (_terminated || _halfClosed) return;
    _halfClosed = true;
    _mux?._sendFrame(MuxFrame.end(streamId));
  }

  /// Tear the stream down in both directions.
  void cancel() {
    if (_terminated) return;
    // D-027: while detached the new carrier has not seen this `open` yet, so a
    // `cancel` for it would be a frame for an unknown stream. Dropping it is
    // correct — `_forget` removes the stream from the resume set too, so the
    // re-play on reconnect skips it.
    if (!_detached) {
      _mux?._sendFrame(MuxFrame.cancel(streamId));
    }
    _mux?._forget(streamId);
    _terminate();
  }

  void _onItem(Object? value) {
    if (!_items.isClosed) _items.add(value);
  }

  void _onError(MuxStreamError error) {
    if (!_errors.isClosed) _errors.add(error);
    _terminate();
  }

  void _onEnd() => _terminate();

  void _terminate() {
    if (_terminated) return;
    _terminated = true;
    _mux?._forget(streamId);
    if (!_done.isClosed) _done.add(null);
  }

  void _dispose() {
    _terminate();
    _items.close();
    _errors.close();
    _done.close();
  }
}

/// The `/api/remote.mux` client: one socket, many logical streams.
///
/// Reconnect contract is inherited from §4.1(3) and matches `EventsSocket`:
/// `close(4001, device_replaced)` heals immediately on the same Bearer (M0
/// 实测② — v3.204 rotation leaves HTTP and this socket alive); everything else
/// backs off exponentially. On a lost socket every live stream is terminated
/// so callers re-open deliberately rather than silently resuming a journal at
/// an unknown cursor.
class EngineMux {
  EngineMux({
    required this.origin,
    required this.pinned,
    required this.bearerProvider,
    this.connectTimeout = const Duration(seconds: 12),
    this.backoffBase = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
    this.carrierFactory,
  });

  final Uri origin;
  final PinnedHttpClient pinned;
  final Future<String?> Function() bearerProvider;
  final Duration connectTimeout;
  final Duration backoffBase;
  final Duration backoffMax;

  /// Test seam (D-027): opens the carrier. Production dials [pinned]'s client
  /// at [endpoint]; a test substitutes a fake carrier so the drop → reconnect
  /// → re-open contract is testable without a live relay.
  final Future<MuxCarrier> Function(Uri url, {Duration? timeout})? carrierFactory;

  /// `/api/remote.mux` resolved against the relay origin, with the scheme
  /// mapped to its WebSocket form (`http`→`ws`, `https`→`wss`).
  ///
  /// The caller holds an HTTP origin — that is what every other client in this
  /// package takes — but `WebSocket.connect` rejects an `http://` URL outright,
  /// so the translation has to happen here rather than in every call site.
  /// A production origin is `https://relay.example.com`, which must become
  /// `wss://`.
  Uri get endpoint => origin.resolve('/api/remote.mux').replace(
        scheme: switch (origin.scheme) {
          'https' || 'wss' => 'wss',
          _ => 'ws',
        },
      );

  MuxCarrier? _ws;
  StreamSubscription<String>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  int _nextStreamId = 0;
  int? _lastCloseCode;
  bool _started = false;
  bool _disposed = false;

  final _streams = <String, MuxStream>{};
  final _pending = <Map<String, dynamic>>[];

  /// D-030: every stream the caller has opened and not yet cancelled/ended —
  /// the reconnect replay set. A stream lives here from `open()` until the
  /// host ends it or the caller cancels it; carrier losses never remove it.
  final _desired =
      <({String streamId, String endpoint, Map<String, dynamic>? args})>[];
  final _state = StreamController<MuxState>.broadcast();
  MuxState state = MuxState.idle;

  Stream<MuxState> get states => _state.stream;

  /// Open a logical stream to [endpoint] (e.g. `session/follow`, `$events`).
  ///
  /// Connects the carrier on first use, so a caller that forgets [start] gets
  /// a working stream rather than a silent no-op.
  ///
  /// [args] are the endpoint's declared parameters; this class wraps them in
  /// the `payload.args` envelope the host requires
  /// (`api/gateway/src/client/index.ts:229` — `connection.rpc.open('/api',
  /// endpoint, { args }, signal)`), so no call site can get it wrong.
  ///
  /// [endpoint] is slash-separated (`session/follow`, not `session.follow`) —
  /// see `endpointOf()` in `api/gateway/src/index.ts:1370`.
  ///
  /// The `open` frame carries no ack; the first `item` on the stream is the
  /// endpoint's opening frame (for `session/follow` that is the `snapshot`;
  /// for `$events` it is `ready`).
  MuxStream open(String endpoint, {Map<String, dynamic>? args}) {
    if (!_started && !_disposed) start();
    final streamId = 'app-${_nextStreamId++}';
    final stream = MuxStream._(this, streamId, endpoint);
    _streams[streamId] = stream;
    // D-030: record the INTENT, not just the fact. A stream whose `open` was
    // queued into `_pending` and then dropped by a carrier loss never reached
    // the host, so it was absent from the D-027 resume set and never re-opened
    // — the console's `$events` channel silently died while the journal (whose
    // open had landed before the drop) came back. Replaying `_desired` after
    // every reconnect closes that race.
    _desired.add((
      streamId: streamId,
      endpoint: endpoint,
      args: args,
    ));
    if (_ws != null) {
      // Carrier already up: send the open directly. When it is down the open
      // is NOT queued into `_pending` — `_onDone` clears that queue on a
      // carrier loss, which would silently drop it; `_replayResumed` sends it
      // right after the next carrier instead (D-030).
      _sendFrame(MuxFrame.open(
        streamId: streamId,
        endpoint: endpoint,
        payload: {'args': args ?? const <String, dynamic>{}},
      ));
    }
    return stream;
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _started = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // D-083: the closed carrier must be dropped, not just closed. `_ws` used
    // to survive `stop()`, so the first `open` after the app came back to the
    // foreground took the "carrier already up" branch and wrote onto a socket
    // that `stop()` had just closed — dart:io raises synchronously there, and
    // the throw escaped `open()` instead of reconnecting (真机 20:48 实证:
    // 解锁回前台 → 45s 首帧看门狗报错 → 用户只看到「会话打不开」).
    final carrier = _ws;
    _ws = null;
    await _sub?.cancel();
    _sub = null;
    await carrier?.close();
    _setState(MuxState.idle);
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _setState(MuxState.connecting);
    final token = await bearerProvider();
    final url = token == null
        ? endpoint
        : endpoint.replace(queryParameters: {...endpoint.queryParameters, 'token': token});
    try {
      final factory = carrierFactory;
      final carrier = factory != null
          ? await factory(url, timeout: connectTimeout)
          : await _dialWebSocket(url);
      if (_disposed || !_started) {
        await carrier.close();
        return;
      }
      _ws = carrier;
      _attempt = 0;
      _lastCloseCode = null;
      _setState(MuxState.connected);
      _flushPending();
      _replayResumed();
      _sub = carrier.texts.listen(
        _onFrame,
        onDone: _onDone,
        onError: (Object _) => _onDone(),
        cancelOnError: true,
      );
    } on Object {
      _scheduleBackoff();
    }
  }

  /// Production carrier: a real `dart:io` WebSocket over the pinned client, so
  /// the wss handshake rides the same TOFU table as every HTTP call.
  Future<MuxCarrier> _dialWebSocket(Uri url) async =>
      _WebSocketCarrier(await WebSocket.connect(
        url.toString(),
        customClient: pinned.client,
      ).timeout(connectTimeout));

  void _onFrame(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      return; // host frames are always JSON; ignore carrier noise
    }
    if (decoded is! Map<String, dynamic>) return;
    final streamId = decoded['streamId'];
    if (streamId is! String) return;
    final stream = _streams[streamId];
    if (stream == null) return; // late frame for a cancelled stream
    switch (decoded['type']) {
      case 'item':
        stream._onItem(decoded['value']);
      case 'error':
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          stream._onError(MuxStreamError.fromWire(error));
        }
      case 'end':
        stream._onEnd();
    }
  }

  /// Write one frame, reporting whether the carrier was still alive.
  ///
  /// `dart:io` raises **synchronously** when a frame goes onto a socket that
  /// is closed — and equally when the socket died without delivering `onDone`,
  /// which is what a mobile network dropping mid-write looks like. That raise
  /// used to escape `_sendFrame`, propagate out of `open()`, and kill the
  /// resume path; here it lands in [_onDone] instead, which is the treatment
  /// the mux already gives a carrier it *observed* dying — same detach, same
  /// backoff, same re-open of [\_desired].
  bool _trySend(MuxCarrier carrier, Map<String, dynamic> frame) {
    try {
      carrier.addText(jsonEncode(frame));
      return true;
    } on Object {
      return false;
    }
  }

  void _sendFrame(Map<String, dynamic> frame) {
    final carrier = _ws;
    if (carrier == null) {
      // Queued rather than dropped. A frame emitted before the carrier is up
      // would otherwise vanish without a trace, and the caller would sit
      // waiting for a first frame that can never arrive — the worst possible
      // failure mode for a fire-and-forget API.
      _pending.add(frame);
      return;
    }
    if (!_trySend(carrier, frame)) _onDone();
  }

  void _flushPending() {
    final carrier = _ws;
    if (carrier == null || _pending.isEmpty) return;
    final queued = _pending.toList(growable: false);
    _pending.clear();
    for (final frame in queued) {
      if (!_trySend(carrier, frame)) {
        _onDone();
        return;
      }
    }
  }

  /// D-027/D-030: re-open every stream the caller still wants after a carrier
  /// loss. The host has no memory of the previous socket, so each stream needs
  /// a fresh `open`; it then answers with that endpoint's opening frame (for
  /// `session/follow` a fresh `snapshot`), so a journal restarts from a
  /// **known** cursor rather than an unknown one — the same authoritative
  /// baseline as the very first open.
  ///
  /// The set is [_desired] — every stream still present in [_streams] — not
  /// only the ones whose `open` had landed before the drop. A stream whose
  /// `open` was still sitting in `_pending` when the carrier died never reached
  /// the host, so it was absent from any "was live" set; the console's
  /// `$events` channel died that way while its journal recovered. Streams the
  /// host ended (or the caller cancelled) are removed from both maps, so they
  /// are correctly never resurrected.
  void _replayResumed() {
    for (final entry in _desired.toList(growable: false)) {
      final stream = _streams[entry.streamId];
      if (stream == null) continue; // ended by the host, or cancelled
      // D-083: a carrier can die inside the replay itself. `_onDone` already
      // cleared the live-stream state and scheduled the redial, so bailing out
      // is correct — the next carrier replays from `_desired` on its own.
      if (_ws == null) return;
      stream._detached = false;
      _sendFrame(MuxFrame.open(
        streamId: entry.streamId,
        endpoint: entry.endpoint,
        payload: {'args': entry.args ?? const <String, dynamic>{}},
      ));
    }
  }

  void _forget(String streamId) {
    _streams.remove(streamId);
    // D-030: the host ended it (or the caller cancelled) — it must NOT come
    // back on the next carrier, so it leaves the replay set here.
    _desired.removeWhere((entry) => entry.streamId == streamId);
  }

  void _onDone() {
    if (_disposed) return;
    // `cancelOnError: true` plus an explicit onDone can both fire for one lost
    // socket; only the first may schedule a reconnect.
    if (_ws == null) return;
    final carrier = _ws!;
    _ws = null;
    // D-028: the 4001 heal path only works if the close code is actually read
    // off the socket. It used to be set to null on connect and never assigned
    // again, so the v3.204 "device replaced" case silently took the backoff
    // path instead of healing immediately.
    _lastCloseCode = carrier.closeCode;
    // Frames queued for a carrier that is now gone must not be replayed onto
    // the next one: the logical streams they belonged to are being re-opened,
    // and replaying an `open` for a forgotten stream is worse than losing it.
    _pending.clear();
    // D-027: a lost socket kills the carrier, not the logical streams. Mark
    // every live stream detached and remember how to re-open it; the caller's
    // handle stays usable and the next carrier answers a fresh `open` with a
    // fresh baseline. Before this, one dropped socket left the console
    // permanently blind: prompts still succeeded over unary HTTP (so it looked
    // alive) while the bubble list never received a frame again.
    for (final stream in _streams.values) {
      stream._detached = true;
    }
    // v3.204 eviction: rotation doesn't touch our Bearer — heal NOW, no backoff.
    if (_lastCloseCode == 4001) {
      _setState(MuxState.healing);
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration.zero, _connect);
    } else {
      _scheduleBackoff();
    }
  }

  void _scheduleBackoff() {
    if (_disposed) return;
    _setState(MuxState.reconnecting);
    final delay = backoffBase * (1 << _attempt.clamp(0, 5));
    _attempt++;
    final capped = delay > backoffMax ? backoffMax : delay;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(capped, _connect);
  }

  void _setState(MuxState next) {
    state = next;
    if (!_state.isClosed) _state.add(next);
  }

  void dispose() {
    _disposed = true;
    _started = false;
    _reconnectTimer?.cancel();
    _desired.clear(); // D-030: nothing may be re-opened after dispose
    for (final stream in _streams.values.toList()) {
      stream._dispose();
    }
    _streams.clear();
    unawaited(stop());
    _state.close();
  }
}
