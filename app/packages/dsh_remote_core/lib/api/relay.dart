/// `/dsh-remote/*` plugin-route contract — hand-copied from the authoritative
/// sources and pinned by tests (repo convention). Route surface:
///
/// - plugin `src/index.ts` dispatch (route shapes)
/// - client `src/tunnel.ts` (RemoteSessionInfo / TunnelState / ConnectionState
///   / RemoteDeviceInfo field-by-field)
///
/// These types describe what a paired phone may call; the relay gate proxies
/// them with the URL-session Bearer (verified by the integration bed).
library;

/// Tunnel-level state, client `TunnelState`.
enum TunnelState {
  connected,
  connecting,
  reconnecting,
  disabled,
  manualOff,
  unknown;

  static TunnelState fromJson(String? v) => switch (v) {
        'connected' => connected,
        'connecting' => connecting,
        'reconnecting' => reconnecting,
        'disabled' => disabled,
        'manual-off' => manualOff,
        _ => unknown,
      };
}

/// End-to-end engine health as measured by the machine-side client
/// (client `EngineHealth`, v3.177).
///
/// `connected` says the tunnel WS is up; this says whether the engine behind
/// it actually answers. `unknown` means no evidence yet — it is not a fault
/// and must not be painted as one. Absent on snapshots from older clients;
/// parse falls back to [unknown].
enum EngineHealth {
  ok,
  unreachable,
  unknown;

  static EngineHealth fromJson(String? v) => switch (v) {
        'ok' => ok,
        'unreachable' => unreachable,
        _ => unknown,
      };
}

/// `client.getConnectionState()` shape.
class TunnelConnectionState {
  const TunnelConnectionState({
    required this.state,
    required this.relayUrl,
    required this.manualOff,
    this.engine = EngineHealth.unknown,
  });

  factory TunnelConnectionState.fromJson(Map<String, dynamic> j) =>
      TunnelConnectionState(
        state: TunnelState.fromJson(j['state'] as String?),
        relayUrl: (j['relayUrl'] as String?) ?? '',
        manualOff: (j['manualOff'] as bool?) ?? false,
        engine: EngineHealth.fromJson(j['engine'] as String?),
      );

  final TunnelState state;
  final String relayUrl;
  final bool manualOff;

  /// Machine-side verdict on the engine behind the tunnel. Meaningful only
  /// when [state] is connected; treat as [EngineHealth.unknown] otherwise.
  final EngineHealth engine;
}

/// One retained pairing, client `RemoteSessionInfo`.
class RemoteSessionInfo {
  const RemoteSessionInfo({
    required this.sessionId,
    required this.pairingToken,
    required this.qrUrl,
    required this.expiresAt,
    required this.createdAt,
  });

  factory RemoteSessionInfo.fromJson(Map<String, dynamic> j) =>
      RemoteSessionInfo(
        sessionId: j['sessionId'] as String,
        pairingToken: j['pairingToken'] as String,
        qrUrl: (j['qrUrl'] as String?) ?? '',
        expiresAt: (j['expiresAt'] as num).toInt(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );

  final String sessionId;
  final String pairingToken;

  /// Signed-URL QR for THIS pairing (machine-side mint; informational for the
  /// app — a phone never re-issues it, but displays it for other devices).
  final String qrUrl;
  final int expiresAt;

  /// First-creation epoch ms — the anchor for the relay-side 30-day cap
  /// (GC + `auth.max_age` local disambiguation feed on this).
  final int createdAt;
}

/// Relay-side device presence, client `RemoteDeviceInfo` (PSK `/__devices`
/// snapshot forwarded through the card payload).
class RemoteDeviceInfo {
  const RemoteDeviceInfo({
    required this.sessionId,
    required this.createdAt,
    required this.lastSeen,
    required this.onlineWs,
    required this.online,
    required this.paired,
  });

  factory RemoteDeviceInfo.fromJson(Map<String, dynamic> j) =>
      RemoteDeviceInfo(
        sessionId: j['sessionId'] as String,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        lastSeen: (j['lastSeen'] as num?)?.toInt(),
        onlineWs: (j['onlineWs'] as num?)?.toInt() ?? 0,
        online: (j['online'] as bool?) ?? false,
        paired: (j['paired'] as bool?) ?? false,
      );

  final String sessionId;
  final int createdAt;
  final int? lastSeen;
  final int onlineWs;
  final bool online;

  /// A device actually scanned this pairing's QR at least once.
  final bool paired;
}

/// Defensive map cast — runtime input comes from jsonDecode (string-keyed),
/// test literals may be loosely typed; both must parse.
Map<String, dynamic>? _asMap(Object? v) =>
    (v as Map?)?.cast<String, dynamic>();

/// `GET /dsh-remote/session` — the card contract.
class RemoteSessionSnapshot {
  const RemoteSessionSnapshot({
    required this.tunnel,
    required this.active,
    required this.sessions,
    required this.devices,
  });

  factory RemoteSessionSnapshot.fromJson(Map<String, dynamic> j) =>
      RemoteSessionSnapshot(
        tunnel: TunnelConnectionState.fromJson(_asMap(j['tunnel']) ?? {}),
        active: () {
          final m = _asMap(j['active']);
          return m == null ? null : RemoteSessionInfo.fromJson(m);
        }(),
        sessions: ((j['sessions'] as List<dynamic>?) ?? [])
            .map((e) => RemoteSessionInfo.fromJson(_asMap(e)!))
            .toList(),
        devices: (j['devices'] as List<dynamic>?)
            ?.map((e) => RemoteDeviceInfo.fromJson(_asMap(e)!))
            .toList(),
      );

  final TunnelConnectionState tunnel;
  final RemoteSessionInfo? active;
  final List<RemoteSessionInfo> sessions;

  /// Null when the relay is unreachable — callers degrade, never break
  /// (card contract).
  final List<RemoteDeviceInfo>? devices;

  int get onlineCount =>
      devices?.where((d) => d.online).length ?? 0;
}

/// `DELETE /dsh-remote/session` — revoke-all result.
class RevokeAllResult {
  const RevokeAllResult({required this.ok, required this.revoked});
  factory RevokeAllResult.fromJson(Map<String, dynamic> j) => RevokeAllResult(
        ok: (j['ok'] as bool?) ?? false,
        revoked: (j['revoked'] as num?)?.toInt() ?? 0,
      );
  final bool ok;
  final int revoked;
}

/// `GET /dsh-remote/url-session` — a freshly minted signed link (24 h).
class UrlSessionMint {
  const UrlSessionMint({required this.url});
  factory UrlSessionMint.fromJson(Map<String, dynamic> j) =>
      UrlSessionMint(url: j['url'] as String);
  final String url;
}

/// `POST /dsh-remote/tunnel` body — action is validated to exactly these two
/// values upstream; anything else is a 400.
enum TunnelAction { connect, disconnect }

/// `POST /dsh-remote/tunnel` response is a bare bool (new enabled state).
