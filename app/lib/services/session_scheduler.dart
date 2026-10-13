import 'dart:async';

import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_log.dart';
import '../data/machine_entry.dart';
import '../data/pin_store.dart';
import '../data/machines_repository.dart';

/// Renewal + liveness scheduler (design §5 会话管理 + §4.1):
/// every [tick] (60 s) walks the machine list and, for any entry inside the
/// T-2h renewal window, re-mints a signed URL through
/// `GET /dsh-remote/url-session` and swaps the credential in place. Time and
/// the mint function are injected → unit-testable without clocks or sockets.
class SessionScheduler {
  SessionScheduler({
    required this.store,
    this.mintUrl,
    this.now = DateTime.now,
    this.tick = const Duration(seconds: 60),
  });

  final MachinesStore store;
  final DateTime Function() now;
  final Duration tick;

  /// Mints a fresh signed URL for an entry; default talks to the real relay.
  final Future<String?> Function(MachineEntry entry)? mintUrl;

  Timer? _timer;
  final renewing = ValueNotifier<Set<String>>({});
  final failures = ValueNotifier<Map<String, String>>({});

  void start() {
    _timer ??= Timer.periodic(tick, (_) => sweep());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass; exposed for tests and for pull-to-refresh.
  Future<void> sweep() async {
    for (final entry in List.of(store.machines.value)) {
      final clock = SessionClock(
        expMs: entry.params.expMs,
        firstPairedMs: entry.firstPairedMs,
      );
      final at = now();
      final expired = clock.isExpired(at);
      // D-111：**已过期的也照试**。
      //
      // 旧逻辑在 `shouldRenew` 里就把过期条目跳过了，于是「错过窗口 = 终局」：
      // 它连问都不再问一次。而服务端现在为「重铸凭证」这一个端点开了口子
      // （relay `verifyUrlSessionTokenForRearm`）——签名对、session 没被吊销、
      // 没过 30 天 cap 的过期凭证，是能铸出下一把钥匙的。所以 App 必须问。
      //
      // 剩下的退避是为了别把一个已经没救的条目每 60 秒敲一次。
      if (!clock.shouldRenew(at) && !_rearmDue(entry, expired, at)) continue;
      if (renewing.value.contains(entry.id)) continue; // in-flight
      if (expired) _rearmLastTry[entry.id] = at; // 退避的计时起点
      renewing.value = {...renewing.value, entry.id};
      try {
        final url = await (mintUrl ?? _realMint)(entry);
        if (url == null) {
          _recordFailure(entry, expired, 'mint returned nothing');
          continue;
        }
        final params = parseSignedUrl(Uri.parse(url));
        // Keep the original pairing anchor (30-day cap reading) — only the
        // credential fields are replaced.
        store.replaceCredential(entry.copyWith(params: params));
        failures.value = {...failures.value}..remove(entry.id);
        _rearmAttempts.remove(entry.id);
        // D-111：续期成功**也要留痕**。过去成功与失败都不写日志，于是
        // 「为什么这台手机错过了窗口」在磁盘上根本查不到——而那恰恰是排障时
        // 唯一能回答的问题。
        AppLog.audit('machine.renew', attrs: {
          'machine': entry.id,
          'ok': true,
          'wasExpired': expired,
        });
      } on Object catch (e) {
        _recordFailure(entry, expired, '$e');
      } finally {
        renewing.value = {...renewing.value}..remove(entry.id);
      }
    }
  }

  /// 过期条目的重铸退避：5min → 30min → 2h 封顶。
  ///
  /// 「没救」的两条路也在这里被自然挡住——**服务端**会拒（吊销 / 超 30 天），
  /// 于是失败次数照涨、间隔照涨，而 App 不会变成一个每分钟敲一次门的东西。
  static const _rearmBackoff = [
    Duration(minutes: 5),
    Duration(minutes: 30),
    Duration(hours: 2),
  ];

  final Map<String, int> _rearmAttempts = {};
  final Map<String, DateTime> _rearmLastTry = {};

  bool _rearmDue(MachineEntry entry, bool expired, DateTime at) {
    if (!expired) return false;
    final last = _rearmLastTry[entry.id];
    if (last == null) return true; // 还没试过：立刻问一次
    // 失败 n 次 → 下一次等 backoff[n-1]：5min → 30min → 2h 封顶。
    final fails = _rearmAttempts[entry.id] ?? 0;
    final idx = (fails <= 0 ? 0 : fails - 1)
        .clamp(0, _rearmBackoff.length - 1);
    return at.difference(last) >= _rearmBackoff[idx];
  }

  /// 失败统一走这里：芯片态 + 退避计数 + **一行日志**。
  ///
  /// 过去失败只写芯片（`_fail`），成功连芯片都不写——于是「这台手机为什么错过了
  /// 续期窗口」在磁盘上查无实据，而那恰恰是排障时唯一能回答的问题。
  void _recordFailure(MachineEntry entry, bool expired, String why) {
    _fail(entry, why);
    if (expired) _rearmAttempts[entry.id] = (_rearmAttempts[entry.id] ?? 0) + 1;
    AppLog.audit('machine.renew', attrs: {
      'machine': entry.id,
      'ok': false,
      'wasExpired': expired,
      'attempt': (_rearmAttempts[entry.id] ?? 0),
      'error': why,
    });
  }

  void _fail(MachineEntry entry, String why) {
    // Failure is a chip state, not a modal (§7.2 L3): keep the old credential
    // (still valid until its own exp) and surface "renew failed".
    failures.value = {...failures.value, entry.id: why};
  }

  Future<String?> _realMint(MachineEntry entry) async {
    final pinned = PinnedHttpClient.fromStore(pinStoreFor(entry));
    try {
      final client = RelayClient(
        origin: entry.params.relayOrigin,
        pinned: pinned,
        bearerProvider: () async => entry.params.bearer,
      );
      final mint = await client.mintUrlSession();
      return mint?.url;
    } finally {
      pinned.close();
    }
  }

  void dispose() {
    stop();
    renewing.dispose();
    failures.dispose();
  }
}
