import 'dart:async';

import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:flutter/foundation.dart';

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
      if (!clock.shouldRenew(now())) continue;
      if (renewing.value.contains(entry.id)) continue; // in-flight
      renewing.value = {...renewing.value, entry.id};
      try {
        final url = await (mintUrl ?? _realMint)(entry);
        if (url == null) {
          _fail(entry, 'mint returned nothing');
          continue;
        }
        final params = parseSignedUrl(Uri.parse(url));
        // Keep the original pairing anchor (30-day cap reading) — only the
        // credential fields are replaced.
        store.replaceCredential(entry.copyWith(params: params));
        failures.value = {...failures.value}..remove(entry.id);
      } on Object catch (e) {
        _fail(entry, '$e');
      } finally {
        renewing.value = {...renewing.value}..remove(entry.id);
      }
    }
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
