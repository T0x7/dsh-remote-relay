import 'dart:async';

import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:flutter/foundation.dart';

import '../data/machine_entry.dart';
import '../data/machines_repository.dart';
import '../data/pin_store.dart';
import 'live_machine_scope.dart';

/// The one snapshot read the machine list is allowed to make, injected so a
/// test never opens a socket. Same seam shape as `MachineDetailPage`'s
/// `SnapshotFetcher`.
typedef SessionSnapshotFetcher = Future<RemoteSessionSnapshot?> Function(
    MachineEntry entry);

/// Builds the periodic timer; `Timer.periodic` in production, a hand-driven
/// double in tests. Injecting the *timer* (not just the interval) is what lets
/// the 60 s boundary be asserted in milliseconds.
typedef PeriodicTimerFactory = Timer Function(
    Duration period, void Function(Timer) tick);

/// design §5 多机器并发策略, last row: the list page keeps the status of the
/// machines it is **not** driving fresh with a low-frequency
/// `GET /dsh-remote/session` (60 s) plus a manual pull — instead of a carrier
/// per machine, which would spend battery, mobile data, and relay bridge
/// concurrency on screens nobody is looking at.
///
/// Shape copied from [SessionScheduler] (renewal): the interval, the fetch and
/// the timer are all injectable, one pass is a plain `sweep()`, and every
/// failure degrades instead of throwing — the card still has a clock to show.
class MachinesSessionPoller {
  MachinesSessionPoller({
    required this.store,
    this.fetch,
    this.interval = const Duration(seconds: 60),
    LiveMachineScope? live,
    this.timerFactory,
    this.onSnapshot,
  }) : _liveScope = live;

  final MachinesStore store;
  final Duration interval;
  final LiveMachineScope? _liveScope;

  /// Who is live. A `static final` cannot be a default argument value, so the
  /// process-wide scope is resolved on first read instead.
  LiveMachineScope get live => _liveScope ?? LiveMachineScope.instance;

  /// Null = the real relay read.
  final SessionSnapshotFetcher? fetch;
  final PeriodicTimerFactory? timerFactory;

  /// Called for every snapshot that lands, so a caller can route a tunnel
  /// change into a reminder without the poller knowing what a reminder is.
  void Function(MachineEntry entry, RemoteSessionSnapshot snapshot)? onSnapshot;

  /// machineId → the tunnel state the relay last reported. Missing means "not
  /// known yet", which is not the same as "down".
  final ValueNotifier<Map<String, TunnelState>> tunnelStates =
      ValueNotifier(const {});

  /// machineId → the client-side engine health from the same snapshot
  /// (v3.177). Evidence-based only: [EngineHealth.unknown] until a snapshot
  /// carries a verdict, and a missing entry is not a fault.
  final ValueNotifier<Map<String, EngineHealth>> engineHealths =
      ValueNotifier(const {});

  /// The last known engine health for [machineId], or null.
  EngineHealth? engineHealthOf(String machineId) => engineHealths.value[machineId];

  /// machineId → why the last read failed.
  final ValueNotifier<Map<String, String>> errors = ValueNotifier(const {});

  /// Machines with a read in flight — a 60 s tick must never stack requests on
  /// a slow relay.
  final ValueNotifier<Set<String>> inFlight = ValueNotifier(const {});

  Timer? _timer;
  bool _disposed = false;

  bool get running => _timer != null;

  /// The last known tunnel state for [machineId], or null.
  TunnelState? stateOf(String machineId) => tunnelStates.value[machineId];

  /// Begin the low-frequency sweep. No read happens before the first tick, so
  /// mounting the list costs nothing; the first read lands one period later.
  ///
  /// `Duration.zero` disables the timer outright (widget tests: a pending
  /// periodic timer outlives the tree and fails their timer audit).
  void start() {
    if (_timer != null || interval <= Duration.zero) return;
    _timer = (timerFactory ?? Timer.periodic)(interval, (_) => sweep());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over every machine that is not live. Also what pull-to-refresh
  /// awaits, which is why it returns a future the caller can hang a spinner on.
  Future<void> sweep() async {
    final entries = List.of(store.machines.value);
    for (final entry in entries) {
      if (live.holds(entry.id)) continue;
      if (inFlight.value.contains(entry.id)) continue;
      inFlight.value = {...inFlight.value, entry.id};
      try {
        final snapshot = await (fetch ?? _realFetch)(entry);
        // A read outlives the page that asked for it whenever the relay is slow
        // and the user navigates away; writing into a disposed notifier throws.
        if (_disposed) return;
        if (snapshot == null) {
          _clearError(entry.id);
          continue;
        }
        tunnelStates.value = {...tunnelStates.value, entry.id: snapshot.tunnel.state};
        engineHealths.value = {
          ...engineHealths.value,
          entry.id: snapshot.tunnel.engine,
        };
        _clearError(entry.id);
        onSnapshot?.call(entry, snapshot);
      } on Object catch (e) {
        // Card contract: an unreachable relay degrades, it never breaks the
        // list. The card keeps its clock; the row carries the reason.
        if (_disposed) return;
        errors.value = {...errors.value, entry.id: '$e'};
      } finally {
        if (!_disposed) inFlight.value = {...inFlight.value}..remove(entry.id);
      }
    }
    _prune(entries);
  }

  /// A removed machine must not leave a status row behind — the next card with
  /// the same id would inherit a state nobody verified.
  void _prune(List<MachineEntry> entries) {
    if (_disposed) return;
    final present = entries.map((e) => e.id).toSet();
    final states = tunnelStates.value;
    final stale = states.keys.where((id) => !present.contains(id)).toList();
    if (stale.isNotEmpty) {
      tunnelStates.value = {...states}..removeWhere((id, _) => stale.contains(id));
    }
    final healths = engineHealths.value;
    final staleHealths = healths.keys.where((id) => !present.contains(id)).toList();
    if (staleHealths.isNotEmpty) {
      engineHealths.value = {...healths}..removeWhere((id, _) => staleHealths.contains(id));
    }
    final failed = errors.value;
    final staleErrors = failed.keys.where((id) => !present.contains(id)).toList();
    if (staleErrors.isNotEmpty) {
      errors.value = {...failed}..removeWhere((id, _) => staleErrors.contains(id));
    }
  }

  void _clearError(String machineId) {
    if (_disposed) return;
    if (errors.value.containsKey(machineId)) {
      errors.value = {...errors.value}..remove(machineId);
    }
  }

  Future<RemoteSessionSnapshot?> _realFetch(MachineEntry entry) async {
    final pinned = PinnedHttpClient.fromStore(pinStoreFor(entry));
    try {
      return await RelayClient(
        origin: entry.params.relayOrigin,
        pinned: pinned,
        bearerProvider: () async => entry.params.bearer,
      ).fetchSessionSnapshot();
    } finally {
      pinned.close();
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    tunnelStates.dispose();
    engineHealths.dispose();
    errors.dispose();
    inFlight.dispose();
  }
}
