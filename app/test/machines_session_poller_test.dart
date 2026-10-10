import 'dart:async';

import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/services/live_machine_scope.dart';
import 'package:dsh_remote_app/services/machines_session_poller.dart';
import 'package:dsh_remote_core/api/relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

/// design §5 多机器并发策略, last row: only the machine the console is driving
/// holds a WS; the list page keeps the **other** machines' status fresh with a
/// low-frequency `GET /dsh-remote/session` (60 s) plus a manual pull.
///
/// The interval, the fetcher and the timer factory are injected, so the 60 s
/// boundary is asserted without anybody waiting 60 s.
void main() {
  RemoteSessionSnapshot snapshot(TunnelState state) => RemoteSessionSnapshot(
        tunnel: TunnelConnectionState(
            state: state, relayUrl: 'ws://relay', manualOff: false),
        active: null,
        sessions: const [],
        devices: const [],
      );

  /// A store holding [names] as machines, each with a `sess_`-shaped id.
  MachinesStore storeOf(List<String> names) => MachinesStore(
        repo: InMemoryMachinesRepository(),
        seed: [
          for (final name in names)
            machineFrom(mintTestUrl(sessionId: 'sess_$name', name: name)),
        ],
      );

  test('v3.177: the engine verdict rides along with the tunnel state', () async {
    final store = storeOf(['s1']);
    var served = snapshot(TunnelState.connected);
    final poller = MachinesSessionPoller(
      store: store,
      fetch: (_) async => served,
      timerFactory: (_, __) => _FakeTimer(const Duration(seconds: 60), (_) {}),
    );
    addTearDown(poller.dispose);
    poller.start();

    // A snapshot without a verdict must not manufacture one.
    await poller.sweep();
    expect(poller.stateOf('sess_s1'), TunnelState.connected);
    expect(poller.engineHealthOf('sess_s1'), EngineHealth.unknown,
        reason: 'old-client snapshot: absence of evidence is not a fault');

    // A verdict flows through to the card seam.
    served = RemoteSessionSnapshot(
      tunnel: TunnelConnectionState(
          state: TunnelState.connected,
          relayUrl: '',
          manualOff: false,
          engine: EngineHealth.unreachable),
      active: null,
      sessions: const [],
      devices: const [],
    );
    await poller.sweep();
    expect(poller.engineHealthOf('sess_s1'), EngineHealth.unreachable);
  });

  test('the 60s timer refreshes every machine that is not live', () async {    final store = storeOf(['s1', 's2']);
    final asked = <String>[];
    final live = LiveMachineScope();
    live.claim('sess_s1'); // the console is driving this one — its data is live
    final timers = <_FakeTimer>[];
    final poller = MachinesSessionPoller(
      store: store,
      live: live,
      fetch: (entry) async {
        asked.add(entry.id);
        return snapshot(TunnelState.connected);
      },
      timerFactory: (period, tick) {
        final timer = _FakeTimer(period, tick);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(poller.dispose);

    poller.start();
    expect(poller.running, isTrue);
    expect(timers.single.period, const Duration(seconds: 60),
        reason: 'design §5: 默认 60s');
    expect(asked, isEmpty, reason: 'mounting must not spend data before the '
        'first tick lands');

    timers.single.fire();
    await pumpEventQueue();
    expect(asked, ['sess_s2'], reason: 'the live machine is skipped — its carrier '
        'already carries the truth');

    timers.single.fire();
    await pumpEventQueue();
    expect(asked, ['sess_s2', 'sess_s2']);
  });

  test('a sweep publishes the tunnel state per machine', () async {
    final poller = MachinesSessionPoller(
      store: storeOf(['s1']),
      live: LiveMachineScope(),
      fetch: (_) async => snapshot(TunnelState.reconnecting),
    );
    addTearDown(poller.dispose);

    expect(poller.stateOf('sess_s1'), isNull);
    await poller.sweep();
    expect(poller.stateOf('sess_s1'), TunnelState.reconnecting);
  });

  test('a machine added later is picked up by the next sweep', () async {
    final store = storeOf([]);
    final asked = <String>[];
    final poller = MachinesSessionPoller(
      store: store,
      live: LiveMachineScope(),
      fetch: (entry) async {
        asked.add(entry.id);
        return snapshot(TunnelState.connected);
      },
    );
    addTearDown(poller.dispose);

    await poller.sweep();
    expect(asked, isEmpty);

    store.machines.value = [
      machineFrom(mintTestUrl(sessionId: 'sess_s9', name: 'new')),
    ];
    await poller.sweep();
    expect(asked, ['sess_s9']);
  });

  test('a relay failure degrades to "unknown", it does not throw', () async {
    final poller = MachinesSessionPoller(
      store: storeOf(['s1']),
      live: LiveMachineScope(),
      fetch: (_) async => throw StateError('relay unreachable'),
    );
    addTearDown(poller.dispose);

    await poller.sweep();
    expect(poller.stateOf('sess_s1'), isNull, reason: 'a card with no snapshot still '
        'renders its clock, which is the honest fallback');
    expect(poller.errors.value, contains('sess_s1'));
  });

  test('one unreachable machine does not starve the others', () async {
    final poller = MachinesSessionPoller(
      store: storeOf(['s1', 's2']),
      live: LiveMachineScope(),
      fetch: (entry) async => entry.id == 'sess_s1'
          ? throw StateError('boom')
          : snapshot(TunnelState.connected),
    );
    addTearDown(poller.dispose);

    await poller.sweep();
    expect(poller.stateOf('sess_s1'), isNull);
    expect(poller.stateOf('sess_s2'), TunnelState.connected);
    expect(poller.inFlight.value, isEmpty, reason: 'no stuck in-flight row');
  });

  test('a slow relay is asked once per sweep, not once per tick', () async {
    final gate = Completer<RemoteSessionSnapshot?>();
    var calls = 0;
    final poller = MachinesSessionPoller(
      store: storeOf(['s1']),
      live: LiveMachineScope(),
      fetch: (_) {
        calls++;
        return gate.future;
      },
    );
    addTearDown(poller.dispose);

    final first = poller.sweep();
    final second = poller.sweep();
    await pumpEventQueue();
    expect(calls, 1, reason: 'an in-flight row is not re-asked');
    gate.complete(snapshot(TunnelState.connected));
    await Future.wait([first, second]);
    expect(poller.stateOf('sess_s1'), TunnelState.connected);
    expect(poller.inFlight.value, isEmpty);
  });

  test('a machine dropped from the list stops being polled', () async {
    final store = storeOf(['s1']);
    final asked = <String>[];
    final poller = MachinesSessionPoller(
      store: store,
      live: LiveMachineScope(),
      fetch: (entry) async {
        asked.add(entry.id);
        return snapshot(TunnelState.connected);
      },
    );
    addTearDown(poller.dispose);

    await poller.sweep();
    await store.remove('sess_s1');
    await poller.sweep();
    expect(asked, ['sess_s1']);
    expect(poller.stateOf('sess_s1'), isNull, reason: 'a removed machine leaves no '
        'stale status row behind');
  });

  test('stop() stops the timer and start() is idempotent', () async {
    final timers = <_FakeTimer>[];
    final poller = MachinesSessionPoller(
      store: storeOf(['s1']),
      live: LiveMachineScope(),
      fetch: (_) async => snapshot(TunnelState.connected),
      timerFactory: (period, tick) {
        final timer = _FakeTimer(period, tick);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(poller.dispose);

    poller.start();
    poller.start();
    expect(timers, hasLength(1), reason: 'one timer, however often start() is called');

    poller.stop();
    expect(timers.single.cancelled, isTrue);
    expect(poller.running, isFalse);
  });

  test('Duration.zero disables the timer entirely (widget tests)', () async {
    final poller = MachinesSessionPoller(
      store: storeOf(['s1']),
      live: LiveMachineScope(),
      interval: Duration.zero,
      fetch: (_) async => snapshot(TunnelState.connected),
      timerFactory: (_, _) => fail('no timer may be created'),
    );
    addTearDown(poller.dispose);

    poller.start();
    expect(poller.running, isFalse);
  });
}

/// Stands in for the [Timer] the poller would otherwise own, so the 60 s
/// boundary is exercised without a wall clock.
class _FakeTimer implements Timer {
  _FakeTimer(Duration period, this._tick) : _period = period;

  final Duration _period;
  final void Function(Timer) _tick;
  bool cancelled = false;
  int _fired = 0;

  /// Run one period, exactly as the scheduler would.
  void fire() {
    if (cancelled) return;
    _fired++;
    _tick(this);
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => _fired;

  Duration get period => _period;
}
