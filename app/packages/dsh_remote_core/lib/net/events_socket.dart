import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log_hook.dart';
import 'pinned_http.dart';

/// Events stream with the §4.1(3) self-heal contract (plan T1.5):
///
/// - connects with `?token=<bearer>` on a bridged WS path
/// - close(4001, device_replaced) → **immediate** reconnect with the same
///   Bearer (v3.204 rotation doesn't invalidate it — M0 实测②)
/// - any other close/network failure → exponential backoff reconnect
/// - foreground lifecycle (connect/disconnect on demand) is the caller's;
///   this class only owns the always-on-while-started loop
class EventsSocket {
  EventsSocket({
    required this.uri,
    required this.bearerProvider,
    required this.pinned,
    this.backoffBase = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
  });

  final Uri uri;
  final Future<String?> Function() bearerProvider;
  final PinnedHttpClient pinned;
  final Duration backoffBase;
  final Duration backoffMax;

  WebSocket? _ws;
  StreamSubscription<Object?>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _started = false;
  bool _disposed = false;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _state = StreamController<EventsSocketState>.broadcast();
  EventsSocketState state = EventsSocketState.idle;

  /// Decoded JSON frames (text frames only; binary frames on event streams
  /// are not part of the contract).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  Stream<EventsSocketState> get states => _state.stream;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _connect();
  }

  Future<void> stop() async {
    _disposed = true;
    _started = false;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _ws?.close();
    _setState(EventsSocketState.idle);
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _setState(EventsSocketState.connecting);
    final token = await bearerProvider();
    final url = token == null
        ? uri
        : uri.replace(queryParameters: {...uri.queryParameters, 'token': token});
    // `url` carries the bearer as ?token= — NEVER log it (or any query form
    // of it). Attempt counts and states only.
    try {
      final ws = await WebSocket.connect(url.toString(),
              customClient: pinned.client)
          .timeout(const Duration(seconds: 12));
      if (_disposed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _attempt = 0;
      _setState(EventsSocketState.connected);
      CoreLog.emit('info', 'events', 'connected');
      _sub = ws.listen((data) {
        if (data is! String) return;
        try {
          _messages.add(jsonDecode(data) as Map<String, dynamic>);
        } catch (_) {/* non-JSON control traffic ignored */}
      }, onDone: _onDone, onError: (Object e) => _onDone());
    } on Object {
      CoreLog.emit('warn', 'events', 'connect failed (attempt=$_attempt)');
      _scheduleBackoffReconnect();
    }
  }

  void _onDone() {
    if (_disposed) return;
    final code = _ws?.closeCode;
    if (code == 4001) {
      // v3.204 eviction: rotation doesn't touch our Bearer — heal NOW,
      // no backoff, no user-visible disruption beyond a transient state.
      CoreLog.emit('warn', 'events',
          'close 4001 device_replaced — healing with same bearer');
      _setState(EventsSocketState.healing);
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration.zero, _connect);
      return;
    }
    _scheduleBackoffReconnect();
  }

  void _scheduleBackoffReconnect() {
    if (_disposed) return;
    _setState(EventsSocketState.reconnecting);
    final delay = backoffBase * (1 << _attempt.clamp(0, 5));
    _attempt++;
    final capped = delay > backoffMax ? backoffMax : delay;
    CoreLog.emit('info', 'events',
        'reconnect in ${capped.inMilliseconds}ms (attempt=$_attempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(capped, _connect);
  }

  void _setState(EventsSocketState s) {
    state = s;
    if (!_state.isClosed) _state.add(s);
  }

  void dispose() {
    stop();
    _messages.close();
    _state.close();
  }
}

enum EventsSocketState { idle, connecting, connected, reconnecting, healing }
