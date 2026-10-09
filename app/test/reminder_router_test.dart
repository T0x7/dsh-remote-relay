import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/services/reminder_router.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// T1.12 前台提醒路由 (design §5 前台事件提醒 + §7.2 L4).
///
/// Three producers (mux carrier state / `job/list` terminal rows / `$events`
/// approval waterfalls) funnel into one router, which
///
/// 1. honours the 屏 G 提醒开关, and
/// 2. never says the same thing twice for the same cause — a flapping socket
///    must be one snackbar, not one per reconnect attempt.
void main() {
  group('dedup', () {
    test('a flapping tunnel is one reminder, and the restore re-arms it',
        () async {
      final router = ReminderRouter();
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();

      expect(seen, hasLength(1), reason: 'one cause, one prompt');
      expect(seen.single.kind, ReminderKind.tunnelDown);

      // Restored: re-armed, and a *later* outage is a new cause.
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: true);
      await pumpEventQueue();
      expect(seen, hasLength(1), reason: 'the restore itself is not a prompt');

      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      expect(seen, hasLength(2));
    });

    test('the already-healthy first report does not arm the dedup', () async {
      final router = ReminderRouter();
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: true);
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      expect(router.fired(ReminderCause.tunnel('m1')), isTrue);
    });

    test('machines are deduped independently', () async {
      final router = ReminderRouter();
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportTunnel(machineId: 'm1', machineName: 'a', connected: false);
      router.reportTunnel(machineId: 'm2', machineName: 'b', connected: false);
      await pumpEventQueue();

      expect(seen.map((r) => r.machineId), ['m1', 'm2']);
    });

    test('an approval is deduped by eventId — the D-032 replay is a repeat',
        () async {
      final router = ReminderRouter();
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportApproval(eventId: 'evt-1', machineId: 'm1', machineName: 'mac-mini');
      router.reportApproval(eventId: 'evt-1', machineId: 'm1', machineName: 'mac-mini');
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.kind, ReminderKind.approvalRequested);
    });

    test('a finished job is deduped by jobId, and job ids are never re-used',
        () async {
      final router = ReminderRouter();
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportJobFinished(
          jobId: 'job-1', machineId: 'm1', machineName: 'mac-mini', title: 'nightly build');
      router.reportJobFinished(
          jobId: 'job-1', machineId: 'm1', machineName: 'mac-mini', title: 'nightly build');
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.kind, ReminderKind.jobFinished);
      expect(seen.single.detail, 'nightly build');
    });
  });

  group('提醒开关 (屏 G)', () {
    test('off: nothing is emitted and nothing is burned', () async {
      final router = ReminderRouter(enabled: false);
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      router.reportJobFinished(jobId: 'j1', machineId: 'm1');
      router.reportApproval(eventId: 'e1', machineId: 'm1');
      await pumpEventQueue();

      expect(seen, isEmpty);
      expect(router.fired(ReminderCause.tunnel('m1')), isFalse,
          reason: 'a muted cause must stay un-fired, so switching the '
              'reminders back on still prompts for the next outage');
    });

    test('flipping the switch takes effect on the next signal, not retroactively',
        () async {
      final router = ReminderRouter();
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      expect(seen, hasLength(1));

      router.enabled = false;
      router.reportTunnel(machineId: 'm2', machineName: 'mac', connected: false);
      await pumpEventQueue();
      expect(seen, hasLength(1), reason: 'muted');

      router.enabled = true;
      router.reportTunnel(machineId: 'm3', machineName: 'imac', connected: false);
      await pumpEventQueue();
      expect(seen, hasLength(2), reason: 'un-muted, and nothing is replayed');
    });

    test('a settings write reaches the router (屏 G owns the switch)', () async {
      final settings = SettingsStore(storage: _MemorySecureStorage());
      await settings.hydrate();
      final router = ReminderRouter(settings: settings);
      addTearDown(router.dispose);
      final seen = <Reminder>[];
      router.reminders.listen(seen.add);

      expect(router.enabled, isTrue, reason: 'the persisted default');

      await settings.setRemindersEnabled(false);
      await pumpEventQueue();
      expect(router.enabled, isFalse);

      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      expect(seen, isEmpty);

      await settings.setRemindersEnabled(true);
      await pumpEventQueue();
      router.reportTunnel(machineId: 'm1', machineName: 'mac-mini', connected: false);
      await pumpEventQueue();
      expect(seen, hasLength(1));
    });

    test('a persisted `false` is honoured on boot', () async {
      // The settings page and the router are two instances over one key: the
      // switch must survive a cold start, not just an in-process flip.
      final storage = _MemorySecureStorage();
      await SettingsStore(storage: storage).setRemindersEnabled(false);
      final booted = SettingsStore(storage: storage);
      await booted.hydrate();
      final router = ReminderRouter(settings: booted);
      addTearDown(router.dispose);
      expect(router.enabled, isFalse);
    });
  });
}

/// A secure-storage double: [SettingsStore] persists one JSON blob, and the
/// router has to read what the settings page wrote. Same shape as the
/// `MemStorage` in `screens_dghi_test.dart` (it is file-local there).
class _MemorySecureStorage extends FlutterSecureStorage {
  final values = <String, String>{};

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
      values[key];

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
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
