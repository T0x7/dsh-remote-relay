import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/services/session_scheduler.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factories.dart';

/// T-2h renewal scheduling (design §4/§5): time and the mint function are
/// injected — no clock, no sockets, no timers.
void main() {
  test('renews only inside the T-2h window, swapping credentials in place',
      () async {
    final now = DateTime.utc(2026, 10, 1, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    // Entry expiring in 1h → inside the window.
    final entry = machineFrom(mintTestUrl(
        now: now.subtract(const Duration(hours: 23)),
        name: 'mac-mini'));
    store.machines.value = [entry];

    final renewedUrl = mintTestUrl(
        now: now, name: 'mac-mini'); // fresh 24h window
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async => renewedUrl.toString(),
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    final after = store.machines.value.single;
    expect(after.params.expMs, parseSignedUrl(renewedUrl).expMs);
    expect(after.firstPairedMs, entry.firstPairedMs,
        reason: 'pairing anchor must survive the swap (30-day reading)');
    expect(scheduler.failures.value, isEmpty);
  });

  test('skips machines outside the window (5h left)', () async {
    final now = DateTime.utc(2026, 10, 1, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    final entry = machineFrom(mintTestUrl(
        now: now.subtract(const Duration(hours: 19)), name: 'mac-mini'));
    store.machines.value = [entry];

    var mints = 0;
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async {
        mints++;
        return null;
      },
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    expect(mints, 0);
    expect(store.machines.value.single.params.expMs, entry.params.expMs);
  });

  test('mint failure keeps the old credential and records the reason',
      () async {
    final now = DateTime.utc(2026, 10, 1, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    final entry = machineFrom(
        mintTestUrl(now: now.subtract(const Duration(hours: 23))));
    store.machines.value = [entry];

    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async => throw StateError('relay down'),
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    expect(store.machines.value.single.params.expMs, entry.params.expMs,
        reason: 'old credential stays valid until its own exp');
    expect(scheduler.failures.value[entry.id], contains('relay down'));
    expect(scheduler.renewing.value, isEmpty, reason: 'no stuck in-flight');
  });

  test('expired machine is not renewed (the clock window excludes it)',
      () async {
    final now = DateTime.utc(2026, 10, 5, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    final entry = machineFrom(
        mintTestUrl(now: now.subtract(const Duration(days: 2))));
    store.machines.value = [entry];

    var mints = 0;
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async {
        mints++;
        return null;
      },
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    expect(mints, 0, reason: 'expired = 屏 I flow, not renewal');
  });
}
