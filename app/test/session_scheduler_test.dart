import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/logging/app_log.dart';
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

  // D-111 改写了这一条契约。
  //
  // 旧断言「过期不续期」在**当时是对的**：relay 的 `verifyUrlSessionToken` 第一条
  // 就是 `if (now > exp) return null`，而过期凭证去换凭证等于拿旧钥匙开「铸新
  // 钥匙」的门——先有鸡还是先有蛋，问了也白问。于是这条断言守着「过期 = 屏 I
  // 流程，不是续期流程」。
  //
  // 现在服务端为**只有** `/dsh-remote/url-session` 这一个端点开了重铸口子
  // （relay `verifyUrlSessionTokenForRearm`：签名照验、吊销照拒、30 天 cap 照
  // 拒，只放宽「过期 ≠ 立即失效」）。所以 App 必须问——不问就等于把「过期前 2h
  // 续期」这个**依赖用户恰好打开过 App** 的脆弱设计固化下来。真机代价见
  // field-notes §6.17：一台没在正确时间开过 App 的手机，凭证静静过期后控制台
  // 永远挂着「正在重连…」。
  test('D-111 过期条目仍会再问一次（服务端已开重铸口子）', () async {
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
    expect(mints, 1, reason: '过期不等于没救——服务端能铸出下一把钥匙');
  });

  test('D-111 重铸成功 → 凭证复活，30 天锚点不动', () async {
    final now = DateTime.utc(2026, 10, 5, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    final entry = machineFrom(
        mintTestUrl(now: now.subtract(const Duration(days: 2))));
    store.machines.value = [entry];

    final fresh = mintTestUrl(now: now);
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async => fresh.toString(),
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    final after = store.machines.value.single;
    expect(after.params.expMs, parseSignedUrl(fresh).expMs);
    expect(after.firstPairedMs, entry.firstPairedMs,
        reason: '重铸只换凭证字段，30 天读数不能跟着漂');
    expect(scheduler.failures.value, isEmpty);
  });

  test('D-111 重铸失败有退避：5 分钟内不再敲第二次', () async {
    final clock = DateTime.utc(2026, 10, 5, 12);
    var now = clock;
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    store.machines.value = [
      machineFrom(mintTestUrl(now: now.subtract(const Duration(days: 2)))),
    ];

    var mints = 0;
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async {
        mints++;
        throw StateError('relay still 401');
      },
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    expect(mints, 1);
    now = clock.add(const Duration(minutes: 2));
    await scheduler.sweep();
    expect(mints, 1, reason: '退避中——别把没救的条目变成每分钟敲一次门的东西');
    now = clock.add(const Duration(minutes: 6));
    await scheduler.sweep();
    expect(mints, 2, reason: '过了第一档退避就该再问一次');
  });

  test('D-111 续期成功与失败都要留痕（这是唯一能回答「为什么错过」的日志）',
      () async {
    final sink = MemoryLogSink();
    final previous = AppLog.sink;
    AppLog.sink = sink;
    addTearDown(() => AppLog.sink = previous);

    var now = DateTime.utc(2026, 10, 5, 12);
    final store = MachinesStore(repo: InMemoryMachinesRepository());
    store.machines.value = [
      machineFrom(mintTestUrl(now: now.subtract(const Duration(days: 2)))),
    ];

    // 一次失败、一次成功，两种结局都要落一行。
    final ok = mintTestUrl(now: now);
    var shouldFail = true;
    final scheduler = SessionScheduler(
      store: store,
      now: () => now,
      mintUrl: (_) async {
        if (shouldFail) {
          shouldFail = false;
          throw StateError('relay down');
        }
        return ok.toString();
      },
    );
    addTearDown(scheduler.dispose);

    await scheduler.sweep();
    now = now.add(const Duration(minutes: 6)); // 跨过退避
    await scheduler.sweep();

    final lines = sink.lines;
    expect(lines.any((l) => l.contains('action=machine.renew')
        && l.contains('ok=false')), isTrue,
        reason: '失败不留痕 = 下次排障只能靠猜');
    expect(lines.any((l) => l.contains('action=machine.renew')
        && l.contains('ok=true')), isTrue,
        reason: '成功也要留痕：否则分不清「没触发」和「触发了但失败」');
  });
}
