import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/machine_entry.dart';
import '../data/pin_store.dart';
import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';

/// 屏 D — machine detail: two clocks (24h renewal + 30-day cap), device
/// presence, and the actions row (escape hatch / tunnel switch / revoke).
typedef SnapshotFetcher = Future<RemoteSessionSnapshot?> Function(
    MachineEntry entry);

class MachineDetailPage extends StatefulWidget {
  const MachineDetailPage({super.key, required this.entry, this.fetchOverride});

  final MachineEntry entry;

  /// Test seam: inject a synchronous snapshot source (widget tests run in
  /// fake-async where real sockets never resolve). Null = real RelayClient.
  final SnapshotFetcher? fetchOverride;

  @override
  State<MachineDetailPage> createState() => _MachineDetailPageState();
}

class _MachineDetailPageState extends State<MachineDetailPage> {
  RemoteSessionSnapshot? _snapshot;
  bool _rejected401 = false;
  String? _netError;
  bool _loading = true;

  MachineEntry get entry => widget.entry;

  RelayClient _client() => RelayClient(
        origin: entry.params.relayOrigin,
        pinned: PinnedHttpClient.fromStore(pinStoreFor(entry)),
        bearerProvider: () async => entry.params.bearer,
      );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final snap = await (widget.fetchOverride ?? _realFetch)(entry);
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _rejected401 = snap == null;
        _netError = null;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _netError = '$e';
        _loading = false;
      });
    }
  }

  Future<RemoteSessionSnapshot?> _realFetch(MachineEntry e) =>
      _client().fetchSessionSnapshot();

  Future<void> _tunnelAction(TunnelAction action) async {
    final ok = await _client().setTunnel(action);
    if (!mounted) return;
    final l10n = L10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (action == TunnelAction.disconnect
              ? l10n.snackDisconnected
              : l10n.snackReconnected)
          : l10n.snackRejected),
    ));
  }

  Future<void> _revokeAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(L10n.of(ctx).revokeTitle),
        content: Text(L10n.of(ctx).revokeBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.of(ctx).actionCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.of(ctx).actionRevoke),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _client().revokeAll();
    if (!mounted) return;
    final l10n2 = L10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok == null
            ? l10n2.unreachableTitle
            : l10n2.snackRevoked('${ok.revoked}')),
    ));
  }

  /// 浏览器逃生舱 v1：铸 24h 链接并**复制到剪贴板**（url_launcher 不在
  /// 依赖白名单——商店式跳转待批注后接入；复制链接先行，语义不损）。
  Future<void> _copyEscapeHatch() async {
    final mint = await _client().mintUrlSession();
    if (!mounted) return;
    if (mint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).snackMintFailed)));
      return;
    }
    final l10n = L10n.of(context);
    final launched = await launchUrl(Uri.parse(mint.url),
        mode: LaunchMode.externalApplication);
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: mint.url));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(launched ? l10n.snackOpeningWeb : l10n.snackCopyFallback)));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final clock = SessionClock(
      expMs: entry.params.expMs,
      firstPairedMs: entry.firstPairedMs,
    );
    final left = clock.remaining(now);
    final stage = clock.chipStage(now);
    final l10n = L10n.of(context);
    final errorText = _rejected401
        ? l10n.err_auth_expired
        : _netError != null
            ? '${l10n.err_network_unreachable} ($_netError)'
            : null;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
                child: Text(entry.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: AppTheme.s),
            StatusDot(stage),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        children: [
          _section(L10n.of(context).detailSectionTunnel),
          _card(_loading
              ? const Padding(
                  padding: EdgeInsets.all(AppTheme.m),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.accent))),
                )
              : Column(children: [
                  _kvRow(l10n.kvState,
                      errorText ?? _tunnelStateText(l10n)),
                  _kvRow(l10n.kvRelay, entry.params.relayOrigin.toString()),
                  if (_snapshot != null && _snapshot!.tunnel.relayUrl.isNotEmpty)
                    _kvRow(l10n.kvReported, _snapshot!.tunnel.relayUrl),
                ])),
          _section(L10n.of(context).detailSectionSession),
          _card(Padding(
            padding: const EdgeInsets.all(AppTheme.m + 2),
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(L10n.of(context).detailRemaining(_fmt(left)),
                      style: const TextStyle(fontSize: 12.5)),
                  CountdownChip(
                      clock.isExpired(now)
                          ? L10n.of(context).chipExpired
                          : L10n.of(context).chipAutoRenew, stage),
                ],
              ),
              const SizedBox(height: AppTheme.s),
              _bar(clock.remaining(now).inMilliseconds /
                  const Duration(hours: 24).inMilliseconds),
              const SizedBox(height: AppTheme.xs + 2),
              Text(L10n.of(context).detailCapLine(clock.maxAgeDay(now) ?? '–'),
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
              const SizedBox(height: AppTheme.s),
              _bar(clock.maxAgeProgress(now), dim: true),
            ]),
          )),
          _section(L10n.of(context).detailSectionDevices(_devicesLine(l10n))),
          if (_snapshot?.devices != null)
            _card(Column(
              children: [
                for (final d in _snapshot!.devices!.take(4))
                  _kvRow(
                      d.sessionId == entry.id ? L10n.of(context).detailThisSession : d.sessionId.substring(0, 12),
                      '${d.online ? L10n.of(context).deviceOnline : L10n.of(context).deviceOffline}${d.paired ? L10n.of(context).devicePairedSuffix : ''}'),
              ],
            )),
          _section(L10n.of(context).detailSectionActions),
          _card(Padding(
            padding: const EdgeInsets.all(AppTheme.m),
            child: Column(children: [
              _action(Icons.open_in_new_outlined,
                  L10n.of(context).actionOpenWeb, _copyEscapeHatch),
              _action(Icons.link_off_outlined, L10n.of(context).actionDisconnect,
                  () => _tunnelAction(TunnelAction.disconnect)),
              _action(Icons.link_outlined, L10n.of(context).actionReconnect,
                  () => _tunnelAction(TunnelAction.connect)),
              _action(Icons.delete_forever_outlined,
                  L10n.of(context).actionRevokeAll, _revokeAll,
                  danger: true),
            ]),
          )),
        ],
      ),
    );
  }

  String _tunnelStateText(L10n l10n) {
    final s = _snapshot?.tunnel.state;
    return switch (s) {
      TunnelState.connected => l10n.stateConnected,
      TunnelState.connecting => l10n.stateConnecting,
      TunnelState.reconnecting => l10n.stateReconnecting,
      TunnelState.manualOff => l10n.stateManualOff,
      TunnelState.disabled => l10n.stateDisabled,
      _ => l10n.stateUnknown,
    };
  }

  String _devicesLine(L10n l10n) => _snapshot?.devices == null
      ? l10n.detailSnapshotMissing
      : l10n.detailPairedOnline(
          _snapshot!.devices!.where((d) => d.paired).length.toString(),
          _snapshot!.devices!.where((d) => d.online).length.toString());

  String _fmt(Duration d) => d.inHours >= 1
      ? '${d.inHours}h ${d.inMinutes % 60}m'
      : '${d.inMinutes}m';

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.xs + 2, AppTheme.m,
            AppTheme.xs + 2, AppTheme.xs + 2),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkDim)),
      );

  Widget _card(Widget child) => Card(child: child);

  Widget _kvRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.m + 2, vertical: AppTheme.xs + 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 52,
              child: Text(k,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.inkDim))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                      color: AppTheme.ink))),
        ]),
      );

  Widget _bar(double fraction, {bool dim = false}) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 4,
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation(
                dim ? AppTheme.inkDim : AppTheme.accent),
          ),
        ),
      );

  Widget _action(IconData icon, String label, VoidCallback onTap,
          {bool danger = false}) =>
      SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.xs),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: danger ? AppTheme.danger : AppTheme.ink,
              side: BorderSide(
                  color: danger
                      ? AppTheme.danger.withValues(alpha: 0.4)
                      : Colors.white.withValues(alpha: 0.16)),
              minimumSize: const Size.fromHeight(AppTheme.minTouch - 4),
            ),
            onPressed: onTap,
            icon: Icon(icon, size: 17),
            label: Align(alignment: Alignment.centerLeft, child: Text(label)),
          ),
        ),
      );
}
