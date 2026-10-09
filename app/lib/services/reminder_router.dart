import 'dart:async';

import '../data/settings_store.dart';

/// One "something happened while you were looking at the app" line, ready for
/// the L4 layer (design §7.2 SnackBar).
class Reminder {
  const Reminder({
    required this.kind,
    this.machineId,
    this.machineName,
    this.detail,
    this.failed = false,
  });

  final ReminderKind kind;

  /// Null for a cause the app cannot attribute to a machine (the console's own
  /// carrier, for instance — the console owns no machine id).
  final String? machineId;

  /// The machine's display name, when there is one. Pairing- and
  /// engine-supplied, so it is shown verbatim.
  final String? machineName;

  /// The job title, for a task reminder.
  final String? detail;

  /// A task ended in failure rather than in success.
  final bool failed;
}

enum ReminderKind {
  /// The machine's tunnel to the relay went down.
  tunnelDown,

  /// A `job/list` row reached a terminal state.
  jobFinished,

  /// An approval is waiting on `$events` (审批请求).
  approvalRequested,
}

/// The dedup key of one **cause**.
///
/// Three producers report the same facts at wildly different rates — a flapping
/// carrier re-reports on every reconnect attempt, `job/list` re-sends its whole
/// row set on every poll — so the router keys on the cause, not on the report.
abstract final class ReminderCause {
  /// The console's own carrier has no machine id; it is still its own cause and
  /// must not be confused with a machine the list happens to be polling.
  static const _console = 'console';

  static String tunnel(String? machineId) => 'tunnel:${machineId ?? _console}';

  static String job(String? machineId, String jobId) =>
      'job:${machineId ?? _console}:$jobId';

  static String approval(String? machineId, String eventId) =>
      'approval:${machineId ?? _console}:$eventId';
}

/// T1.12 前台提醒路由 (design §5 前台事件提醒).
///
/// Three sources — the mux carrier state, `job/list` terminal rows, and the
/// `$events` approval waterfall — land here and leave as one stream of
/// [Reminder]s for a single presenter to draw. Two rules make that stream worth
/// showing:
///
/// 1. **The 屏 G switch is honoured.** Nothing is emitted while it is off, and
///    nothing is *recorded* either, so switching it back on does not dump a
///    backlog of stale events — only the next real one prompts.
/// 2. **One cause, one prompt.** The dedup set is keyed on the cause, so a
///    flapping tunnel is one SnackBar rather than one per reconnect. A cause
///    that *clears* is disarmed, so the next outage is a new cause and prompts
///    again.
class ReminderRouter {
  ReminderRouter({SettingsStore? settings, bool enabled = true})
      : _settings = settings,
        _enabled = settings == null
            ? enabled
            : settings.notifier.value.remindersEnabled {
    final store = settings;
    if (store == null) return;
    // This instance's own writes, plus a cold `hydrate()`.
    store.notifier.addListener(_readStore);
    // Writes made by the 屏 G page, which holds a **different** instance over
    // the same key — a per-instance notifier cannot cross that gap.
    _storeChangesSub = SettingsStore.changes.listen(_fold);
    store.hydrate();
  }

  /// The process-wide router the console and the list both report into.
  static final ReminderRouter instance =
      ReminderRouter(settings: SettingsStore());

  final SettingsStore? _settings;
  final _reminders = StreamController<Reminder>.broadcast();
  final Set<String> _fired = {};
  StreamSubscription<SettingsSnapshot>? _storeChangesSub;
  bool _enabled;

  /// The dedup keys that have already prompted.
  Set<String> get firedCauses => Set.unmodifiable(_fired);

  /// Whether the 屏 G 提醒 switch is on.
  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
  }

  /// The one stream every surface presents from. A SnackBar on whichever
  /// `Scaffold` is on screen, so a task that finishes while the user is in the
  /// chat still says so.
  Stream<Reminder> get reminders => _reminders.stream;

  /// Whether [cause] has already prompted.
  bool fired(String cause) => _fired.contains(cause);

  /// The carrier state of [machineId] changed.
  ///
  /// `connected: true` is a **restore**: it disarms the cause so the next
  /// outage prompts again, and it is not itself a prompt.
  void reportTunnel({
    String? machineId,
    String? machineName,
    required bool connected,
  }) {
    final cause = ReminderCause.tunnel(machineId);
    if (connected) {
      _fired.remove(cause);
      return;
    }
    _fire(cause, () => Reminder(
          kind: ReminderKind.tunnelDown,
          machineId: machineId,
          machineName: machineName,
        ));
  }

  /// A task reached a terminal state. A job id is never re-used, so this
  /// disarms nothing.
  void reportJobFinished({
    required String jobId,
    String? machineId,
    String? machineName,
    String? title,
    bool failed = false,
  }) =>
      _fire(ReminderCause.job(machineId, jobId), () => Reminder(
            kind: ReminderKind.jobFinished,
            machineId: machineId,
            machineName: machineName,
            detail: title,
            failed: failed,
          ));

  /// An approval is waiting. Keyed on the event id because the D-032 periodic
  /// `$events` re-open makes the host replay every still-pending waterfall, and
  /// because an event id is never re-used: the cause stays fired for the rest
  /// of the session, so however often the host re-sends it, it prompts once.
  void reportApproval({
    required String eventId,
    String? machineId,
    String? machineName,
    String? title,
  }) =>
      _fire(ReminderCause.approval(machineId, eventId), () => Reminder(
            kind: ReminderKind.approvalRequested,
            machineId: machineId,
            machineName: machineName,
            detail: title,
          ));

  /// Records the cause (so a repeat stays quiet) and emits if the switch is on.
  ///
  /// A **muted** cause is deliberately not recorded: a machine that flapped all
  /// week while the switch was off must still say something the first time it
  /// fails after the user turns reminders back on.
  void _fire(String cause, Reminder Function() build) {
    if (!_enabled) return;
    if (!_fired.add(cause)) return;
    if (_reminders.isClosed) return;
    _reminders.add(build());
  }

  void _readStore() {
    final store = _settings;
    if (store != null) _fold(store.notifier.value);
  }

  void _fold(SettingsSnapshot snapshot) {
    _enabled = snapshot.remindersEnabled;
  }

  void dispose() {
    _reminders.close();
    _storeChangesSub?.cancel();
    _settings?.notifier.removeListener(_readStore);
  }
}
