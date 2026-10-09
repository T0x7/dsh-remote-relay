import 'dart:convert';

import 'package:dsh_remote_core/credentials/signed_url.dart';

/// One paired machine (design §12 本地数据清单): relay metadata + the
/// URL-session credential. Credentials ride the encrypted store; the entry
/// serializes as one JSON blob (v1 keeps metadata in the same secure store —
/// stricter than the design minimum, zero extra deps).
class MachineEntry {
  const MachineEntry({
    required this.id,
    required this.name,
    required this.params,
    required this.firstPairedMs,
    this.certPin,
  });

  /// sessionId — stable identity of the pairing (relay mints one session).
  final String id;

  /// Display name from the QR's `name` param (hostname), editable later.
  final String name;

  /// The CURRENT credential set (replaced wholesale on renewal).
  final SignedUrlParams params;

  /// Pairing anchor for the 30-day cap reading (QR `t`, replaced by the
  /// engine session row's createdAt when the snapshot is first fetched).
  final int firstPairedMs;

  /// TOFU pin (SHA-256 hex) when the relay is https; null for plain http.
  final String? certPin;

  MachineEntry copyWith({String? name, SignedUrlParams? params, int? firstPairedMs}) =>
      MachineEntry(
        id: id,
        name: name ?? this.name,
        params: params ?? this.params,
        firstPairedMs: firstPairedMs ?? this.firstPairedMs,
        certPin: certPin,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'relayOrigin': params.relayOrigin.toString(),
        'sessionId': params.sessionId,
        'hash': params.hash,
        'mid': params.mid,
        't': params.tMs,
        'exp': params.expMs,
        'firstPairedMs': firstPairedMs,
        if (certPin != null) 'certPin': certPin,
      };

  factory MachineEntry.fromJson(Map<String, dynamic> j) => MachineEntry(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'machine',
        firstPairedMs: (j['firstPairedMs'] as num?)?.toInt() ?? 0,
        certPin: j['certPin'] as String?,
        params: SignedUrlParams(
          relayOrigin: Uri.parse(j['relayOrigin'] as String),
          sessionId: j['sessionId'] as String,
          hash: j['hash'] as String,
          mid: j['mid'] as String,
          tMs: (j['t'] as num).toInt(),
          expMs: (j['exp'] as num).toInt(),
        ),
      );

  static String encodeList(List<MachineEntry> machines) =>
      jsonEncode(machines.map((m) => m.toJson()).toList());

  static List<MachineEntry> decodeList(String raw) {
    if (raw.isEmpty) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => MachineEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
