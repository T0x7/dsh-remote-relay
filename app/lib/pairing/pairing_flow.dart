import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:flutter/material.dart';

import '../data/machine_entry.dart';
import '../l10n/generated/app_localizations.dart';
import '../logging/app_log.dart';
import 'scan_page.dart';
import '../ui/theme.dart';

/// Pairing flow (mockup 屏 B 粘贴路径 + C 确认 + J 失败): paste → parse →
/// **verify-before-store** (first `GET /dsh-remote/session` with the freshly
/// assembled Bearer — a dead QR never reaches the store) → confirm → save.
///
/// Camera scan (mobile_scanner) is the next batch; paste is the automatable
/// equivalent path (plan §12 相机路径取舍).
class PairingFlowSheet extends StatefulWidget {
  const PairingFlowSheet({super.key, required this.onPaired});

  final ValueChanged<MachineEntry> onPaired;

  /// Production path hits the real relay via RelayClient; tests override
  /// (plan §12 seam). Not part of the widget-tree contract.
  static PairingVerifier? verifierOverride;

  /// D-084: how the relay's certificate fingerprint is obtained. Tests inject
  /// a fake so the suite never opens a real TLS socket; null = the real probe.
  static PinProbe? pinProbeOverride;

  @override
  State<PairingFlowSheet> createState() => _PairingFlowSheetState();
}

enum _Step { paste, confirm, verifying, error, unreachable }

/// Injectable verification outcome (widget tests bypass the real relay).
enum PairingVerifyResult { valid, invalid, unreachable }

typedef PairingVerifier = Future<PairingVerifyResult> Function(
    SignedUrlParams params);

/// D-084: the relay certificate's fingerprint source. Null from the probe
/// means "could not fix one" — never an error the user has to act on.
typedef PinProbe = Future<String?> Function(Uri origin);

/// Entry built after a successful verify (test seam, D-025): carries the TOFU
/// fingerprint learned during the verify request so every later client
/// (console / detail / renewal) can seed its pin table from `entry.certPin`.
/// Null pin ⇒ plain-http relay or overridden verifier — stored as-is.
MachineEntry buildPairedEntry(SignedUrlParams params, String? learnedPin) =>
    MachineEntry(
      id: params.sessionId,
      name: params.name ?? params.relayOrigin.host,
      params: params,
      firstPairedMs: params.tMs,
      certPin: learnedPin,
    );

class _PairingFlowSheetState extends State<PairingFlowSheet> {
  final _controller = TextEditingController();
  _Step _step = _Step.paste;
  SignedUrlParams? _params;
  String? _errorCopy;

  /// TOFU fingerprint learned during the verify request (D-025). Null when the
  /// relay is plain http (no TLS callback) or the verifier was overridden.
  String? _learnedPin;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tryParse() {
    setState(() => _errorCopy = null);
    try {
      final params = parseSignedUrl(Uri.parse(_controller.text.trim()));
      setState(() {
        _params = params;
        _step = _Step.confirm;
      });
    } on SignedUrlFormatException catch (e) {
      setState(() {
        _step = _Step.paste;
        final l10n = L10n.of(context);
        _errorCopy = switch (e.reason) {
          String r when r.contains('token') => l10n.errTokenRetired,
          String r when r.contains('window') => l10n.errWindowExpired,
          _ => l10n.errMalformed(e.reason),
        };
      });
    } on FormatException {
      final l10n = L10n.of(context);
      setState(() => _errorCopy = l10n.errNotUrl);
    }
  }

  /// 屏 B — open the camera, feed a decoded payload into the same parse
  /// path as pasting (one contract, one verification).
  Future<void> _scanQr() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const ScanPage()),
    );
    if (value == null || !mounted) return;
    _controller.text = value.trim();
    _tryParse();
  }

  /// Verify-before-store: the first Bearer request doubles as the QR liveness
  /// check (design §5 配对流). 401 → the J-screen copy; transport → L3 copy.
  Future<void> _verifyAndConfirm() async {
    final params = _params!;
    setState(() => _step = _Step.verifying);
    final result = await _verify(params);
    if (!mounted) return;
    switch (result) {
      case PairingVerifyResult.valid:
        final pin = await _pinFor(params);
        // `_pinFor` 是第二个 async gap——跨它使用 context 需要再守一次。
        if (!mounted) return;
        final entry = buildPairedEntry(params, pin);
        widget.onPaired(entry);
        Navigator.of(context).pop();
      case PairingVerifyResult.invalid:
        setState(() {
          _step = _Step.error;
          _errorCopy = L10n.of(context).qrExpiredBody;
        });
      case PairingVerifyResult.unreachable:
        setState(() {
          _step = _Step.unreachable;
          _errorCopy = L10n.of(context).unreachableBody;
        });
    }
  }

  Future<PairingVerifyResult> _verify(SignedUrlParams params) async {
    final override = PairingFlowSheet.verifierOverride;
    if (override != null) return override(params);
    _learnedPin = null;
    final pinStore = MemoryPinStore();
    final pinned = PinnedHttpClient(
      pinTable: pinStore.pins,
      learnOnFirstConnect: true, // TOFU learn at pairing (design §8)
      onLearn: (_, fingerprint) => _learnedPin = fingerprint, // D-025
    );
    final client = RelayClient(
      origin: params.relayOrigin,
      pinned: pinned,
      bearerProvider: () async => params.bearer,
    );
    try {
      final snapshot = await client.fetchSessionSnapshot();
      return snapshot == null
          ? PairingVerifyResult.invalid
          : PairingVerifyResult.valid;
    } on Object {
      return PairingVerifyResult.unreachable;
    } finally {
      pinned.close();
    }
  }

  /// D-084 — the pin for this machine, or null when there is none to take.
  ///
  /// Two sources, in order of authority:
  /// 1. `_learnedPin` — set when the relay's certificate failed validation and
  ///    `badCertificateCallback` fired. That is the pre-D-084 path; keep it.
  /// 2. a proactive [probePeerFingerprint] — needed because a *trusted*
  ///    certificate never triggers the callback at all, which is the common
  ///    case and the reason pin tables were empty on a working https pairing.
  ///
  /// Failure is swallowed on purpose: pairing has already proved the Bearer
  /// works, and a missing pin only degrades to the steady state's fail-closed
  /// table. Blocking a successful pairing over an unreadable certificate would
  /// trade a security nicety for a worse failure.
  Future<String?> _pinFor(SignedUrlParams params) async {
    if (_learnedPin != null) return _learnedPin;
    final origin = params.relayOrigin;
    if (origin.scheme != 'https') return null; // plaintext has no certificate
    final probe = PairingFlowSheet.pinProbeOverride ?? probePeerFingerprint;
    try {
      final pin = await probe(origin);
      if (pin != null) {
        AppLog.d('pairing',
            'TOFU pin learned for ${origin.host} (${fingerprintPreview(pin)})');
      } else {
        AppLog.w('pairing',
            'TOFU pin unavailable for ${origin.host} — stored unpinned');
      }
      // 主机名按 server 的 redact 纪律留档（identifier，不是 secret）；指纹
      // 只进 app.log，操作日志里不复制第二份。
      AppLog.audit('pair.tofu',
          attrs: {'host': origin.host, 'learned': pin != null});
      return pin;
    } on Object catch (e) {
      AppLog.w('pairing', 'TOFU pin probe failed for ${origin.host}: $e');
      AppLog.audit('pair.tofu',
          attrs: {'host': origin.host, 'learned': false, 'error': true});
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => switch (_step) {
        _Step.paste => _pasteView(),
        _Step.confirm => _confirmView(),
        _Step.verifying => _busyView(),
        _Step.error => _errorView(),
        _Step.unreachable => _errorView(), // same card, different copy
      };

  Widget _sheetBody({required List<Widget> children}) => Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  Widget _pasteView() => _sheetBody(children: [
        Row(
          children: [
            Expanded(
              child: Text(L10n.of(context).pairingTitle,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: _scanQr,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
              label: Text(L10n.of(context).pairingScan),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s),
        TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 2,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          decoration: InputDecoration(
            hintText: L10n.of(context).pairingHint,
            filled: true,
            fillColor: AppTheme.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        if (_errorCopy != null) ...[
          const SizedBox(height: AppTheme.s),
          Text(_errorCopy!, style: const TextStyle(color: AppTheme.danger, fontSize: 12)),
        ],
        const SizedBox(height: AppTheme.m),
        FilledButton(
          onPressed: _tryParse,
          child: Text(L10n.of(context).pairingParse),
        ),
      ]);

  Widget _confirmView() => _sheetBody(children: [
        Text(L10n.of(context).confirmTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTheme.m),
        _kv(L10n.of(context).kvRelay, _params!.relayOrigin.toString()),
        _kv(L10n.of(context).kvMachine, _params!.name ?? _params!.relayOrigin.host),
        _kv(L10n.of(context).detailSectionSession, L10n.of(context).confirmSessionLine),
        const SizedBox(height: AppTheme.s),
        Container(
          padding: const EdgeInsets.all(AppTheme.m),
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.accent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_user_outlined, size: 16, color: AppTheme.accent),
              const SizedBox(width: AppTheme.s),
              Expanded(
                child: Text(
                  L10n.of(context).confirmSecurity,
                  style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.m),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() {
                _step = _Step.paste;
                _params = null;
              }),
              child: Text(L10n.of(context).actionCancel),
            ),
          ),
          const SizedBox(width: AppTheme.s),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: _verifyAndConfirm,
              icon: const Icon(Icons.lock_clock_outlined, size: 16),
              label: Text(L10n.of(context).actionLockAndConnect),
            ),
          ),
        ]),
      ]);

  Widget _busyView() => _sheetBody(children: [
        const Padding(
          padding: EdgeInsets.all(AppTheme.xl),
          child: Center(child: CircularProgressIndicator(color: AppTheme.accent)),
        ),
        Center(
            child: Text(L10n.of(context).verifyingLink,
                style: const TextStyle(fontSize: 12, color: AppTheme.inkDim))),
      ]);

  Widget _errorView() => _sheetBody(children: [
        Icon(
          _step == _Step.unreachable
              ? Icons.wifi_off_rounded
              : Icons.warning_amber_rounded,
          color: _step == _Step.unreachable ? AppTheme.inkDim : AppTheme.warn,
          size: 44,
        ),
        const SizedBox(height: AppTheme.m),
        Text(
          _step == _Step.unreachable ? L10n.of(context).unreachableTitle : L10n.of(context).qrExpiredTitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: AppTheme.s),
        Text(
          _errorCopy ?? '',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: AppTheme.inkDim),
        ),
        const SizedBox(height: AppTheme.m),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(L10n.of(context).actionCancel),
            ),
          ),
          const SizedBox(width: AppTheme.s),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: () => setState(() => _step = _Step.paste),
              child: Text(L10n.of(context).actionRetry),
            ),
          ),
        ]),
      ]);

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.xs + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                      color: AppTheme.ink)),
            ),
          ],
        ),
      );
}
